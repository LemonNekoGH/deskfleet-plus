//! Native arm64 CoreDevice screen streaming (`com.apple.coredevice.displayservice`),
//! HID remote control (`com.apple.coredevice.hid.universalhidservice` + `.indigo`),
//! and bidirectional clipboard sync (`com.apple.coredevice.pasteboardservice`)
//! over LocalDevVPN (`10.7.0.1`) + lockdown pairing file.

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use idevice::core_device::{
    CallInfoBlob, DisplayServiceClient, HevcDepacketizer, ReportBlock, RtpPacket, SenderReport,
    build_frame_ack, build_keyframe_request, build_liveness, build_rctl, build_screen_audio_offer,
    build_screen_video_offer, build_start_audio_parameters, build_start_video_parameters, is_rtcp,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::{AdapterHandle, UdpSocketHandle};
use idevice::{ReadWrite, RsdService};
use tokio::sync::mpsc;

use crate::coredevice_input::{
    ClipboardCallback, InputCommand, SendCtx, run_input_and_clipboard_task,
};
use crate::coredevice_media::{FrameCallback, VideoLoopState, build_report_block};
use crate::coredevice_tunnel::open_coredevice_rsd;

const CLIENT_SUPPORTED_FEATURES: u64 = 140;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const PROBE_TIMEOUT: Duration = Duration::from_secs(6);

pub type ClosedCallback = extern "C" fn(ctx: *mut c_void, error_or_null: *const c_char);

enum SessionControl {
    Keyframe,
    Input(InputCommand),
    Stop,
}

struct CoreDeviceSessionHandle {
    tx: mpsc::UnboundedSender<SessionControl>,
    stopped: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}

fn write_c_string(out: *mut *mut c_char, text: String) {
    if !out.is_null() {
        let sanitized = text.replace('\0', " ");
        if let Ok(cs) = CString::new(sanitized) {
            unsafe { *out = cs.into_raw() };
        }
    }
}

fn read_c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

struct ActiveMediaStream {
    client: DisplayServiceClient<Box<dyn ReadWrite>>,
    audio_udp: UdpSocketHandle,
    video_udp: UdpSocketHandle,
    audio_our_ssrc: u32,
    our_ssrc: u32,
    cname: String,
    audio_sender_port: u16,
    video_sender_port: u16,
}

async fn start_media_stream(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    display_id: i64,
) -> Result<ActiveMediaStream, String> {
    let mut client = DisplayServiceClient::connect_rsd(adapter, handshake)
        .await
        .map_err(|e| format!("com.apple.coredevice.displayservice unavailable: {e}"))?;

    let audio_udp = adapter
        .bind_udp(0)
        .await
        .map_err(|e| format!("bind_udp(audio) failed: {e}"))?;
    let video_udp = adapter
        .bind_udp(0)
        .await
        .map_err(|e| format!("bind_udp(video) failed: {e}"))?;

    let receiver_ip = adapter.host_ip().to_string();
    let sender_ip = adapter.peer_ip().to_string();
    let audio_receiver_port = audio_udp.local_port();
    let video_receiver_port = video_udp.local_port();
    let audio_sender_port: u16 = 50000;
    let video_sender_port: u16 = 50001;

    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };

    let client_session_id = uuid::Uuid::new_v4();

    // Establish the screen-sharing session with the audio channel first (required by AVConference).
    let audio_call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let audio_our_ssrc = (uuid::Uuid::new_v4().as_u128() as u32).max(1);
    let audio_offer = build_screen_audio_offer(&audio_call_id, &call_info)
        .map_err(|e| format!("audio offer build failed: {e}"))?;
    let audio_params = build_start_audio_parameters(
        &receiver_ip,
        audio_receiver_port,
        &sender_ip,
        audio_sender_port,
        audio_offer,
        CLIENT_SUPPORTED_FEATURES,
        client_session_id,
    );
    client
        .start_media_stream(audio_params)
        .await
        .map_err(|e| format!("audio startMediaStream failed: {e}"))?;

    // Start the HEVC video channel on the same clientSessionID.
    let video_call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let our_ssrc = (uuid::Uuid::new_v4().as_u128() as u32).max(1);
    let video_offer = build_screen_video_offer(&video_call_id, &call_info, our_ssrc)
        .map_err(|e| format!("video offer build failed: {e}"))?;
    let video_params = build_start_video_parameters(
        &receiver_ip,
        video_receiver_port,
        &sender_ip,
        video_sender_port,
        video_offer,
        CLIENT_SUPPORTED_FEATURES,
        display_id,
        client_session_id,
    );
    let _answer = client
        .start_media_stream(video_params)
        .await
        .map_err(|e| format!("video startMediaStream failed: {e}"))?;

    let cname = format!("deskfleet@{receiver_ip}");
    Ok(ActiveMediaStream {
        client,
        audio_udp,
        video_udp,
        audio_our_ssrc,
        our_ssrc,
        cname,
        audio_sender_port,
        video_sender_port,
    })
}

async fn run_session(
    mut adapter: AdapterHandle,
    mut handshake: RsdHandshake,
    display_id: i64,
    mut stream: ActiveMediaStream,
    mut rx: mpsc::UnboundedReceiver<SessionControl>,
    stopped: Arc<AtomicBool>,
    on_frame: FrameCallback,
    on_clipboard: Option<ClipboardCallback>,
    on_closed: Option<ClosedCallback>,
    ctx: SendCtx,
) {
    let (input_tx, input_rx) = mpsc::unbounded_channel::<InputCommand>();
    let input_task = tokio::task::spawn_local(run_input_and_clipboard_task(
        adapter.clone(),
        handshake.clone(),
        input_rx,
        Arc::clone(&stopped),
        on_clipboard,
        ctx,
    ));

    let mut st = VideoLoopState::new();
    let started_at = Instant::now();
    let mut logged_send_err = false;

    let mut rctl_interval = tokio::time::interval(Duration::from_millis(50));
    rctl_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut liveness_interval = tokio::time::interval(Duration::from_secs(1));
    liveness_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    eprintln!(
        "[CoreDevice] media session started: video_local_port={} audio_local_port={}",
        stream.video_udp.local_port(),
        stream.audio_udp.local_port()
    );

    let close_error: Option<String> = loop {
        if stopped.load(Ordering::Acquire) {
            break None;
        }
        tokio::select! {
            ctrl = rx.recv() => {
                match ctrl {
                    Some(SessionControl::Stop) | None => break None,
                    Some(SessionControl::Keyframe) => {
                        st.pending_keyframe = true;
                        if let Some(media_ssrc) = st.sender_ssrc {
                            st.fir_seq = st.fir_seq.wrapping_add(1);
                            let block = build_report_block(media_ssrc, st.extended_highest_seq(), st.last_sr_lsr, st.last_sr_at);
                            let req = build_keyframe_request(stream.our_ssrc, &stream.cname, media_ssrc, &[block], st.fir_seq);
                            let _ = stream.video_udp.send_to(stream.video_sender_port, req).await;
                            st.pending_keyframe = false;
                        }
                    }
                    Some(SessionControl::Input(cmd)) => {
                        let _ = input_tx.send(cmd);
                    }
                }
            }
            audio = stream.audio_udp.recv() => {
                if let Ok(dg) = audio {
                    st.audio_packets += 1;
                    if dg.source_port != 0 && dg.source_port != stream.audio_sender_port {
                        eprintln!("[CoreDevice] audio sender port updated: {} -> {}", stream.audio_sender_port, dg.source_port);
                        stream.audio_sender_port = dg.source_port;
                    }
                    if is_rtcp(&dg.data) {
                        if let Some(sr) = SenderReport::parse_first(&dg.data) {
                            st.audio_sender_ssrc = Some(sr.ssrc);
                            st.audio_sr_lsr = sr.ntp_middle;
                            st.audio_sr_at = Some(Instant::now());
                        }
                    }
                }
            }
            video = stream.video_udp.recv() => {
                match video {
                    Ok(dg) => {
                        if dg.source_port != 0 && dg.source_port != stream.video_sender_port {
                            eprintln!("[CoreDevice] video sender port updated: {} -> {}", stream.video_sender_port, dg.source_port);
                            stream.video_sender_port = dg.source_port;
                        }
                        if is_rtcp(&dg.data) {
                            if let Some(sr) = SenderReport::parse_first(&dg.data) {
                                st.sender_ssrc = Some(sr.ssrc);
                                st.last_sr_lsr = sr.ntp_middle;
                                st.last_sr_at = Some(Instant::now());
                            }
                            continue;
                        }
                        let Some(pkt) = RtpPacket::parse(&dg.data) else { continue; };
                        st.rtp_packets += 1;
                        st.last_video_rtp_at = Instant::now();
                        if st.sender_ssrc.is_none() {
                            st.sender_ssrc = Some(pkt.ssrc);
                        }
                        st.record_seq(pkt.sequence_number);

                        if let Some(prev_ts) = st.current_au_ts {
                            if prev_ts != pkt.timestamp {
                                let out = st.depacketizer.take_output();
                                if !out.is_empty() && st.emit_au(out, prev_ts, on_frame, ctx, stream.video_sender_port) {
                                    st.empty_marker_streak = 0;
                                    st.stalled_since = None;
                                }
                            }
                        }
                        st.current_au_ts = Some(pkt.timestamp);
                        st.depacketizer.push(pkt.sequence_number, pkt.timestamp, pkt.payload);

                        if pkt.marker {
                            let out = st.depacketizer.take_output();
                            let emitted = !out.is_empty()
                                && st.emit_au(out, pkt.timestamp, on_frame, ctx, stream.video_sender_port);
                            if emitted {
                                st.empty_marker_streak = 0;
                                st.stalled_since = None;
                                let ack = build_frame_ack(stream.our_ssrc, pkt.timestamp);
                                if let Err(e) = stream.video_udp.send_to(stream.video_sender_port, ack).await {
                                    if !logged_send_err {
                                        eprintln!("[CoreDevice] video UDP send_to error: {e}");
                                        logged_send_err = true;
                                    }
                                }
                            } else {
                                st.empty_marker_streak += 1;
                                let since = *st.stalled_since.get_or_insert_with(Instant::now);
                                if st.empty_marker_streak >= 2 || since.elapsed() >= Duration::from_millis(150) {
                                    st.depacketizer = HevcDepacketizer::new();
                                    st.pending_prefix.clear();
                                    st.empty_marker_streak = 0;
                                    st.stalled_since = None;
                                    st.pending_keyframe = true;
                                }
                            }
                            st.current_au_ts = None;
                        }

                        if st.pending_keyframe {
                            if let Some(media_ssrc) = st.sender_ssrc {
                                st.fir_seq = st.fir_seq.wrapping_add(1);
                                let block = build_report_block(media_ssrc, st.extended_highest_seq(), st.last_sr_lsr, st.last_sr_at);
                                let req = build_keyframe_request(stream.our_ssrc, &stream.cname, media_ssrc, &[block], st.fir_seq);
                                let _ = stream.video_udp.send_to(stream.video_sender_port, req).await;
                                st.pending_keyframe = false;
                            }
                        }
                    }
                    Err(e) => {
                        break Some(format!("CoreDevice video stream closed: {e}"));
                    }
                }
            }
            _ = rctl_interval.tick() => {
                if let Some(base) = st.base_seq {
                    let clock_ms = (started_at.elapsed().as_millis() & 0xFFFF) as u16;
                    let rel_seq = st.highest_seq.wrapping_sub(base);
                    let rctl = build_rctl(stream.our_ssrc, clock_ms, st.frame_count, rel_seq);
                    st.rctl_sent += 1;
                    let _ = stream.video_udp.send_to(stream.video_sender_port, rctl).await;
                }
            }
            _ = liveness_interval.tick() => {
                let blocks: Vec<ReportBlock> = st.sender_ssrc
                    .map(|ssrc| build_report_block(ssrc, st.extended_highest_seq(), st.last_sr_lsr, st.last_sr_at))
                    .into_iter()
                    .collect();
                let liveness = build_liveness(stream.our_ssrc, &stream.cname, &blocks);
                st.liveness_sent += 1;
                if let Err(e) = stream.video_udp.send_to(stream.video_sender_port, liveness).await {
                    if !logged_send_err {
                        eprintln!("[CoreDevice] video liveness send_to error: {e}");
                        logged_send_err = true;
                    }
                }
                // Keep the companion audio stream alive so AVConference never tears down the session.
                let audio_blocks: Vec<ReportBlock> = st.audio_sender_ssrc
                    .map(|ssrc| build_report_block(ssrc, 0, st.audio_sr_lsr, st.audio_sr_at))
                    .into_iter()
                    .collect();
                let audio_liveness = build_liveness(stream.audio_our_ssrc, &stream.cname, &audio_blocks);
                let _ = stream.audio_udp.send_to(stream.audio_sender_port, audio_liveness).await;

                if st.last_video_rtp_at.elapsed() >= Duration::from_secs(4) {
                    let status_note = match tokio::time::timeout(
                        Duration::from_secs(2),
                        stream.client.get_media_stream_server_status(),
                    )
                    .await
                    {
                        Ok(Ok(val)) => format!("status_keys={:?}", val.as_dictionary().map(|d| d.keys().collect::<Vec<_>>())),
                        Ok(Err(e)) => format!("status_err={e}"),
                        Err(_) => "status_timeout".to_string(),
                    };
                    eprintln!(
                        "[CoreDevice] video RTP stalled for {}s (frames={} rtp={} audio={} liveness={} rctl={} {status_note}); restarting media stream",
                        st.last_video_rtp_at.elapsed().as_secs(),
                        st.total_frames,
                        st.rtp_packets,
                        st.audio_packets,
                        st.liveness_sent,
                        st.rctl_sent
                    );
                    let _ = tokio::time::timeout(Duration::from_millis(750), stream.client.stop_media_stream()).await;
                    st.consecutive_restarts += 1;
                    if st.consecutive_restarts > 5 {
                        break Some("CoreDevice display stream stopped repeatedly".to_string());
                    }
                    match tokio::time::timeout(
                        CONNECT_TIMEOUT,
                        start_media_stream(&mut adapter, &mut handshake, display_id),
                    )
                    .await
                    {
                        Ok(Ok(next_stream)) => {
                            stream = next_stream;
                            st.reset_for_stream_restart();
                            eprintln!(
                                "[CoreDevice] media stream restarted: video_local_port={}",
                                stream.video_udp.local_port()
                            );
                        }
                        Ok(Err(e)) => break Some(format!("CoreDevice stream restart failed: {e}")),
                        Err(_) => break Some("CoreDevice stream restart timed out".to_string()),
                    }
                }
            }
        }
    };

    stopped.store(true, Ordering::Release);
    drop(input_tx);
    let _ = tokio::time::timeout(Duration::from_secs(1), input_task).await;
    let _ = tokio::time::timeout(Duration::from_millis(750), stream.client.stop_media_stream()).await;
    eprintln!(
        "[CoreDevice] media session stopped: total_frames={} rtp_pkts={} err={:?}",
        st.total_frames, st.rtp_packets, close_error
    );

    if let Some(cb) = on_closed {
        if let Some(err) = close_error {
            if let Ok(cs) = CString::new(err.replace('\0', " ")) {
                cb(ctx.0, cs.as_ptr());
            } else {
                cb(ctx.0, std::ptr::null());
            }
        } else {
            cb(ctx.0, std::ptr::null());
        }
    }
}

/// Probes CoreDevice RSD services on `host_ip` (typically `"10.7.0.1"`) using `pairing_path`.
#[no_mangle]
pub unsafe extern "C" fn deskfleet_coredevice_probe(
    host_ip: *const c_char,
    pairing_path: *const c_char,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let host_ip = read_c_str(host_ip).unwrap_or_else(|| "10.7.0.1".to_string());
    let Some(pairing_path) = read_c_str(pairing_path) else {
        write_c_string(out_error, "Missing pairing file path".to_string());
        return -1;
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            write_c_string(out_error, format!("Failed to create CoreDevice runtime: {e}"));
            return -1;
        }
    };
    let res = runtime.block_on(async {
        let (_adapter, handshake) =
            tokio::time::timeout(PROBE_TIMEOUT, open_coredevice_rsd(&host_ip, &pairing_path))
                .await
                .map_err(|_| format!("Timed out probing CoreDevice RSD on {host_ip}"))??;
        let has_display = handshake
            .services
            .contains_key("com.apple.coredevice.displayservice");
        let has_touch = handshake
            .services
            .contains_key("com.apple.coredevice.hid.universalhidservice");
        let has_indigo = handshake
            .services
            .contains_key("com.apple.coredevice.hid.indigo");
        let has_pasteboard = handshake
            .services
            .contains_key("com.apple.coredevice.pasteboardservice");
        let service_count = handshake.services.len();
        let json = serde_json::json!({
            "available": has_display,
            "control": has_display && (has_touch || has_indigo),
            "pasteboard": has_pasteboard,
            "codecs": if has_display { vec!["h265"] } else { Vec::<&str>::new() },
            "serviceCount": service_count,
            "services": {
                "display": has_display,
                "touch": has_touch,
                "indigo": has_indigo,
                "pasteboard": has_pasteboard,
            }
        });
        Ok::<String, String>(json.to_string())
    });

    match res {
        Ok(json) => {
            write_c_string(out_json, json);
            0
        }
        Err(err) => {
            write_c_string(out_error, err);
            -1
        }
    }
}

/// Starts a CoreDevice displayservice HEVC stream + HID/Pasteboard remote control session.
#[no_mangle]
pub unsafe extern "C" fn deskfleet_coredevice_session_start(
    host_ip: *const c_char,
    pairing_path: *const c_char,
    display_id: i64,
    on_frame: Option<FrameCallback>,
    on_clipboard: Option<ClipboardCallback>,
    on_closed: Option<ClosedCallback>,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> *mut c_void {
    let host_ip = read_c_str(host_ip).unwrap_or_else(|| "10.7.0.1".to_string());
    let Some(pairing_path) = read_c_str(pairing_path) else {
        write_c_string(out_error, "Missing pairing file path".to_string());
        return std::ptr::null_mut();
    };
    let Some(on_frame) = on_frame else {
        write_c_string(out_error, "Missing frame callback".to_string());
        return std::ptr::null_mut();
    };

    let (tx, rx) = mpsc::unbounded_channel();
    let stopped = Arc::new(AtomicBool::new(false));
    let stopped_worker = Arc::clone(&stopped);
    let send_ctx = SendCtx(ctx);
    let display_id = display_id.max(1);
    let (startup_tx, startup_rx) = std::sync::mpsc::sync_channel::<Result<(), String>>(1);

    let worker = match std::thread::Builder::new()
        .name("ios-coredevice".to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = startup_tx.send(Err(format!("Failed to build CoreDevice runtime: {e}")));
                    return;
                }
            };

            let init = runtime.block_on(async {
                let (mut adapter, mut handshake) = tokio::time::timeout(
                    CONNECT_TIMEOUT,
                    open_coredevice_rsd(&host_ip, &pairing_path),
                )
                .await
                .map_err(|_| format!("Timed out connecting to CoreDevice on {host_ip}"))??;
                let stream = tokio::time::timeout(
                    CONNECT_TIMEOUT,
                    start_media_stream(&mut adapter, &mut handshake, display_id),
                )
                .await
                .map_err(|_| "Timed out starting CoreDevice display stream".to_string())??;
                Ok::<_, String>((adapter, handshake, stream))
            });

            let (adapter, handshake, stream) = match init {
                Ok(v) => {
                    let _ = startup_tx.send(Ok(()));
                    v
                }
                Err(err) => {
                    let _ = startup_tx.send(Err(err));
                    return;
                }
            };

            let local = tokio::task::LocalSet::new();
            runtime.block_on(local.run_until(run_session(
                adapter,
                handshake,
                display_id,
                stream,
                rx,
                stopped_worker,
                on_frame,
                on_clipboard,
                on_closed,
                send_ctx,
            )));
        }) {
        Ok(handle) => handle,
        Err(e) => {
            write_c_string(out_error, format!("Failed to spawn CoreDevice thread: {e}"));
            return std::ptr::null_mut();
        }
    };

    match startup_rx.recv() {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            let _ = worker.join();
            write_c_string(out_error, err);
            return std::ptr::null_mut();
        }
        Err(_) => {
            let _ = worker.join();
            write_c_string(
                out_error,
                "CoreDevice worker exited during startup".to_string(),
            );
            return std::ptr::null_mut();
        }
    }

    let handle = Box::new(CoreDeviceSessionHandle {
        tx,
        stopped,
        worker: Some(worker),
    });
    Box::into_raw(handle) as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn deskfleet_coredevice_session_request_keyframe(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let session = unsafe { &*(handle as *const CoreDeviceSessionHandle) };
    let _ = session.tx.send(SessionControl::Keyframe);
}

#[no_mangle]
pub unsafe extern "C" fn deskfleet_coredevice_session_send_input(
    handle: *mut c_void,
    command_json: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let Some(text) = read_c_str(command_json) else {
        return -1;
    };
    let Ok(cmd) = serde_json::from_str::<InputCommand>(&text) else {
        return -1;
    };
    let session = unsafe { &*(handle as *const CoreDeviceSessionHandle) };
    if session.stopped.load(Ordering::Acquire) {
        return -1;
    }
    if session.tx.send(SessionControl::Input(cmd)).is_ok() {
        0
    } else {
        -1
    }
}

#[no_mangle]
pub unsafe extern "C" fn deskfleet_coredevice_session_stop(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let mut session = unsafe { Box::from_raw(handle as *mut CoreDeviceSessionHandle) };
    session.stopped.store(true, Ordering::Release);
    let _ = session.tx.send(SessionControl::Stop);
    if let Some(worker) = session.worker.take() {
        let _ = worker.join();
    }
}
