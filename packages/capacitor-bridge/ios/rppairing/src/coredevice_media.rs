//! HEVC access-unit framing, RTP sequence/timestamp tracking, and RTCP report helpers
//! for the iOS CoreDevice display stream.

use std::ffi::c_void;
use std::time::Instant;

use idevice::core_device::{HevcDepacketizer, ReportBlock};

use crate::coredevice_input::SendCtx;

pub type FrameCallback = extern "C" fn(
    ctx: *mut c_void,
    data: *const u8,
    len: usize,
    pts_ns: u64,
    is_keyframe: bool,
);

/// Strips HEVC Access Unit Delimiter (AUD, NAL type 35) units from an Annex-B buffer,
/// re-emitting remaining NALs with 4-byte start codes, and reports `(cleaned, has_vcl, is_keyframe)`.
///
/// `HevcDepacketizer` prepends an AUD NAL (`00 00 00 01 46 01 50`) on every timestamp transition
/// after frame 1, which can trip strict VideoToolbox HVCC decoders (`kVTVideoDecoderBadDataErr`).
pub(crate) fn clean_hevc_access_unit(data: &[u8]) -> (Vec<u8>, bool, bool) {
    let mut starts: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 {
            if data[i + 2] == 1 {
                starts.push((i, i + 3));
                i += 3;
                continue;
            }
            if i + 4 <= data.len() && data[i + 2] == 0 && data[i + 3] == 1 {
                starts.push((i, i + 4));
                i += 4;
                continue;
            }
        }
        i += 1;
    }

    let mut out = Vec::with_capacity(data.len());
    let mut has_vcl = false;
    let mut is_keyframe = false;
    for (idx, &(_, nal_start)) in starts.iter().enumerate() {
        let nal_end = starts
            .get(idx + 1)
            .map_or(data.len(), |&(next_prefix, _)| next_prefix);
        if nal_start + 2 > nal_end {
            continue;
        }
        let nal = &data[nal_start..nal_end];
        let nal_type = (nal[0] >> 1) & 0x3f;
        if nal_type == 35 {
            continue;
        }
        if nal_type <= 31 {
            has_vcl = true;
            if (16..=23).contains(&nal_type) {
                is_keyframe = true;
            }
        }
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(nal);
    }
    (out, has_vcl, is_keyframe)
}

pub(crate) fn build_report_block(
    media_ssrc: u32,
    highest_seq: u32,
    lsr: u32,
    last_sr_at: Option<Instant>,
) -> ReportBlock {
    let dlsr = last_sr_at
        .map(|t| (t.elapsed().as_secs_f64() * 65536.0) as u32)
        .unwrap_or(0);
    ReportBlock {
        source_ssrc: media_ssrc,
        fraction_lost: 0,
        cumulative_lost: 0,
        highest_seq,
        jitter: 0,
        lsr,
        dlsr,
    }
}

pub(crate) fn rtp_ts_to_ns(rtp_ts: u32, first_ts: &mut Option<u32>, last_pts_ns: &mut u64) -> u64 {
    let origin = *first_ts.get_or_insert(rtp_ts);
    let delta_ticks = u64::from(rtp_ts.wrapping_sub(origin));
    // 90 kHz clock -> nanoseconds: ticks * 1_000_000_000 / 90_000 = ticks * 100_000 / 9
    let pts = delta_ticks.saturating_mul(100_000) / 9;
    let monotonic = if pts > *last_pts_ns {
        pts
    } else {
        last_pts_ns.saturating_add(1_000)
    };
    *last_pts_ns = monotonic;
    monotonic
}

pub(crate) struct VideoLoopState {
    pub depacketizer: HevcDepacketizer,
    pub sender_ssrc: Option<u32>,
    pub last_sr_lsr: u32,
    pub last_sr_at: Option<Instant>,
    pub highest_seq: u16,
    pub seq_cycles: u16,
    pub base_seq: Option<u16>,
    pub frame_count: u16,
    pub total_frames: u64,
    pub rtp_packets: u64,
    pub audio_packets: u64,
    pub audio_sender_ssrc: Option<u32>,
    pub audio_sr_lsr: u32,
    pub audio_sr_at: Option<Instant>,
    pub fir_seq: u8,
    pub first_rtp_ts: Option<u32>,
    pub current_au_ts: Option<u32>,
    pub last_pts_ns: u64,
    pub pending_prefix: Vec<u8>,
    pub empty_marker_streak: u32,
    pub stalled_since: Option<Instant>,
    pub last_video_rtp_at: Instant,
    pub liveness_sent: u64,
    pub rctl_sent: u64,
    pub pending_keyframe: bool,
    pub consecutive_restarts: u32,
}

impl VideoLoopState {
    pub fn new() -> Self {
        Self {
            depacketizer: HevcDepacketizer::new(),
            sender_ssrc: None,
            last_sr_lsr: 0,
            last_sr_at: None,
            highest_seq: 0,
            seq_cycles: 0,
            base_seq: None,
            frame_count: 0,
            total_frames: 0,
            rtp_packets: 0,
            audio_packets: 0,
            audio_sender_ssrc: None,
            audio_sr_lsr: 0,
            audio_sr_at: None,
            fir_seq: 0,
            first_rtp_ts: None,
            current_au_ts: None,
            last_pts_ns: 0,
            pending_prefix: Vec::new(),
            empty_marker_streak: 0,
            stalled_since: None,
            last_video_rtp_at: Instant::now(),
            liveness_sent: 0,
            rctl_sent: 0,
            pending_keyframe: true,
            consecutive_restarts: 0,
        }
    }

    pub fn reset_for_stream_restart(&mut self) {
        self.depacketizer = HevcDepacketizer::new();
        self.sender_ssrc = None;
        self.last_sr_lsr = 0;
        self.last_sr_at = None;
        self.highest_seq = 0;
        self.seq_cycles = 0;
        self.base_seq = None;
        self.audio_sender_ssrc = None;
        self.audio_sr_lsr = 0;
        self.audio_sr_at = None;
        self.first_rtp_ts = None;
        self.current_au_ts = None;
        self.pending_prefix.clear();
        self.empty_marker_streak = 0;
        self.stalled_since = None;
        self.last_video_rtp_at = Instant::now();
        self.pending_keyframe = true;
    }

    pub fn extended_highest_seq(&self) -> u32 {
        (u32::from(self.seq_cycles) << 16) | u32::from(self.highest_seq)
    }

    pub fn record_seq(&mut self, seq: u16) {
        if self.base_seq.is_none() {
            self.base_seq = Some(seq);
            self.highest_seq = seq;
            return;
        }
        let delta = seq.wrapping_sub(self.highest_seq);
        if delta > 0 && delta < 0x8000 {
            if seq < self.highest_seq {
                self.seq_cycles = self.seq_cycles.wrapping_add(1);
            }
            self.highest_seq = seq;
        }
    }

    pub fn emit_au(
        &mut self,
        raw: Vec<u8>,
        rtp_ts: u32,
        on_frame: FrameCallback,
        ctx: SendCtx,
        sender_port: u16,
    ) -> bool {
        let (mut cleaned, has_vcl, is_key) = clean_hevc_access_unit(&raw);
        if cleaned.is_empty() {
            return false;
        }
        if !has_vcl {
            self.pending_prefix.extend_from_slice(&cleaned);
            return false;
        }
        if !self.pending_prefix.is_empty() {
            let mut combined = Vec::with_capacity(self.pending_prefix.len() + cleaned.len());
            combined.extend_from_slice(&self.pending_prefix);
            combined.extend_from_slice(&cleaned);
            self.pending_prefix.clear();
            cleaned = combined;
        }
        let pts_ns = rtp_ts_to_ns(rtp_ts, &mut self.first_rtp_ts, &mut self.last_pts_ns);
        on_frame(ctx.0, cleaned.as_ptr(), cleaned.len(), pts_ns, is_key);
        self.frame_count = self.frame_count.wrapping_add(1);
        self.total_frames += 1;
        self.consecutive_restarts = 0;
        let _ = sender_port;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_hevc_irap_keyframes_and_strips_aud() {
        let keyframe = [
            0, 0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 0, 1, 0x26, 0x01, 0xCC,
        ];
        assert!(clean_hevc_access_unit(&keyframe).2);

        let delta = [0, 0, 0, 1, 0x02, 0x01, 0xDD];
        assert!(!clean_hevc_access_unit(&delta).2);

        let with_aud = [0, 0, 0, 1, 0x46, 0x01, 0x50, 0, 0, 0, 1, 0x02, 0x01, 0xDD];
        let (cleaned, has_vcl, is_key) = clean_hevc_access_unit(&with_aud);
        assert_eq!(cleaned, delta);
        assert!(has_vcl);
        assert!(!is_key);
    }

    #[test]
    fn tracks_extended_sequence_number_across_wraparound() {
        let mut st = VideoLoopState::new();
        st.record_seq(65534);
        st.record_seq(65535);
        assert_eq!(st.extended_highest_seq(), 65535);
        st.record_seq(0);
        assert_eq!(st.extended_highest_seq(), 65536);
        st.record_seq(1);
        assert_eq!(st.extended_highest_seq(), 65537);
        // Out-of-order older packet must not bump cycles.
        st.record_seq(65535);
        assert_eq!(st.extended_highest_seq(), 65537);
    }
}
