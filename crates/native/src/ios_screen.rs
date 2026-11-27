//! Embedded iOS RVVM host bridge for remote screen sharing and input control.
//!
//! When running inside DeskFleet Plus's iOS RVVM Linux guest, the iOS host app
//! exposes a local TCP bridge (`DESKFLEET_IOS_SCREEN_ADDR` + `DESKFLEET_IOS_SCREEN_TOKEN`)
//! backed by either Apple CoreDevice (`displayservice` + `hid` + `pasteboard`)
//! or the ReplayKit Broadcast Upload Extension (`VideoToolbox` H.264/H.265).

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::{Duration, Instant};

use bytes::Bytes;
#[cfg(target_os = "linux")]
use deskfleet_capture::Display;
use deskfleet_capture::CaptureError;
use deskfleet_encoder::{Codec, EncoderError};
use deskfleet_input::{Backend, InputError};
use serde::Deserialize;

#[cfg(target_os = "linux")]
use crate::desktop_access::DesktopAccess;
use crate::media::{DesktopConfig, MediaError, Packet, pipeline::CaptureBatch};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const POLL_TIMEOUT: Duration = Duration::from_millis(15);
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
const FRAME_KIND_KEEPALIVE: u8 = 0;
const FRAME_KIND_VIDEO: u8 = 1;
const FRAME_FLAG_KEYFRAME: u8 = 1;
const CMD_KEYFRAME: u8 = 1;
const CMD_BITRATE: u8 = 2;
const BITRATE_UPDATE_INTERVAL: Duration = Duration::from_millis(400);

#[cfg(target_os = "linux")]
pub(crate) fn is_configured() -> bool {
    std::env::var_os("DESKFLEET_IOS_SCREEN_ADDR").is_some_and(|v| !v.is_empty())
}

#[cfg(target_os = "linux")]
fn configured_endpoint() -> Result<(String, String), String> {
    let addr = std::env::var("DESKFLEET_IOS_SCREEN_ADDR")
        .ok()
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "DESKFLEET_IOS_SCREEN_ADDR is not set".to_owned())?;
    let token = std::env::var("DESKFLEET_IOS_SCREEN_TOKEN")
        .unwrap_or_default()
        .trim()
        .to_owned();
    Ok((addr, token))
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HostScreenInfo {
    pub(crate) available: bool,
    #[serde(default)]
    pub(crate) control: bool,
    #[serde(default)]
    pub(crate) width: u32,
    #[serde(default)]
    pub(crate) height: u32,
    #[serde(default = "default_fps")]
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub(crate) fps: f64,
    #[serde(default)]
    pub(crate) codecs: Vec<String>,
}

fn default_fps() -> f64 {
    60.0
}

fn connect_authenticated(addr: &str, token: &str) -> Result<TcpStream, String> {
    let sock_addr: SocketAddr = addr
        .parse()
        .map_err(|e| format!("invalid iOS screen bridge address '{addr}': {e}"))?;
    let mut stream = TcpStream::connect_timeout(&sock_addr, CONNECT_TIMEOUT)
        .map_err(|e| format!("failed to connect to iOS screen bridge {addr}: {e}"))?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT));
    let _ = stream.set_write_timeout(Some(HANDSHAKE_TIMEOUT));
    writeln!(stream, "AUTH {token}")
        .map_err(|e| format!("failed writing iOS screen auth: {e}"))?;
    stream
        .flush()
        .map_err(|e| format!("failed flushing iOS screen auth: {e}"))?;
    let reply = read_line_raw(&mut stream)?;
    if reply != "OK" {
        return Err(format!("iOS screen bridge rejected auth: {reply}"));
    }
    Ok(stream)
}

fn read_line_raw(stream: &mut TcpStream) -> Result<String, String> {
    let mut buf = Vec::with_capacity(128);
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) => return Err("iOS screen bridge closed unexpectedly".to_owned()),
            Ok(_) => {
                if byte[0] == b'\n' {
                    break;
                }
                if byte[0] != b'\r' {
                    buf.push(byte[0]);
                }
                if buf.len() > 64 * 1024 {
                    return Err("iOS screen bridge response line too long".to_owned());
                }
            }
            Err(e) => return Err(format!("iOS screen bridge read failed: {e}")),
        }
    }
    String::from_utf8(buf).map_err(|e| format!("invalid UTF-8 from iOS screen bridge: {e}"))
}

fn query_info_from(addr: &str, token: &str) -> Result<HostScreenInfo, String> {
    let mut stream = connect_authenticated(addr, token)?;
    writeln!(stream, "INFO").map_err(|e| format!("failed sending INFO: {e}"))?;
    stream
        .flush()
        .map_err(|e| format!("failed flushing INFO: {e}"))?;
    let line = read_line_raw(&mut stream)?;
    serde_json::from_str::<HostScreenInfo>(&line)
        .map_err(|e| format!("invalid iOS screen INFO payload: {e}"))
}

#[cfg(target_os = "linux")]
fn query_info() -> Result<HostScreenInfo, String> {
    let (addr, token) = configured_endpoint()?;
    query_info_from(&addr, &token)
}

#[cfg(target_os = "linux")]
pub(crate) fn displays_sync() -> Result<Vec<Display>, CaptureError> {
    let info = query_info().map_err(CaptureError::Platform)?;
    if !info.available || info.width == 0 || info.height == 0 {
        return Ok(Vec::new());
    }
    Ok(vec![Display {
        id: 0,
        name: Some("iOS Display".to_owned()),
        display_number: Some(1),
        width: info.width,
        height: info.height,
        refresh_rate_hz: if info.fps.is_finite() && (1.0..=240.0).contains(&info.fps) {
            info.fps
        } else {
            60.0
        },
    }])
}

#[cfg(target_os = "linux")]
pub(crate) fn supported_video_codecs_sync(display_id: u32) -> Result<Vec<String>, MediaError> {
    if display_id != 0 {
        return Err(MediaError::DisplayNotFound(display_id));
    }
    let info = query_info().map_err(CaptureError::Platform)?;
    if !info.available {
        return Ok(Vec::new());
    }
    Ok(info
        .codecs
        .into_iter()
        .filter(|c| matches!(c.as_str(), "h264" | "h265"))
        .collect())
}

#[cfg(target_os = "linux")]
pub(crate) async fn check_access() -> Result<DesktopAccess, String> {
    tokio::task::spawn_blocking(|| {
        let Ok(info) = query_info() else {
            return Ok(DesktopAccess::default());
        };
        Ok(DesktopAccess {
            screen_capture: info.available && !info.codecs.is_empty(),
            control: info.available && info.control,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(target_os = "linux")]
pub(crate) async fn supported() -> Result<bool, String> {
    tokio::task::spawn_blocking(|| {
        let Ok(info) = query_info() else {
            return Ok(false);
        };
        Ok(info.available && info.width > 0 && info.height > 0 && !info.codecs.is_empty())
    })
    .await
    .map_err(|e| e.to_string())?
}

pub(crate) struct IosScreenCapture {
    stream: TcpStream,
    frame_duration: Duration,
    resume_keyframe: bool,
    has_video: bool,
    bitrate_ceiling: u32,
    last_bitrate_sent: u32,
    last_bitrate_at: Instant,
}

impl IosScreenCapture {
    #[cfg(target_os = "linux")]
    pub(crate) fn open(
        config: DesktopConfig,
        codec: Codec,
        audio: bool,
    ) -> Result<Self, MediaError> {
        if audio {
            return Err(MediaError::InvalidConfig(
                "iOS system audio streaming is not enabled yet",
            ));
        }
        config.validate()?;
        if config.display_id != 0 {
            return Err(MediaError::DisplayNotFound(config.display_id));
        }
        let (addr, token) = configured_endpoint().map_err(CaptureError::Platform)?;
        Self::open_at(&addr, &token, config, codec)
    }

    fn open_at(
        addr: &str,
        token: &str,
        config: DesktopConfig,
        codec: Codec,
    ) -> Result<Self, MediaError> {
        let mut stream = connect_authenticated(addr, token)
            .map_err(|e| MediaError::VideoEncoder(EncoderError::Platform(e)))?;
        let fps = config.fps.clamp(1.0, 240.0);
        let max_w = config.max_width.unwrap_or(0);
        let max_h = config.max_height.unwrap_or(0);
        writeln!(
            stream,
            "VIDEO {} {} {} {} {}",
            codec.as_str(),
            fps.round() as u32,
            config.bitrate_bps,
            max_w,
            max_h,
        )
        .map_err(|e| MediaError::VideoEncoder(EncoderError::Platform(e.to_string())))?;
        stream
            .flush()
            .map_err(|e| MediaError::VideoEncoder(EncoderError::Platform(e.to_string())))?;
        let reply = read_line_raw(&mut stream)
            .map_err(|e| MediaError::VideoEncoder(EncoderError::Platform(e)))?;
        if !reply.starts_with("OK") {
            return Err(MediaError::VideoEncoder(EncoderError::Platform(
                reply.strip_prefix("ERR ").unwrap_or(&reply).to_owned(),
            )));
        }
        stream
            .set_read_timeout(Some(POLL_TIMEOUT))
            .map_err(|e| CaptureError::Platform(e.to_string()))?;
        Ok(Self {
            stream,
            frame_duration: Duration::from_secs_f64(1.0 / fps),
            resume_keyframe: true,
            has_video: false,
            bitrate_ceiling: config.bitrate_ceiling(),
            last_bitrate_sent: config.bitrate_bps,
            last_bitrate_at: Instant::now(),
        })
    }

    pub(crate) fn poll(
        &mut self,
        keyframe: bool,
        estimate_bps: Option<f64>,
        video_paused: bool,
    ) -> Result<CaptureBatch, MediaError> {
        if keyframe {
            let _ = self.stream.write_all(&[CMD_KEYFRAME]);
        }
        if let Some(estimate) = estimate_bps
            && estimate.is_finite()
            && estimate > 0.0
            && self.last_bitrate_at.elapsed() >= BITRATE_UPDATE_INTERVAL
        {
            let target = (estimate.round() as u32).clamp(150_000, self.bitrate_ceiling);
            if target.abs_diff(self.last_bitrate_sent) >= (self.last_bitrate_sent / 10).max(50_000) {
                let mut cmd = [0u8; 5];
                cmd[0] = CMD_BITRATE;
                cmd[1..5].copy_from_slice(&target.to_be_bytes());
                let _ = self.stream.write_all(&cmd);
                self.last_bitrate_sent = target;
                self.last_bitrate_at = Instant::now();
            }
        }

        let mut packets = Vec::new();
        for _ in 0..8 {
            let Some((kind, flags, pts_ns, data)) = self.read_frame()? else {
                break;
            };
            if kind == FRAME_KIND_KEEPALIVE {
                continue;
            }
            if kind != FRAME_KIND_VIDEO || data.is_empty() {
                continue;
            }
            if video_paused {
                self.resume_keyframe = true;
                continue;
            }
            let is_key = (flags & FRAME_FLAG_KEYFRAME) != 0;
            if self.resume_keyframe && !is_key {
                continue;
            }
            self.resume_keyframe = false;
            self.has_video = true;
            packets.push(Packet::Video(
                Bytes::from(data),
                self.frame_duration,
                pts_ns,
                is_key,
            ));
            break;
        }
        Ok(CaptureBatch {
            packets,
            encoder_started: true,
        })
    }

    fn read_frame(&mut self) -> Result<Option<(u8, u8, u64, Vec<u8>)>, MediaError> {
        let mut hdr = [0u8; 14];
        match self.stream.read(&mut hdr[..1]) {
            Ok(0) => return Err(self.fail("iOS screen video stream closed")),
            Ok(_) => {}
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                return Ok(None);
            }
            Err(e) => return Err(self.fail(&e.to_string())),
        }
        let _ = self.stream.set_read_timeout(Some(Duration::from_secs(2)));
        let res = (|| -> io::Result<(u8, u8, u64, Vec<u8>)> {
            self.stream.read_exact(&mut hdr[1..])?;
            let kind = hdr[0];
            let flags = hdr[1];
            let pts_ns = u64::from_be_bytes(hdr[2..10].try_into().unwrap());
            let len = u32::from_be_bytes(hdr[10..14].try_into().unwrap()) as usize;
            if len > MAX_FRAME_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "oversized iOS screen frame",
                ));
            }
            let mut buf = vec![0u8; len];
            if len > 0 {
                self.stream.read_exact(&mut buf)?;
            }
            Ok((kind, flags, pts_ns, buf))
        })();
        let _ = self.stream.set_read_timeout(Some(POLL_TIMEOUT));
        res.map(Some).map_err(|e| self.fail(&e.to_string()))
    }

    fn fail(&self, msg: &str) -> MediaError {
        if self.has_video {
            CaptureError::Platform(msg.to_owned()).into()
        } else {
            MediaError::VideoEncoder(EncoderError::Platform(msg.to_owned()))
        }
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn stop(self) -> Result<(), MediaError> {
        Ok(())
    }
}

pub(crate) struct IosScreenInput {
    writer: TcpStream,
    reader: BufReader<TcpStream>,
}

#[derive(Deserialize)]
struct HostInputEvent {
    t: String,
    #[serde(default)]
    s: String,
}

impl IosScreenInput {
    #[cfg(target_os = "linux")]
    pub(crate) fn open(display_id: u32) -> Result<Self, InputError> {
        if display_id != 0 {
            return Err(InputError::Unsupported("display was not found"));
        }
        let (addr, token) = configured_endpoint().map_err(InputError::Platform)?;
        Self::open_at(&addr, &token)
    }

    fn open_at(addr: &str, token: &str) -> Result<Self, InputError> {
        let mut stream = connect_authenticated(addr, token).map_err(InputError::Platform)?;
        writeln!(stream, "INPUT").map_err(|e| InputError::Platform(e.to_string()))?;
        stream
            .flush()
            .map_err(|e| InputError::Platform(e.to_string()))?;
        let reply = read_line_raw(&mut stream).map_err(InputError::Platform)?;
        if reply != "OK" {
            let reason = reply.strip_prefix("ERR ").unwrap_or(&reply);
            return Err(InputError::Platform(reason.to_owned()));
        }
        let reader_stream = stream
            .try_clone()
            .map_err(|e| InputError::Platform(e.to_string()))?;
        let _ = reader_stream.set_read_timeout(Some(POLL_TIMEOUT));
        Ok(Self {
            writer: stream,
            reader: BufReader::new(reader_stream),
        })
    }

    fn send_json(&mut self, value: serde_json::Value) -> Result<(), InputError> {
        let mut line = serde_json::to_string(&value)
            .map_err(|e| InputError::Platform(e.to_string()))?;
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .map_err(|e| InputError::Platform(e.to_string()))
    }
}

impl Backend for IosScreenInput {
    fn move_pointer(&mut self, x: f64, y: f64) -> Result<(), InputError> {
        self.send_json(serde_json::json!({ "t": "move", "x": x, "y": y }))
    }

    fn button(&mut self, button: u8, pressed: bool) -> Result<(), InputError> {
        self.send_json(serde_json::json!({ "t": "btn", "b": button, "p": pressed }))
    }

    fn wheel(&mut self, dx: f64, dy: f64) -> Result<(), InputError> {
        self.send_json(serde_json::json!({ "t": "wheel", "dx": dx, "dy": dy }))
    }

    fn key(&mut self, code: &str, pressed: bool, repeat: bool) -> Result<(), InputError> {
        self.send_json(serde_json::json!({ "t": "key", "c": code, "p": pressed, "r": repeat }))
    }

    fn set_clipboard(&mut self, text: &str) -> Result<(), InputError> {
        self.send_json(serde_json::json!({ "t": "clip", "s": text }))
    }

    fn poll_clipboard(&mut self) -> Result<Option<String>, InputError> {
        let mut latest = None;
        loop {
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => return Ok(latest),
                Ok(_) => {
                    if let Ok(event) = serde_json::from_str::<HostInputEvent>(line.trim())
                        && event.t == "clip"
                        && !event.s.is_empty()
                        && event.s.len() <= deskfleet_input::MAX_CLIPBOARD_BYTES
                    {
                        latest = Some(event.s);
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) =>
                {
                    return Ok(latest);
                }
                Err(e) => return Err(InputError::Platform(e.to_string())),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;

    use deskfleet_input::{InputEvent, InputSession};

    use super::*;

    #[test]
    fn queries_host_info_with_auth_token() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(s.try_clone().unwrap());
            let mut auth = String::new();
            reader.read_line(&mut auth).unwrap();
            assert_eq!(auth.trim(), "AUTH secret-123");
            s.write_all(b"OK\n").unwrap();
            let mut cmd = String::new();
            reader.read_line(&mut cmd).unwrap();
            assert_eq!(cmd.trim(), "INFO");
            s.write_all(
                br#"{"available":true,"control":true,"width":1179,"height":2556,"fps":60,"codecs":["h265"]}"#,
            )
            .unwrap();
            s.write_all(b"\n").unwrap();
        });

        let info = query_info_from(&addr, "secret-123").unwrap();
        server.join().unwrap();
        assert!(info.available);
        assert!(info.control);
        assert_eq!((info.width, info.height), (1179, 2556));
        assert_eq!(info.codecs, vec!["h265"]);
    }

    #[test]
    fn streams_annex_b_video_and_forwards_keyframe_requests() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert_eq!(line.trim(), "AUTH tok");
            s.write_all(b"OK\n").unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            assert_eq!(line.trim(), "VIDEO h265 60 4000000 0 0");
            s.write_all(b"OK h265 1179 2556\n").unwrap();

            // Send a delta frame (must be skipped while waiting for first keyframe), then a keyframe.
            let delta = [0u8, 0, 0, 1, 0x02, 0x01];
            let mut hdr = [0u8; 14];
            hdr[0] = FRAME_KIND_VIDEO;
            hdr[1] = 0;
            hdr[2..10].copy_from_slice(&1_000u64.to_be_bytes());
            hdr[10..14].copy_from_slice(&(delta.len() as u32).to_be_bytes());
            s.write_all(&hdr).unwrap();
            s.write_all(&delta).unwrap();

            let key = [0u8, 0, 0, 1, 0x26, 0x01, 0xAA];
            hdr[1] = FRAME_FLAG_KEYFRAME;
            hdr[2..10].copy_from_slice(&2_000u64.to_be_bytes());
            hdr[10..14].copy_from_slice(&(key.len() as u32).to_be_bytes());
            s.write_all(&hdr).unwrap();
            s.write_all(&key).unwrap();

            let mut cmd = [0u8; 1];
            s.read_exact(&mut cmd).unwrap();
            assert_eq!(cmd[0], CMD_KEYFRAME);
        });

        let config = DesktopConfig {
            display_id: 0,
            fps: 60.0,
            bitrate_bps: 4_000_000,
            max_bitrate_bps: 0,
            max_width: None,
            max_height: None,
        };
        let mut cap = IosScreenCapture::open_at(&addr, "tok", config, Codec::H265).unwrap();
        let batch = cap.poll(true, None, false).unwrap();
        server.join().unwrap();
        assert_eq!(batch.packets.len(), 1);
        let Packet::Video(bytes, _, pts_ns, is_key) = &batch.packets[0] else {
            panic!("expected video packet");
        };
        assert!(*is_key);
        assert_eq!(*pts_ns, 2_000);
        assert_eq!(&bytes[..], &[0, 0, 0, 1, 0x26, 0x01, 0xAA]);
    }

    #[test]
    fn forwards_input_events_and_receives_clipboard() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert_eq!(line.trim(), "AUTH tok");
            s.write_all(b"OK\n").unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            assert_eq!(line.trim(), "INPUT");
            s.write_all(b"OK\n").unwrap();
            s.write_all(br#"{"t":"clip","s":"from-iphone"}"#).unwrap();
            s.write_all(b"\n").unwrap();

            let mut received = Vec::new();
            loop {
                line.clear();
                if reader.read_line(&mut line).unwrap() == 0 {
                    break;
                }
                received.push(line.trim().to_owned());
            }
            received
        });

        let mut session =
            InputSession::with_backend(|| IosScreenInput::open_at(&addr, "tok")).unwrap();
        session
            .handle(InputEvent::PointerButton {
                button: 0,
                pressed: true,
                x: 0.5,
                y: 0.25,
            })
            .unwrap();
        session
            .handle(InputEvent::Key {
                code: "KeyA".into(),
                pressed: true,
                repeat: false,
            })
            .unwrap();
        assert_eq!(session.poll_clipboard().unwrap().as_deref(), Some("from-iphone"));
        drop(session);

        let lines = server.join().unwrap();
        assert!(lines.iter().any(|l| l.contains(r#""t":"move""#)));
        assert!(lines.iter().any(|l| l.contains(r#""t":"btn""#) && l.contains(r#""p":true"#)));
        assert!(lines.iter().any(|l| l.contains(r#""t":"key""#) && l.contains(r#""c":"KeyA""#)));
        // Drop releases held touch and key
        assert!(lines.iter().any(|l| l.contains(r#""t":"btn""#) && l.contains(r#""p":false"#)));
        assert!(lines.iter().any(|l| l.contains(r#""t":"key""#) && l.contains(r#""p":false"#)));
    }
}
