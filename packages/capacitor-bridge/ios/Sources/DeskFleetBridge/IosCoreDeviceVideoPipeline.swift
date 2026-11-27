// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Decodes Apple CoreDevice `displayservice` Annex-B HEVC frames into hardware NV12
/// `CVPixelBuffer`s using iOS's hardware `VTDecompressionSession`.
///
/// AVConference's CoreDevice stream runs an infinite-GOP 60fps HEVC stream that does not
/// reliably honor PLI/FIR keyframe requests after the opening IDR. Decoding once to a
/// GPU-backed `CVPixelBuffer` lets each DeskFleet viewer subscriber encode on-demand to
/// H.265 or H.264 with guaranteed keyframes, requested resolution scaling, fps pacing,
/// and dynamic bitrate control.
internal final class IosCoreDeviceHevcDecoder {
    private final class DecodeBox {
        var pixelBuffer: CVPixelBuffer?
        var status: OSStatus = noErr
    }

    private var vps = Data()
    private var sps = Data()
    private var pps = Data()
    private var formatDesc: CMFormatDescription?
    private var session: VTDecompressionSession?
    private let decodeBox = DecodeBox()
    private var decodedCount: UInt64 = 0
    private var errorCount: UInt64 = 0

    deinit {
        invalidate()
    }

    func invalidate() {
        if let active = session {
            session = nil
            VTDecompressionSessionInvalidate(active)
        }
        formatDesc = nil
        vps.removeAll(keepingCapacity: false)
        sps.removeAll(keepingCapacity: false)
        pps.removeAll(keepingCapacity: false)
    }

    /// Synchronously decodes one Annex-B HEVC access unit into a `CVPixelBuffer`.
    func decode(annexB: Data, ptsNs: UInt64) -> CVPixelBuffer? {
        let nals = IosScreenShareProtocol.splitAnnexBNalUnits(annexB)
        guard !nals.isEmpty else { return nil }

        var paramsChanged = false
        var hvcc = Data(capacity: annexB.count)
        var hasVcl = false

        for nal in nals {
            guard nal.count >= 2 else { continue }
            let nalType = (nal[0] >> 1) & 0x3F
            switch nalType {
            case 32: // VPS
                if vps != nal {
                    vps = nal
                    paramsChanged = true
                }
            case 33: // SPS
                if sps != nal {
                    sps = nal
                    paramsChanged = true
                }
            case 34: // PPS
                if pps != nal {
                    pps = nal
                    paramsChanged = true
                }
            case 35: // AUD
                continue
            default:
                if nalType <= 31 {
                    hasVcl = true
                }
                var beLen = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &beLen) { hvcc.append(contentsOf: $0) }
                hvcc.append(nal)
            }
        }

        if paramsChanged || session == nil {
            guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else {
                return nil
            }
            if !recreateSession() {
                return nil
            }
        }

        guard hasVcl, !hvcc.isEmpty, let activeSession = session, let activeFormat = formatDesc else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: hvcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: hvcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createBlockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }
        let replaceStatus = hvcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: hvcc.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(ptsNs / 1_000), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = hvcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: activeFormat,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            return nil
        }

        decodeBox.pixelBuffer = nil
        decodeBox.status = noErr
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            activeSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if decodeStatus != noErr || decodeBox.status != noErr {
            errorCount += 1
            if errorCount <= 5 || errorCount % 60 == 0 {
                NSLog(
                    "[IosCoreDevice] HEVC decode error #%llu status=%d cbStatus=%d",
                    errorCount,
                    decodeStatus,
                    decodeBox.status
                )
            }
            return nil
        }
        if let pb = decodeBox.pixelBuffer {
            decodedCount += 1
            return pb
        }
        return nil
    }

    private func recreateSession() -> Bool {
        if let active = session {
            session = nil
            VTDecompressionSessionInvalidate(active)
        }
        formatDesc = nil

        var newFormat: CMFormatDescription?
        let fmtStatus: OSStatus = vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    guard let vp = vpsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let sp = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let pp = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                    var ptrs: [UnsafePointer<UInt8>] = [vp, sp, pp]
                    var sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &ptrs,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &newFormat
                    )
                }
            }
        }
        guard fmtStatus == noErr, let newFormat else {
            NSLog("[IosCoreDevice] CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: %d", fmtStatus)
            return false
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.coreDeviceHevcDecodeCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(decodeBox).toOpaque()
        )
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else {
            NSLog("[IosCoreDevice] VTDecompressionSessionCreate failed: %d", createStatus)
            return false
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        formatDesc = newFormat
        session = newSession
        return true
    }

    private static let coreDeviceHevcDecodeCallback: VTDecompressionOutputCallback = {
        refCon, _, status, infoFlags, imageBuffer, _, _ in
        guard let refCon else { return }
        let box = Unmanaged<DecodeBox>.fromOpaque(refCon).takeUnretainedValue()
        box.status = status
        if status == noErr,
           !infoFlags.contains(.frameDropped),
           let imageBuffer {
            box.pixelBuffer = imageBuffer
        }
    }
}

/// Per-viewer hardware VideoToolbox encoder (`h264` or `h265`) streaming framed Annex-B
/// packets to one connected RVVM guest TCP subscriber.
internal final class IosCoreDeviceVideoSubscriber: @unchecked Sendable {
    let id: UUID
    let fd: Int32
    let request: IosScreenShareProtocol.VideoStreamRequest

    private let effectiveFps: Int
    private let onDisconnect: () -> Void
    private let encodeQueue: DispatchQueue
    private let sendQueue: DispatchQueue
    private let lock = NSLock()

    private var closed = false
    private var pendingEncode = 0
    private var pendingSend = 0
    private var forceNextKeyframe = true
    private var lastEncodeUptimeNs: UInt64 = 0
    private var lastPtsNs: UInt64 = 0
    private var currentBitrateBps: Int
    private var encodedCount: UInt64 = 0

    // Accessed exclusively on `encodeQueue`.
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0

    init(
        id: UUID = UUID(),
        fd: Int32,
        request: IosScreenShareProtocol.VideoStreamRequest,
        onDisconnect: @escaping () -> Void
    ) {
        self.id = id
        self.fd = fd
        self.request = request
        // Keep streaming within 30fps so RVVM RISC-V 64 WebRTC SRTP pacing never lags.
        self.effectiveFps = max(1, min(30, request.fps))
        self.currentBitrateBps = request.bitrateBps
        self.onDisconnect = onDisconnect
        self.encodeQueue = DispatchQueue(
            label: "moe.remon.deskfleet.plus.coredevice.enc.\(id.uuidString.prefix(8))",
            qos: .userInteractive
        )
        self.sendQueue = DispatchQueue(
            label: "moe.remon.deskfleet.plus.coredevice.send.\(id.uuidString.prefix(8))",
            qos: .userInteractive
        )
    }

    deinit {
        markClosed()
    }

    func markClosed() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed {
            encodeQueue.async { [weak self] in
                self?.teardownEncoderLocked()
            }
        }
    }

    func requestKeyframe(retainedPixelBuffer: CVPixelBuffer?, ptsNs: UInt64) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        forceNextKeyframe = true
        let canPushNow = retainedPixelBuffer != nil && pendingEncode == 0
        if canPushNow {
            pendingEncode += 1
            lastEncodeUptimeNs = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()

        if canPushNow, let pb = retainedPixelBuffer {
            encodeQueue.async { [weak self] in
                guard let self else { return }
                defer {
                    self.lock.lock()
                    self.pendingEncode = max(0, self.pendingEncode - 1)
                    self.lock.unlock()
                }
                self.encodePixelBuffer(pb, ptsNs: ptsNs)
            }
        }
    }

    func updateBitrate(_ bitrateBps: Int) {
        let clamped = max(100_000, min(25_000_000, bitrateBps))
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        currentBitrateBps = clamped
        lock.unlock()
        encodeQueue.async { [weak self] in
            self?.applyBitrateLocked(clamped)
        }
    }

    func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer, ptsNs: UInt64) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let needKeyframe = forceNextKeyframe
        if pendingEncode >= 2 {
            lock.unlock()
            return
        }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let minIntervalNs = UInt64(1_000_000_000 / max(1, effectiveFps))
        if !needKeyframe && lastEncodeUptimeNs > 0 && nowNs > lastEncodeUptimeNs
            && (nowNs - lastEncodeUptimeNs) < (minIntervalNs * 85 / 100) {
            lock.unlock()
            return
        }
        lastEncodeUptimeNs = nowNs
        pendingEncode += 1
        lock.unlock()

        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingEncode = max(0, self.pendingEncode - 1)
                self.lock.unlock()
            }
            self.encodePixelBuffer(pixelBuffer, ptsNs: ptsNs)
        }
    }

    func sendKeepalive() {
        sendWirePacket(IosScreenShareProtocol.encodeKeepaliveFrame(), isKeyframe: false)
    }

    private func encodePixelBuffer(_ pixelBuffer: CVPixelBuffer, ptsNs: UInt64) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let needKeyframe = forceNextKeyframe
        forceNextKeyframe = false
        let bitrate = currentBitrateBps
        lock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dims = IosScreenShareProtocol.computeScaledEvenDimensions(
            srcWidth: srcW,
            srcHeight: srcH,
            maxWidth: request.maxWidth,
            maxHeight: request.maxHeight
        )
        guard ensureEncoderLocked(width: dims.width, height: dims.height, bitrateBps: bitrate),
              let activeSession = session else {
            return
        }

        var frameProps: CFDictionary?
        if needKeyframe {
            let dict: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any]
            frameProps = dict as CFDictionary
        }
        let pts = CMTime(value: Int64(ptsNs / 1_000), timescale: 1_000_000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, effectiveFps)))
        VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func ensureEncoderLocked(width: Int, height: Int, bitrateBps: Int) -> Bool {
        if session != nil && sessionWidth == width && sessionHeight == height {
            return true
        }
        teardownEncoderLocked()

        let codecType: CMVideoCodecType = request.codec == "h265"
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: coreDeviceVtEncodeCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            NSLog("[IosCoreDevice] VTCompressionSessionCreate(%@ %dx%d) failed: %d", request.codec, width, height, status)
            return false
        }

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: request.codec == "h265"
                ? kVTProfileLevel_HEVC_Main_AutoLevel
                : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        )
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: effectiveFps))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(1, effectiveFps * 2)))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))
        session = created
        sessionWidth = width
        sessionHeight = height
        applyBitrateLocked(bitrateBps)
        VTCompressionSessionPrepareToEncodeFrames(created)
        NSLog(
            "[IosCoreDevice] encoder ready: codec=%@ %dx%d fps=%d bps=%d",
            request.codec,
            width,
            height,
            effectiveFps,
            bitrateBps
        )
        return true
    }

    private func applyBitrateLocked(_ bitrateBps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrateBps))
        let bytesPerSec = max(32_000, Int(Double(bitrateBps) / 8.0 * 1.5))
        let limits: [NSNumber] = [NSNumber(value: bytesPerSec), NSNumber(value: 1.0)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
    }

    private func teardownEncoderLocked() {
        guard let active = session else { return }
        session = nil
        sessionWidth = 0
        sessionHeight = 0
        VTCompressionSessionInvalidate(active)
    }

    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var parameterSets: [Data] = []
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
            if mediaSubType == kCMVideoCodecType_HEVC {
                var psCount = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &psCount,
                    nalUnitHeaderLengthOut: nil
                ) == noErr {
                    for idx in 0..<psCount {
                        var ptr: UnsafePointer<UInt8>?
                        var size = 0
                        if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                            formatDesc,
                            parameterSetIndex: idx,
                            parameterSetPointerOut: &ptr,
                            parameterSetSizeOut: &size,
                            parameterSetCountOut: nil,
                            nalUnitHeaderLengthOut: nil
                        ) == noErr, let ptr, size > 0 {
                            parameterSets.append(Data(bytes: ptr, count: size))
                        }
                    }
                }
            } else {
                var psCount = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &psCount,
                    nalUnitHeaderLengthOut: nil
                ) == noErr {
                    for idx in 0..<psCount {
                        var ptr: UnsafePointer<UInt8>?
                        var size = 0
                        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            formatDesc,
                            parameterSetIndex: idx,
                            parameterSetPointerOut: &ptr,
                            parameterSetSizeOut: &size,
                            parameterSetCountOut: nil,
                            nalUnitHeaderLengthOut: nil
                        ) == noErr, let ptr, size > 0 {
                            parameterSets.append(Data(bytes: ptr, count: size))
                        }
                    }
                }
            }
        }

        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0, totalLength <= IosScreenShareProtocol.maxFramePayloadBytes else { return }
        var rawData = Data(count: totalLength)
        let copyStatus = rawData.withUnsafeMutableBytes { dst -> OSStatus in
            guard let base = dst.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let annexB = IosScreenShareProtocol.convertLengthPrefixedToAnnexB(
            avccData: rawData,
            parameterSets: parameterSets,
            prependParameterSets: isKeyframe
        )
        guard !annexB.isEmpty else { return }

        let rawPtsNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let monotonic = rawPtsNs > lastPtsNs ? rawPtsNs : (lastPtsNs + 1_000)
        lastPtsNs = monotonic
        encodedCount += 1
        lock.unlock()

        let framed = IosScreenShareProtocol.encodeVideoFrame(
            payload: annexB,
            ptsNs: monotonic,
            isKeyframe: isKeyframe
        )
        sendWirePacket(framed, isKeyframe: isKeyframe)
    }

    private func sendWirePacket(_ data: Data, isKeyframe: Bool) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if !isKeyframe && pendingSend >= 4 {
            // Request an IDR on the next encode so dropping a P-frame never corrupts decoder state.
            forceNextKeyframe = true
            lock.unlock()
            return
        }
        pendingSend += 1
        lock.unlock()

        sendQueue.async { [weak self] in
            guard let self else { return }
            let ok = IosScreenShareProtocol.posixWriteAll(fd: self.fd, data: data)
            self.lock.lock()
            self.pendingSend = max(0, self.pendingSend - 1)
            let wasClosed = self.closed
            if !ok { self.closed = true }
            self.lock.unlock()
            if !ok && !wasClosed {
                Darwin.shutdown(self.fd, SHUT_RDWR)
                self.onDisconnect()
            }
        }
    }
}

private let coreDeviceVtEncodeCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon, _, status, infoFlags, sampleBuffer in
    guard status == noErr,
          !infoFlags.contains(.frameDropped),
          let outputCallbackRefCon,
          let sampleBuffer else {
        return
    }
    let subscriber = Unmanaged<IosCoreDeviceVideoSubscriber>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    subscriber.handleEncodedSampleBuffer(sampleBuffer)
}
