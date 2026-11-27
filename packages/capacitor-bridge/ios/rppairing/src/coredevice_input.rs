//! CoreDevice HID touch, keyboard, hardware button, and pasteboard command translation.

use std::ffi::{CString, c_char, c_void};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use idevice::core_device::hid::{
    ButtonState, IndigoHidClient, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
    UniversalHidServiceClient,
};
use idevice::core_device::{GENERAL_PASTEBOARD, PasteboardServiceClient};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::{ReadWrite, RsdService};
use serde::Deserialize;
use tokio::sync::mpsc;

pub(crate) const MAX_CLIPBOARD_BYTES: usize = 32 * 1024;
const HID_AUTH_SETTLE_DELAY: Duration = Duration::from_millis(300);
const CLIPBOARD_POLL_INTERVAL: Duration = Duration::from_millis(750);

pub type ClipboardCallback = extern "C" fn(ctx: *mut c_void, utf8_text: *const c_char);

#[derive(Clone, Copy)]
pub(crate) struct SendCtx(pub(crate) *mut c_void);
unsafe impl Send for SendCtx {}
unsafe impl Sync for SendCtx {}

// Named Apple hardware buttons (HID Consumer page 0x0C).
const HID_PAGE_CONSUMER: u64 = 0x0C;
const HID_USAGE_HOME: u64 = 0x40;
const HID_USAGE_POWER: u64 = 0x30;

#[derive(Debug, Deserialize)]
#[serde(tag = "t", rename_all = "camelCase")]
pub(crate) enum InputCommand {
    Move { x: f64, y: f64 },
    Btn { b: u8, p: bool },
    Wheel { dx: f64, dy: f64 },
    Key { c: String, p: bool, #[serde(default)] #[allow(dead_code)] r: bool },
    Clip { s: String },
    Release,
}

/// Maps normalized [0.0, 1.0] coordinates to UniversalHID touchscreen [0, 65535].
pub(crate) fn normalized_to_hid_coord(v: f64) -> u16 {
    if !v.is_finite() {
        return 0;
    }
    (v.clamp(0.0, 1.0) * 65535.0).round() as u16
}

/// Maps physical DOM `KeyboardEvent.code` names to USB HID Keyboard/Keypad (page 0x07) usage IDs.
pub(crate) fn dom_code_to_hid_usage(code: &str) -> Option<u64> {
    if let [b @ b'A'..=b'Z'] = code.strip_prefix("Key").map_or(&[][..], str::as_bytes) {
        return Some(0x04 + u64::from(b - b'A'));
    }
    if let [b @ b'1'..=b'9'] = code.strip_prefix("Digit").map_or(&[][..], str::as_bytes) {
        return Some(0x1E + u64::from(b - b'1'));
    }
    if code == "Digit0" {
        return Some(0x27);
    }
    if let Some(n) = code
        .strip_prefix('F')
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|n| (1..=12).contains(n))
    {
        return Some(0x3A + (n - 1));
    }
    Some(match code {
        "Enter" => 0x28,
        "NumpadEnter" => 0x58,
        "Escape" => 0x29,
        "Backspace" => 0x2A,
        "Tab" => 0x2B,
        "Space" => 0x2C,
        "Minus" => 0x2D,
        "Equal" => 0x2E,
        "BracketLeft" => 0x2F,
        "BracketRight" => 0x30,
        "Backslash" => 0x31,
        "Semicolon" => 0x33,
        "Quote" => 0x34,
        "Backquote" => 0x35,
        "Comma" => 0x36,
        "Period" => 0x37,
        "Slash" => 0x38,
        "CapsLock" => 0x39,
        "Insert" => 0x49,
        "Home" => 0x4A,
        "PageUp" => 0x4B,
        "Delete" => 0x4C,
        "End" => 0x4D,
        "PageDown" => 0x4E,
        "ArrowRight" => 0x4F,
        "ArrowLeft" => 0x50,
        "ArrowDown" => 0x51,
        "ArrowUp" => 0x52,
        "NumpadDivide" => 0x54,
        "NumpadMultiply" => 0x55,
        "NumpadSubtract" => 0x56,
        "NumpadAdd" => 0x57,
        "Numpad1" => 0x59,
        "Numpad2" => 0x5A,
        "Numpad3" => 0x5B,
        "Numpad4" => 0x5C,
        "Numpad5" => 0x5D,
        "Numpad6" => 0x5E,
        "Numpad7" => 0x5F,
        "Numpad8" => 0x60,
        "Numpad9" => 0x61,
        "Numpad0" => 0x62,
        "NumpadDecimal" => 0x63,
        "IntlBackslash" => 0x64,
        "ControlLeft" => 0xE0,
        "ShiftLeft" => 0xE1,
        "AltLeft" => 0xE2,
        "MetaLeft" => 0xE3,
        "ControlRight" => 0xE4,
        "ShiftRight" => 0xE5,
        "AltRight" => 0xE6,
        "MetaRight" => 0xE7,
        _ => return None,
    })
}

pub(crate) struct InputState {
    x: f64,
    y: f64,
    touch_down: bool,
    held_keys: Vec<u64>,
    pub(crate) last_clipboard: Option<String>,
    pub(crate) last_change_count: Option<i64>,
}

impl InputState {
    pub(crate) fn new() -> Self {
        Self {
            x: 0.5,
            y: 0.5,
            touch_down: false,
            held_keys: Vec::new(),
            last_clipboard: None,
            last_change_count: None,
        }
    }

    pub(crate) async fn handle(
        &mut self,
        cmd: InputCommand,
        touch: &mut Option<UniversalHidServiceClient<Box<dyn ReadWrite + 'static>>>,
        indigo: &mut Option<IndigoHidClient<Box<dyn ReadWrite + 'static>>>,
        pasteboard: &mut Option<PasteboardServiceClient<Box<dyn ReadWrite + 'static>>>,
    ) {
        match cmd {
            InputCommand::Move { x, y } => {
                self.x = x.clamp(0.0, 1.0);
                self.y = y.clamp(0.0, 1.0);
                if self.touch_down {
                    if let Some(hid) = touch.as_mut() {
                        let ux = normalized_to_hid_coord(self.x);
                        let uy = normalized_to_hid_coord(self.y);
                        let _ = hid
                            .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, ux, uy, None)
                            .await;
                    }
                }
            }
            InputCommand::Btn { b, p } => match b {
                0 => {
                    self.touch_down = p;
                    if let Some(hid) = touch.as_mut() {
                        let ux = normalized_to_hid_coord(self.x);
                        let uy = normalized_to_hid_coord(self.y);
                        let state = if p {
                            TOUCHSCREEN_STATE_CONTACT
                        } else {
                            TOUCHSCREEN_STATE_RELEASE
                        };
                        let _ = hid.send_touchscreen(state, ux, uy, None).await;
                    }
                }
                1 => {
                    // Middle click -> Hardware Home button
                    if let Some(ind) = indigo.as_mut() {
                        let state = if p { ButtonState::Down } else { ButtonState::Up };
                        let _ = ind.send_button(HID_PAGE_CONSUMER, HID_USAGE_HOME, state).await;
                    }
                }
                2 | 3 => {
                    // Right click / Back button -> iOS left-edge swipe back gesture
                    if p {
                        if let Some(hid) = touch.as_mut() {
                            let y = normalized_to_hid_coord(self.y.clamp(0.15, 0.85));
                            let _ = hid
                                .drag(
                                    normalized_to_hid_coord(0.02),
                                    y,
                                    normalized_to_hid_coord(0.45),
                                    y,
                                    8,
                                    12,
                                )
                                .await;
                        }
                    }
                }
                4 => {
                    // Forward button -> Power / Lock button
                    if let Some(ind) = indigo.as_mut() {
                        let state = if p { ButtonState::Down } else { ButtonState::Up };
                        let _ = ind.send_button(HID_PAGE_CONSUMER, HID_USAGE_POWER, state).await;
                    }
                }
                _ => {}
            },
            InputCommand::Wheel { dx, dy } => {
                if let Some(hid) = touch.as_mut() {
                    let delta_x = (-dx / 1200.0).clamp(-0.35, 0.35);
                    let delta_y = (-dy / 1200.0).clamp(-0.35, 0.35);
                    if delta_x.abs() < 0.005 && delta_y.abs() < 0.005 {
                        return;
                    }
                    let start_x = self.x.clamp(0.1, 0.9);
                    let start_y = self.y.clamp(0.1, 0.9);
                    let end_x = (start_x + delta_x).clamp(0.02, 0.98);
                    let end_y = (start_y + delta_y).clamp(0.02, 0.98);
                    let _ = hid
                        .drag(
                            normalized_to_hid_coord(start_x),
                            normalized_to_hid_coord(start_y),
                            normalized_to_hid_coord(end_x),
                            normalized_to_hid_coord(end_y),
                            6,
                            10,
                        )
                        .await;
                }
            }
            InputCommand::Key { c, p, r: _ } => {
                if let (Some(usage), Some(ind)) = (dom_code_to_hid_usage(&c), indigo.as_mut()) {
                    if p {
                        if !self.held_keys.contains(&usage) {
                            self.held_keys.push(usage);
                        }
                        let _ = ind.send_keyboard(usage, ButtonState::Down).await;
                    } else {
                        self.held_keys.retain(|k| *k != usage);
                        let _ = ind.send_keyboard(usage, ButtonState::Up).await;
                    }
                }
            }
            InputCommand::Clip { s } => {
                if !s.is_empty() && s.len() <= MAX_CLIPBOARD_BYTES {
                    self.last_clipboard = Some(s.clone());
                    if let Some(pb) = pasteboard.as_mut() {
                        let _ = pb.set_text(&s, GENERAL_PASTEBOARD).await;
                    }
                }
            }
            InputCommand::Release => {
                self.release_all(touch, indigo).await;
            }
        }
    }

    pub(crate) async fn release_all(
        &mut self,
        touch: &mut Option<UniversalHidServiceClient<Box<dyn ReadWrite + 'static>>>,
        indigo: &mut Option<IndigoHidClient<Box<dyn ReadWrite + 'static>>>,
    ) {
        if self.touch_down {
            self.touch_down = false;
            if let Some(hid) = touch.as_mut() {
                let ux = normalized_to_hid_coord(self.x);
                let uy = normalized_to_hid_coord(self.y);
                let _ = hid
                    .send_touchscreen(TOUCHSCREEN_STATE_RELEASE, ux, uy, None)
                    .await;
            }
        }
        if let Some(ind) = indigo.as_mut() {
            for usage in self.held_keys.drain(..) {
                let _ = ind.send_keyboard(usage, ButtonState::Up).await;
            }
        } else {
            self.held_keys.clear();
        }
    }
}

pub(crate) async fn run_input_and_clipboard_task(
    mut adapter: AdapterHandle,
    mut handshake: RsdHandshake,
    mut input_rx: mpsc::UnboundedReceiver<InputCommand>,
    stopped: Arc<AtomicBool>,
    on_clipboard: Option<ClipboardCallback>,
    ctx: SendCtx,
) {
    tokio::time::sleep(HID_AUTH_SETTLE_DELAY).await;
    if stopped.load(Ordering::Acquire) {
        return;
    }

    let mut touch_client = tokio::time::timeout(
        Duration::from_secs(4),
        UniversalHidServiceClient::<Box<dyn ReadWrite + 'static>>::connect_rsd(
            &mut adapter,
            &mut handshake,
        ),
    )
    .await
    .ok()
    .and_then(Result::ok);
    let mut indigo_client = tokio::time::timeout(
        Duration::from_secs(4),
        IndigoHidClient::<Box<dyn ReadWrite + 'static>>::connect_rsd(&mut adapter, &mut handshake),
    )
    .await
    .ok()
    .and_then(Result::ok);
    let mut pasteboard_client = tokio::time::timeout(
        Duration::from_secs(4),
        PasteboardServiceClient::<Box<dyn ReadWrite + 'static>>::connect_rsd(
            &mut adapter,
            &mut handshake,
        ),
    )
    .await
    .ok()
    .and_then(Result::ok);

    eprintln!(
        "[CoreDevice] input services ready: touch={} indigo={} pasteboard={}",
        touch_client.is_some(),
        indigo_client.is_some(),
        pasteboard_client.is_some()
    );

    let mut input_state = InputState::new();
    if let Some(pb) = pasteboard_client.as_mut() {
        if let Ok(Ok(snap)) =
            tokio::time::timeout(Duration::from_millis(500), pb.get(GENERAL_PASTEBOARD)).await
        {
            input_state.last_change_count = snap.change_count;
            input_state.last_clipboard = snap.text();
        }
    }

    let mut clipboard_interval = tokio::time::interval(CLIPBOARD_POLL_INTERVAL);
    clipboard_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        if stopped.load(Ordering::Acquire) {
            break;
        }
        tokio::select! {
            biased;
            cmd = input_rx.recv() => {
                match cmd {
                    Some(cmd) => {
                        input_state
                            .handle(cmd, &mut touch_client, &mut indigo_client, &mut pasteboard_client)
                            .await;
                    }
                    None => break,
                }
            }
            _ = clipboard_interval.tick(), if on_clipboard.is_some() && pasteboard_client.is_some() => {
                if let Some(pb) = pasteboard_client.as_mut() {
                    if let Ok(Ok(snap)) = tokio::time::timeout(
                        Duration::from_millis(500),
                        pb.get(GENERAL_PASTEBOARD),
                    ).await {
                        let changed = match (input_state.last_change_count, snap.change_count) {
                            (Some(prev), Some(curr)) => curr != prev,
                            (None, Some(_)) => true,
                            _ => false,
                        };
                        if changed {
                            input_state.last_change_count = snap.change_count;
                            if let Some(text) = snap.text() {
                                if !text.is_empty()
                                    && text.len() <= MAX_CLIPBOARD_BYTES
                                    && input_state.last_clipboard.as_deref() != Some(text.as_str())
                                {
                                    input_state.last_clipboard = Some(text.clone());
                                    if let (Some(cb), Ok(cs)) =
                                        (on_clipboard, CString::new(text.replace('\0', "")))
                                    {
                                        cb(ctx.0, cs.as_ptr());
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let _ = tokio::time::timeout(
        Duration::from_millis(750),
        input_state.release_all(&mut touch_client, &mut indigo_client),
    )
    .await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_dom_codes_to_usb_hid_usages() {
        assert_eq!(dom_code_to_hid_usage("KeyA"), Some(0x04));
        assert_eq!(dom_code_to_hid_usage("KeyZ"), Some(0x1D));
        assert_eq!(dom_code_to_hid_usage("Digit1"), Some(0x1E));
        assert_eq!(dom_code_to_hid_usage("Digit0"), Some(0x27));
        assert_eq!(dom_code_to_hid_usage("Enter"), Some(0x28));
        assert_eq!(dom_code_to_hid_usage("Backspace"), Some(0x2A));
        assert_eq!(dom_code_to_hid_usage("ShiftLeft"), Some(0xE1));
        assert_eq!(dom_code_to_hid_usage("MetaRight"), Some(0xE7));
        assert_eq!(dom_code_to_hid_usage("F12"), Some(0x45));
        assert_eq!(dom_code_to_hid_usage("UnknownKey"), None);
    }

    #[test]
    fn converts_normalized_coordinates_safely() {
        assert_eq!(normalized_to_hid_coord(0.0), 0);
        assert_eq!(normalized_to_hid_coord(0.5), 32768);
        assert_eq!(normalized_to_hid_coord(1.0), 65535);
        assert_eq!(normalized_to_hid_coord(-1.0), 0);
        assert_eq!(normalized_to_hid_coord(2.0), 65535);
        assert_eq!(normalized_to_hid_coord(f64::NAN), 0);
    }

    #[test]
    fn parses_wire_input_commands() {
        let mv: InputCommand = serde_json::from_str(r#"{"t":"move","x":0.25,"y":0.75}"#).unwrap();
        assert!(matches!(mv, InputCommand::Move { x, y } if (x - 0.25).abs() < 1e-6 && (y - 0.75).abs() < 1e-6));
        let key: InputCommand = serde_json::from_str(r#"{"t":"key","c":"KeyA","p":true}"#).unwrap();
        assert!(matches!(key, InputCommand::Key { c, p: true, r: false } if c == "KeyA"));
        let clip: InputCommand = serde_json::from_str(r#"{"t":"clip","s":"hello"}"#).unwrap();
        assert!(matches!(clip, InputCommand::Clip { s } if s == "hello"));
    }
}
