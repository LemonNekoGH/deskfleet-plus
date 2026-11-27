// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Darwin
import Foundation

/// Pure Foundation protocol, framing, and Annex-B conversion helpers shared between
/// the main DeskFleet Plus app (`DeskFleetBridge`) and the ReplayKit `BroadcastUpload`
/// extension (and unit-tested on macOS without UIKit/ReplayKit).
internal enum IosScreenShareProtocol {
    static let appGroupId = "group.moe.remon.deskfleet.plus"
    static let replayKitSocketFileName = "df-screen.sock"
    static let guestBridgeHost = "192.168.0.254"
    static let coreDeviceHostIp = "10.7.0.1"

    static let frameKindKeepalive: UInt8 = 0
    static let frameKindVideo: UInt8 = 1
    static let frameFlagKeyframe: UInt8 = 1 << 0
    static let controlKindKeyframe: UInt8 = 1
    static let controlKindBitrate: UInt8 = 2
    static let maxFramePayloadBytes = 16 * 1024 * 1024

    struct VideoStreamRequest: Equatable {
        let codec: String
        let fps: Int
        let bitrateBps: Int
        let maxWidth: Int
        let maxHeight: Int
    }

    struct CoreDeviceProbeResult: Equatable {
        let available: Bool
        let control: Bool
        let pasteboard: Bool
        let codecs: [String]
    }

    static func replayKitSocketPath(containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
    )) -> String? {
        guard let containerURL else { return nil }
        return containerURL.appendingPathComponent(replayKitSocketFileName, isDirectory: false).path
    }

    static func normalizeCodec(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h264", "avc":
            return "h264"
        case "h265", "hevc":
            return "h265"
        default:
            return nil
        }
    }

    /// Parses `VIDEO <codec> <fps> <bitrate_bps> <max_w> <max_h>` from the guest daemon.
    static func parseVideoRequest(_ line: String) -> VideoStreamRequest? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6,
              parts[0] == "VIDEO",
              let codec = normalizeCodec(String(parts[1])),
              let fps = Int(parts[2]),
              let bitrate = Int(parts[3]),
              let maxW = Int(parts[4]),
              let maxH = Int(parts[5]) else {
            return nil
        }
        return VideoStreamRequest(
            codec: codec,
            fps: max(1, min(60, fps)),
            bitrateBps: max(100_000, min(25_000_000, bitrate)),
            maxWidth: max(0, maxW),
            maxHeight: max(0, maxH)
        )
    }

    static func encodeReplayKitStartCommand(_ request: VideoStreamRequest) -> Data {
        Data("START \(request.codec) \(request.fps) \(request.bitrateBps) \(request.maxWidth) \(request.maxHeight)\n".utf8)
    }

    static func parseReplayKitStartCommand(_ line: String) -> VideoStreamRequest? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6,
              parts[0] == "START",
              let codec = normalizeCodec(String(parts[1])),
              let fps = Int(parts[2]),
              let bitrate = Int(parts[3]),
              let maxW = Int(parts[4]),
              let maxH = Int(parts[5]) else {
            return nil
        }
        return VideoStreamRequest(
            codec: codec,
            fps: max(1, min(60, fps)),
            bitrateBps: max(100_000, min(25_000_000, bitrate)),
            maxWidth: max(0, maxW),
            maxHeight: max(0, maxH)
        )
    }

    static func encodeGuestInfoJson(
        available: Bool,
        control: Bool,
        width: Int,
        height: Int,
        fps: Double,
        codecs: [String]
    ) -> String {
        let payload: [String: Any] = [
            "available": available,
            "control": control,
            "width": max(0, width),
            "height": max(0, height),
            "fps": fps,
            "codecs": codecs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"available":false,"codecs":[],"control":false,"fps":0,"height":0,"width":0}"#
        }
        return text
    }

    static func parseCoreDeviceProbeJson(_ json: String) -> CoreDeviceProbeResult? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let available = (obj["available"] as? Bool) ?? false
        let control = (obj["control"] as? Bool) ?? false
        let pasteboard = (obj["pasteboard"] as? Bool) ?? false
        let codecs = (obj["codecs"] as? [String]) ?? []
        return CoreDeviceProbeResult(
            available: available,
            control: control,
            pasteboard: pasteboard,
            codecs: codecs
        )
    }

    static func encodeKeepaliveFrame() -> Data {
        Data(repeating: 0, count: 14)
    }

    /// Encodes `[u8 kind=1][u8 flags][u64_be pts_ns][u32_be len][payload]`.
    static func encodeVideoFrame(payload: Data, ptsNs: UInt64, isKeyframe: Bool) -> Data {
        var frame = Data(capacity: 14 + payload.count)
        frame.append(frameKindVideo)
        frame.append(isKeyframe ? frameFlagKeyframe : 0)
        var ptsBe = ptsNs.bigEndian
        withUnsafeBytes(of: &ptsBe) { frame.append(contentsOf: $0) }
        var lenBe = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lenBe) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Decodes a 14-byte video frame header.
    static func decodeFrameHeader(_ header: Data) -> (kind: UInt8, flags: UInt8, ptsNs: UInt64, length: Int)? {
        guard header.count >= 14 else { return nil }
        return header.withUnsafeBytes { raw in
            let kind = raw.load(fromByteOffset: 0, as: UInt8.self)
            let flags = raw.load(fromByteOffset: 1, as: UInt8.self)
            let pts = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 2, as: UInt64.self))
            let len = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 10, as: UInt32.self)))
            return (kind, flags, pts, len)
        }
    }

    /// Scales source dimensions to fit within `maxWidth x maxHeight` while preserving
    /// aspect ratio and rounding down to even numbers (>= 2) required by YUV 4:2:0 encoders.
    static func computeScaledEvenDimensions(
        srcWidth: Int,
        srcHeight: Int,
        maxWidth: Int,
        maxHeight: Int
    ) -> (width: Int, height: Int) {
        let sw = max(2, srcWidth & ~1)
        let sh = max(2, srcHeight & ~1)
        let limitW = maxWidth > 0 ? maxWidth : sw
        let limitH = maxHeight > 0 ? maxHeight : sh
        if sw <= limitW && sh <= limitH {
            return (sw, sh)
        }
        let scale = min(Double(limitW) / Double(sw), Double(limitH) / Double(sh))
        let outW = max(2, (Int((Double(sw) * scale).rounded(.down)) & ~1))
        let outH = max(2, (Int((Double(sh) * scale).rounded(.down)) & ~1))
        return (outW, outH)
    }

    /// Splits an Annex-B byte stream (`00 00 01` or `00 00 00 01` delimiters) into raw NAL units.
    static func splitAnnexBNalUnits(_ data: Data) -> [Data] {
        let count = data.count
        guard count >= 4 else { return [] }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return []
            }
            var starts: [(prefix: Int, start: Int)] = []
            var i = 0
            while i + 3 <= count {
                if base[i] == 0 && base[i + 1] == 0 {
                    if base[i + 2] == 1 {
                        starts.append((i, i + 3))
                        i += 3
                        continue
                    }
                    if i + 4 <= count && base[i + 2] == 0 && base[i + 3] == 1 {
                        starts.append((i, i + 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }
            guard !starts.isEmpty else { return [] }
            var result: [Data] = []
            result.reserveCapacity(starts.count)
            for idx in 0..<starts.count {
                let nalStart = starts[idx].start
                let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].prefix : count
                if nalEnd > nalStart {
                    result.append(Data(bytes: base.advanced(by: nalStart), count: nalEnd - nalStart))
                }
            }
            return result
        }
    }

    /// Converts 4-byte length-prefixed AVCC/HVCC NAL units from VideoToolbox into Annex-B
    /// (`00 00 00 01`), optionally prepending parameter sets (SPS/PPS or VPS/SPS/PPS) on keyframes.
    static func convertLengthPrefixedToAnnexB(
        avccData: Data,
        parameterSets: [Data],
        prependParameterSets: Bool
    ) -> Data {
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var extraBytes = 0
        if prependParameterSets {
            for ps in parameterSets where !ps.isEmpty {
                extraBytes += 4 + ps.count
            }
        }
        var out = Data(capacity: avccData.count + extraBytes + 16)
        if prependParameterSets {
            for ps in parameterSets where !ps.isEmpty {
                out.append(contentsOf: startCode)
                out.append(ps)
            }
        }
        avccData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset + 4 <= total {
                let nalLen = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                offset += 4
                guard nalLen > 0, offset + nalLen <= total else { break }
                out.append(contentsOf: startCode)
                out.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: nalLen)
                offset += nalLen
            }
        }
        return out
    }

    // MARK: - POSIX Socket I/O Helpers

    static func configureNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func posixWriteAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            let total = raw.count
            while sent < total {
                let n = Darwin.write(fd, base.advanced(by: sent), total - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func posixReadExact(fd: Int32, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        var buf = Data(count: count)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var received = 0
            while received < count {
                let n = Darwin.read(fd, base.advanced(by: received), count - received)
                if n > 0 {
                    received += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? buf : nil
    }

    static func posixReadLine(fd: Int32, maxBytes: Int = 8192) -> String? {
        var bytes = Data()
        bytes.reserveCapacity(128)
        var ch: UInt8 = 0
        while bytes.count < maxBytes {
            let n = Darwin.read(fd, &ch, 1)
            if n == 1 {
                if ch == 0x0A {
                    return String(data: bytes, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                bytes.append(ch)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }

    /// Creates and binds an `AF_UNIX` `SOCK_STREAM` listener at `path`.
    static func bindUnixListener(path: String, backlog: Int32 = 4) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        configureNoSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            return -1
        }
        _ = path.withCString { Darwin.unlink($0) }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: pathBytes)
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        guard bindRes == 0, Darwin.listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    /// Connects to an `AF_UNIX` `SOCK_STREAM` server at `path`.
    static func connectUnixSocket(path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        configureNoSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: pathBytes)
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        guard connectRes == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }
}
