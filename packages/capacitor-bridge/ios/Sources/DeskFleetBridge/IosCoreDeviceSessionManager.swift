// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import CoreVideo
import Darwin
import Foundation
import IshPlusRPPairing

/// Owns the single shared Apple CoreDevice session (`displayservice` HEVC +
/// `universalhidservice`/`indigo` HID + `pasteboardservice`), decodes the
/// incoming HEVC stream once via hardware `VTDecompressionSession`, and fans
/// out `CVPixelBuffer`s to connected guest video subscribers (each encoding to
/// its requested H.265/H.264 profile, resolution, fps, and bitrate).
internal final class IosCoreDeviceSessionManager: @unchecked Sendable {
    final class InputSubscriber {
        let id = UUID()
        let fd: Int32
        private let queue = DispatchQueue(label: "moe.remon.deskfleet.plus.input-sub", qos: .utility)

        init(fd: Int32) {
            self.fd = fd
        }

        func sendClipboard(_ text: String) {
            let payload: [String: Any] = ["t": "clip", "s": text]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: jsonData, encoding: .utf8) else {
                return
            }
            line.append("\n")
            let bytes = Data(line.utf8)
            queue.async { [fd] in
                _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: bytes)
            }
        }
    }

    private let pairingFileURLProvider: () -> URL
    private let onSessionClosed: (String?) -> Void
    private let lock = NSLock()
    private let lifecycleQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.coredevice.lifecycle", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.coredevice.decode", qos: .userInteractive)
    private let decoder = IosCoreDeviceHevcDecoder()

    private var handle: UnsafeMutableRawPointer?
    private var videoSubscribers: [UUID: IosCoreDeviceVideoSubscriber] = [:]
    private var inputSubscribers: [UUID: InputSubscriber] = [:]
    private var stopWorkItem: DispatchWorkItem?
    private var lastDecodedBuffer: CVPixelBuffer?
    private var lastDecodedPtsNs: UInt64 = 0

    init(
        pairingFileURLProvider: @escaping () -> URL,
        onSessionClosed: @escaping (String?) -> Void
    ) {
        self.pairingFileURLProvider = pairingFileURLProvider
        self.onSessionClosed = onSessionClosed
    }

    deinit {
        stopNow()
    }

    /// Ensures the shared CoreDevice session is running without attaching the subscriber yet,
    /// so the caller can write its TCP handshake line (`OK ...`) before any media/clipboard
    /// payloads are queued on the socket.
    func ensureSessionRunning() throws {
        try lifecycleQueue.sync {
            lock.lock()
            stopWorkItem?.cancel()
            stopWorkItem = nil
            let existing = handle
            lock.unlock()

            if existing != nil { return }

            let pairingPath = pairingFileURLProvider().path
            var outErr: UnsafeMutablePointer<CChar>?
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let started = IosScreenShareProtocol.coreDeviceHostIp.withCString { hostCStr in
                pairingPath.withCString { pairCStr in
                    deskfleet_coredevice_session_start(
                        hostCStr,
                        pairCStr,
                        1,
                        coreDeviceFrameCallback,
                        coreDeviceClipboardCallback,
                        coreDeviceClosedCallback,
                        ctx,
                        &outErr
                    )
                }
            }
            defer {
                if let outErr { ishplus_pairing_free_string(outErr) }
            }

            guard let started else {
                let errMsg = outErr.map { String(cString: $0) } ?? "Failed to start CoreDevice session"
                NSLog("[IosCoreDevice] session start failed: %@", errMsg)
                throw NSError(
                    domain: "IosCoreDeviceSessionManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: errMsg]
                )
            }

            decodeQueue.sync {
                self.decoder.invalidate()
            }
            lock.lock()
            handle = started
            lastDecodedBuffer = nil
            lastDecodedPtsNs = 0
            lock.unlock()
            NSLog("[IosCoreDevice] session started")
        }
    }

    func attach(videoSub: IosCoreDeviceVideoSubscriber?, inputSub: InputSubscriber?) {
        lock.lock()
        stopWorkItem?.cancel()
        stopWorkItem = nil
        if let videoSub { videoSubscribers[videoSub.id] = videoSub }
        if let inputSub { inputSubscribers[inputSub.id] = inputSub }
        let cachedPb = lastDecodedBuffer
        let cachedPts = lastDecodedPtsNs
        let vCount = videoSubscribers.count
        let iCount = inputSubscribers.count
        lock.unlock()
        NSLog("[IosCoreDevice] attached subscriber (video=%d input=%d)", vCount, iCount)

        if let videoSub, let cachedPb {
            videoSub.requestKeyframe(retainedPixelBuffer: cachedPb, ptsNs: cachedPts)
        }
    }

    func release(videoSubId: UUID?, inputSubId: UUID?) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let videoSubId {
                self.videoSubscribers.removeValue(forKey: videoSubId)?.markClosed()
            }
            if let inputSubId {
                self.inputSubscribers.removeValue(forKey: inputSubId)
            }
            let empty = self.videoSubscribers.isEmpty && self.inputSubscribers.isEmpty
            if empty, self.handle != nil {
                self.stopWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.stopIfUnused()
                }
                self.stopWorkItem = work
                self.lifecycleQueue.asyncAfter(deadline: .now() + .seconds(2), execute: work)
            }
            self.lock.unlock()
        }
    }

    func stopNow() {
        lifecycleQueue.sync {
            lock.lock()
            stopWorkItem?.cancel()
            stopWorkItem = nil
            let currentHandle = handle
            handle = nil
            let vSubs = Array(videoSubscribers.values)
            let iSubs = Array(inputSubscribers.values)
            videoSubscribers.removeAll()
            inputSubscribers.removeAll()
            lastDecodedBuffer = nil
            lock.unlock()

            for sub in vSubs {
                sub.markClosed()
                Darwin.shutdown(sub.fd, SHUT_RDWR)
            }
            for sub in iSubs {
                Darwin.shutdown(sub.fd, SHUT_RDWR)
            }
            if let currentHandle {
                deskfleet_coredevice_session_stop(currentHandle)
            }
            decodeQueue.sync {
                self.decoder.invalidate()
            }
        }
    }

    func requestKeyframe(for videoSubId: UUID) {
        lock.lock()
        let sub = videoSubscribers[videoSubId]
        let cachedPb = lastDecodedBuffer
        let cachedPts = lastDecodedPtsNs
        let currentHandle = handle
        lock.unlock()

        sub?.requestKeyframe(retainedPixelBuffer: cachedPb, ptsNs: cachedPts)
        if cachedPb == nil, let currentHandle {
            deskfleet_coredevice_session_request_keyframe(currentHandle)
        }
    }

    func updateBitrate(for videoSubId: UUID, bitrateBps: Int) {
        lock.lock()
        let sub = videoSubscribers[videoSubId]
        lock.unlock()
        sub?.updateBitrate(bitrateBps)
    }

    func sendInput(_ jsonLine: String) {
        lock.lock()
        let currentHandle = handle
        lock.unlock()
        guard let currentHandle else { return }
        _ = jsonLine.withCString { deskfleet_coredevice_session_send_input(currentHandle, $0) }
    }

    private func stopIfUnused() {
        lock.lock()
        guard videoSubscribers.isEmpty && inputSubscribers.isEmpty,
              let currentHandle = handle else {
            lock.unlock()
            return
        }
        handle = nil
        stopWorkItem = nil
        lastDecodedBuffer = nil
        lock.unlock()
        deskfleet_coredevice_session_stop(currentHandle)
        decodeQueue.async { [weak self] in
            self?.decoder.invalidate()
        }
    }

    fileprivate func dispatchFrame(
        data: UnsafePointer<UInt8>?,
        len: Int,
        ptsNs: UInt64,
        isKeyframe _: Bool
    ) {
        guard let data, len > 0 else { return }
        let payload = Data(bytes: data, count: len)
        decodeQueue.async { [weak self] in
            guard let self else { return }
            guard let pixelBuffer = self.decoder.decode(annexB: payload, ptsNs: ptsNs) else {
                return
            }
            self.lock.lock()
            self.lastDecodedBuffer = pixelBuffer
            self.lastDecodedPtsNs = ptsNs
            let subs = Array(self.videoSubscribers.values)
            self.lock.unlock()
            for sub in subs {
                sub.enqueuePixelBuffer(pixelBuffer, ptsNs: ptsNs)
            }
        }
    }

    fileprivate func dispatchClipboard(_ text: String) {
        lock.lock()
        let subs = Array(inputSubscribers.values)
        lock.unlock()
        for sub in subs {
            sub.sendClipboard(text)
        }
    }

    fileprivate func handleClosed(_ error: String?) {
        lock.lock()
        let vSubs = Array(videoSubscribers.values)
        let iSubs = Array(inputSubscribers.values)
        lastDecodedBuffer = nil
        lock.unlock()
        for sub in vSubs {
            sub.markClosed()
            Darwin.shutdown(sub.fd, SHUT_RDWR)
        }
        for sub in iSubs {
            Darwin.shutdown(sub.fd, SHUT_RDWR)
        }
        onSessionClosed(error)
    }
}

private let coreDeviceFrameCallback: deskfleet_coredevice_frame_cb = { ctx, data, len, ptsNs, isKeyframe in
    guard let ctx else { return }
    let manager = Unmanaged<IosCoreDeviceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
    manager.dispatchFrame(data: data, len: Int(len), ptsNs: ptsNs, isKeyframe: isKeyframe)
}

private let coreDeviceClipboardCallback: deskfleet_coredevice_clipboard_cb = { ctx, utf8Ptr in
    guard let ctx, let utf8Ptr else { return }
    let manager = Unmanaged<IosCoreDeviceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
    manager.dispatchClipboard(String(cString: utf8Ptr))
}

private let coreDeviceClosedCallback: deskfleet_coredevice_closed_cb = { ctx, errPtr in
    guard let ctx else { return }
    let manager = Unmanaged<IosCoreDeviceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
    let message = errPtr.map { String(cString: $0) }
    manager.handleClosed(message)
}
