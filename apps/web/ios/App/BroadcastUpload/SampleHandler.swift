import Accelerate
import CoreAudioTypes
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ReplayKit
import VideoToolbox

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private static let frameIntervalMs: UInt64 = 22
    private static let geometryReportIntervalMs: UInt64 = 1_000

    private let lock = NSLock()
    private let analyzer = OutlineAudioSpectrumAnalyzer()
    private var store: OutlineAudioSharedStore?
    private var videoStreamer: ReplayKitVideoStreamer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var spectrum = [UInt8](repeating: 0, count: OutlineAudioSharedStore.stereoSpectrumBytes)
    private var lastFrameEmitMs: UInt64 = 0
    private var lastGeometryEmitMs: UInt64 = 0
    private var lastReportedWidth = 0
    private var lastReportedHeight = 0
    private var wasSilent = true
    private var finished = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lock.lock()
        defer { lock.unlock() }
        finished = false
        wasSilent = true
        lastGeometryEmitMs = 0
        lastReportedWidth = 0
        lastReportedHeight = 0

        let sharedStore = store ?? OutlineAudioSharedStore()
        store = sharedStore
        sharedStore?.markBroadcastStarted()

        videoStreamer?.stop()
        if let socketPath = IosScreenShareProtocol.replayKitSocketPath() {
            let streamer = ReplayKitVideoStreamer(socketPath: socketPath)
            streamer.start()
            videoStreamer = streamer
        }

        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.finished, let sharedStore = self.store else { return }
            if sharedStore.isStopRequested { self.stopFromAppLocked() }
            else { sharedStore.updateHeartbeat() }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    override func broadcastFinished() {
        lock.lock()
        let streamer = videoStreamer
        videoStreamer = nil
        finished = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        store?.markBroadcastStopped()
        lock.unlock()
        streamer?.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        lock.lock()
        guard !finished, let sharedStore = store else {
            lock.unlock()
            return
        }
        if sharedStore.isStopRequested {
            stopFromAppLocked()
            lock.unlock()
            return
        }

        switch sampleBufferType {
        case .video:
            let streamer = videoStreamer
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let nowMs = OutlineAudioSharedStore.nowMs()
                if width > 0 && height > 0 &&
                    (width != lastReportedWidth || height != lastReportedHeight ||
                     nowMs >= lastGeometryEmitMs + Self.geometryReportIntervalMs) {
                    lastReportedWidth = width
                    lastReportedHeight = height
                    lastGeometryEmitMs = nowMs
                    sharedStore.writeVideoGeometry(width: width, height: height, fps: 30, timestampMs: nowMs)
                }
            }
            lock.unlock()
            streamer?.enqueueVideoSample(sampleBuffer)

        case .audioApp:
            defer { lock.unlock() }
            guard analyzer.appendSampleBuffer(sampleBuffer) else { return }
            let nowMs = OutlineAudioSharedStore.nowMs()
            if nowMs >= lastFrameEmitMs + Self.frameIntervalMs {
                lastFrameEmitMs = nowMs
                let hasSignal = analyzer.computeSpectrum(into: &spectrum)
                if hasSignal || !wasSilent {
                    wasSilent = !hasSignal
                    sharedStore.writeSpectrum(spectrum, sampleRate: analyzer.sampleRate, timestampMs: nowMs)
                }
            }

        default:
            lock.unlock()
        }
    }

    private func stopFromAppLocked() {
        guard !finished else { return }
        finished = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        let streamer = videoStreamer
        videoStreamer = nil
        store?.markBroadcastStopped()
        DispatchQueue.global(qos: .utility).async {
            streamer?.stop()
        }
        finishBroadcastWithError(NSError(
            domain: "moe.remon.deskfleet.plus.BroadcastUpload",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Broadcast was stopped in DeskFleet."]
        ))
    }

    deinit {
        heartbeatTimer?.cancel()
        videoStreamer?.stop()
    }
}

/// Hardware VideoToolbox H.264/H.265 encoder streaming Annex-B frames over the App Group
/// Unix domain socket. Allocates `VTCompressionSession` only while the host app is actively
/// reading video so memory stays well within iOS's 50 MiB Broadcast Extension budget.
private final class ReplayKitVideoStreamer: @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.replaykit.encode", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.replaykit.send", qos: .userInteractive)
    private let firstFrameSignal = DispatchSemaphore(value: 0)

    private var stopped = false
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var activeRequest: IosScreenShareProtocol.VideoStreamRequest?
    private var session: VTCompressionSession?
    private var sessionCodec: String = ""
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var firstFrameSignaled = false
    private var forceNextKeyframe = true
    private var pendingEncodeCount = 0
    private var pendingSendCount = 0
    private var lastEncodeNs: UInt64 = 0
    private var firstPtsNs: UInt64?
    private var lastPtsNs: UInt64 = 0

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        let fd = IosScreenShareProtocol.bindUnixListener(path: socketPath, backlog: 2)
        guard fd >= 0 else { return }
        lock.lock()
        listenFd = fd
        stopped = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(listenFd: fd)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let lfd = listenFd
        listenFd = -1
        let cfd = clientFd
        clientFd = -1
        activeRequest = nil
        if !firstFrameSignaled {
            firstFrameSignaled = true
            firstFrameSignal.signal()
        }
        lock.unlock()

        if cfd >= 0 {
            Darwin.shutdown(cfd, SHUT_RDWR)
            Darwin.close(cfd)
        }
        if lfd >= 0 {
            Darwin.shutdown(lfd, SHUT_RDWR)
            Darwin.close(lfd)
        }
        _ = socketPath.withCString { Darwin.unlink($0) }

        encodeQueue.sync {
            self.teardownEncoderLocked()
        }
    }

    func enqueueVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        lock.lock()
        let isStopped = stopped
        sourceWidth = width
        sourceHeight = height
        if !firstFrameSignaled {
            firstFrameSignaled = true
            firstFrameSignal.signal()
        }
        guard !isStopped, let request = activeRequest, clientFd >= 0 else {
            lock.unlock()
            return
        }
        if pendingEncodeCount >= 2 {
            lock.unlock()
            return
        }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let minIntervalNs = UInt64(1_000_000_000 / max(1, request.fps))
        if lastEncodeNs > 0 && nowNs > lastEncodeNs && (nowNs - lastEncodeNs) < (minIntervalNs * 85 / 100) {
            lock.unlock()
            return
        }
        lastEncodeNs = nowNs
        pendingEncodeCount += 1
        lock.unlock()

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingEncodeCount = max(0, self.pendingEncodeCount - 1)
                self.lock.unlock()
            }
            self.encodePixelBuffer(pixelBuffer, pts: pts)
        }
    }

    private func acceptLoop(listenFd: Int32) {
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFd, sa, &len)
                }
            }
            if cfd < 0 {
                if errno == EINTR { continue }
                break
            }
            IosScreenShareProtocol.configureNoSigPipe(cfd)
            handleClient(fd: cfd)
        }
    }

    private func handleClient(fd: Int32) {
        defer {
            clearClient(fd: fd)
        }
        guard let line = IosScreenShareProtocol.posixReadLine(fd: fd, maxBytes: 256),
              let request = IosScreenShareProtocol.parseReplayKitStartCommand(line) else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR invalid START command\n".utf8))
            return
        }

        // Wait briefly for the first ReplayKit video sample if geometry isn't known yet.
        lock.lock()
        var srcW = sourceWidth
        var srcH = sourceHeight
        lock.unlock()
        if srcW <= 0 || srcH <= 0 {
            _ = firstFrameSignal.wait(timeout: .now() + .seconds(2))
            lock.lock()
            srcW = sourceWidth
            srcH = sourceHeight
            lock.unlock()
        }
        guard srcW > 0, srcH > 0 else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR waiting for ReplayKit video frames\n".utf8))
            return
        }

        let dims = IosScreenShareProtocol.computeScaledEvenDimensions(
            srcWidth: srcW,
            srcHeight: srcH,
            maxWidth: request.maxWidth,
            maxHeight: request.maxHeight
        )
        let okLine = "OK \(request.codec) \(dims.width) \(dims.height)\n"
        guard IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data(okLine.utf8)) else {
            return
        }

        lock.lock()
        let oldFd = clientFd
        clientFd = fd
        activeRequest = request
        forceNextKeyframe = true
        firstPtsNs = nil
        lastPtsNs = 0
        pendingSendCount = 0
        lock.unlock()

        if oldFd >= 0 && oldFd != fd {
            Darwin.shutdown(oldFd, SHUT_RDWR)
            Darwin.close(oldFd)
        }

        // Read control packets from host app until disconnect:
        // [u8 1] = force keyframe, [u8 2][u32_be bps] = update bitrate.
        while true {
            guard let kindData = IosScreenShareProtocol.posixReadExact(fd: fd, count: 1),
                  let kind = kindData.first else {
                break
            }
            if kind == IosScreenShareProtocol.controlKindKeyframe {
                lock.lock()
                forceNextKeyframe = true
                lock.unlock()
            } else if kind == IosScreenShareProtocol.controlKindBitrate {
                guard let bpsData = IosScreenShareProtocol.posixReadExact(fd: fd, count: 4) else {
                    break
                }
                let bps = bpsData.withUnsafeBytes {
                    Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
                }
                let clamped = max(250_000, min(25_000_000, bps))
                encodeQueue.async { [weak self] in
                    self?.applyBitrateLocked(clamped)
                }
            }
        }
    }

    private func clearClient(fd: Int32) {
        var shouldTeardown = false
        lock.lock()
        if clientFd == fd {
            clientFd = -1
            activeRequest = nil
            shouldTeardown = true
        }
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        if shouldTeardown {
            encodeQueue.async { [weak self] in
                self?.teardownEncoderLocked()
            }
        }
    }

    private func encodePixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard !stopped, clientFd >= 0, let request = activeRequest else {
            lock.unlock()
            return
        }
        let needKeyframe = forceNextKeyframe
        forceNextKeyframe = false
        lock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dims = IosScreenShareProtocol.computeScaledEvenDimensions(
            srcWidth: srcW,
            srcHeight: srcH,
            maxWidth: request.maxWidth,
            maxHeight: request.maxHeight
        )
        guard ensureEncoderLocked(
            codec: request.codec,
            width: dims.width,
            height: dims.height,
            fps: request.fps,
            bitrateBps: request.bitrateBps
        ), let activeSession = session else {
            return
        }

        var frameProps: CFDictionary?
        if needKeyframe {
            let dict: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any]
            frameProps = dict as CFDictionary
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, request.fps)))
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

    private func ensureEncoderLocked(
        codec: String,
        width: Int,
        height: Int,
        fps: Int,
        bitrateBps: Int
    ) -> Bool {
        if session != nil && sessionCodec == codec && sessionWidth == width && sessionHeight == height {
            return true
        }
        teardownEncoderLocked()

        let codecType: CMVideoCodecType = codec == "h265" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: replayKitVtOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            return false
        }

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: codec == "h265"
                ? kVTProfileLevel_HEVC_Main_AutoLevel
                : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        )
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))
        session = created
        sessionCodec = codec
        sessionWidth = width
        sessionHeight = height
        applyBitrateLocked(bitrateBps)
        VTCompressionSessionPrepareToEncodeFrames(created)
        return true
    }

    private func applyBitrateLocked(_ bitrateBps: Int) {
        guard let session else { return }
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrateBps)
        )
        let bytesPerSec = max(64_000, Int(Double(bitrateBps) / 8.0 * 1.5))
        let limits: [NSNumber] = [NSNumber(value: bytesPerSec), NSNumber(value: 1.0)]
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: limits as CFArray
        )
    }

    private func teardownEncoderLocked() {
        guard let active = session else { return }
        session = nil
        sessionCodec = ""
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

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSec = pts.isValid && !pts.isIndefinite ? CMTimeGetSeconds(pts) : 0
        let rawPtsNs = ptsSec.isFinite && ptsSec > 0 ? UInt64(ptsSec * 1_000_000_000.0) : DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let fd = clientFd
        guard !stopped, fd >= 0 else {
            lock.unlock()
            return
        }
        if !isKeyframe && pendingSendCount >= 4 {
            lock.unlock()
            return
        }
        let origin = firstPtsNs ?? rawPtsNs
        firstPtsNs = origin
        let relative = rawPtsNs >= origin ? (rawPtsNs - origin) : 0
        let monotonic = relative > lastPtsNs ? relative : (lastPtsNs + 1_000)
        lastPtsNs = monotonic
        pendingSendCount += 1
        lock.unlock()

        let wireFrame = IosScreenShareProtocol.encodeVideoFrame(
            payload: annexB,
            ptsNs: monotonic,
            isKeyframe: isKeyframe
        )
        sendQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingSendCount = max(0, self.pendingSendCount - 1)
                self.lock.unlock()
            }
            if !IosScreenShareProtocol.posixWriteAll(fd: fd, data: wireFrame) {
                self.clearClient(fd: fd)
            }
        }
    }
}

private let replayKitVtOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon, _, status, infoFlags, sampleBuffer in
    guard status == noErr,
          !infoFlags.contains(.frameDropped),
          let outputCallbackRefCon,
          let sampleBuffer else {
        return
    }
    let streamer = Unmanaged<ReplayKitVideoStreamer>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    streamer.handleEncodedSampleBuffer(sampleBuffer)
}

/// Accelerate/vDSP 4096-point Blackman FFT quantizing [left(224), right(224)] dB bins in [-80, -10] dB.
private final class OutlineAudioSpectrumAnalyzer {
    private static let fftSize = 4096
    private static let log2Fft: vDSP_Length = 12
    private static let ringMask = fftSize - 1
    private static let smoothing: Float = 0.2
    private static let minLinear: Float = 1e-4 // -80 dB

    private let fftSetup = vDSP_create_fftsetup(log2Fft, FFTRadix(kFFTRadix2))
    private let window: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_blkman_window(&w, vDSP_Length(fftSize), 0)
        return w
    }()
    private var ringLeft = [Float](repeating: 0, count: fftSize)
    private var ringRight = [Float](repeating: 0, count: fftSize)
    private var ringCursor = 0
    private var splitReal = [Float](repeating: 0, count: fftSize)
    private var splitImag = [Float](repeating: 0, count: fftSize)
    private var smoothedLeft = [Float](repeating: 0, count: OutlineAudioSharedStore.spectrumBins)
    private var smoothedRight = [Float](repeating: 0, count: OutlineAudioSharedStore.spectrumBins)
    private(set) var sampleRate = 48_000

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return false }
        let totalFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard totalFrames > 0 else { return false }
        if asbd.mSampleRate > 0 { sampleRate = Int(asbd.mSampleRate.rounded()) }

        let listBytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride * 2
        let rawList = UnsafeMutableRawPointer.allocate(byteCount: listBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let listPtr = rawList.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPtr, bufferListSize: listBytes,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        ) == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        guard let firstData = buffers.first?.mData else { return false }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBig = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 || buffers.count >= 2
        let bits = Int(asbd.mBitsPerChannel)
        let sampleBytes = max(1, bits / 8)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let stride = planar ? sampleBytes : sampleBytes * channels
        let frames = min(totalFrames, Int(buffers[0].mDataByteSize) / stride)
        guard frames > 0 else { return false }

        let rightBase = planar
            ? (buffers.count >= 2 ? (buffers[1].mData ?? firstData) : firstData)
            : (channels >= 2 ? firstData.advanced(by: sampleBytes) : firstData)
        var cursor = ringCursor
        for i in 0..<frames {
            let offset = i * stride
            ringLeft[cursor] = Self.decodeSample(firstData, offset: offset, bits: bits, isFloat: isFloat, isBig: isBig)
            ringRight[cursor] = Self.decodeSample(rightBase, offset: offset, bits: bits, isFloat: isFloat, isBig: isBig)
            cursor = (cursor + 1) & Self.ringMask
        }
        ringCursor = cursor
        return true
    }

    func computeSpectrum(into outBytes: inout [UInt8]) -> Bool {
        let bins = OutlineAudioSharedStore.spectrumBins
        guard let setup = fftSetup, outBytes.count >= bins * 2 else { return false }
        for n in 0..<Self.fftSize {
            let idx = (ringCursor + n) & Self.ringMask
            splitReal[n] = ringLeft[idx]
            splitImag[n] = ringRight[idx]
        }
        splitReal.withUnsafeMutableBufferPointer { re in
            splitImag.withUnsafeMutableBufferPointer { im in
                guard let rp = re.baseAddress, let ip = im.baseAddress else { return }
                vDSP_vmul(rp, 1, window, 1, rp, 1, vDSP_Length(Self.fftSize))
                vDSP_vmul(ip, 1, window, 1, ip, 1, vDSP_Length(Self.fftSize))
                var complex = DSPSplitComplex(realp: rp, imagp: ip)
                vDSP_fft_zip(setup, &complex, 1, Self.log2Fft, FFTDirection(kFFTDirection_Forward))
            }
        }

        let invTwoN: Float = 0.5 / Float(Self.fftSize)
        var nonZero = false
        for k in 1..<bins {
            let m = Self.fftSize - k
            let lMag = hypotf((splitReal[k] + splitReal[m]) * invTwoN, (splitImag[k] - splitImag[m]) * invTwoN)
            let rMag = hypotf((splitImag[k] + splitImag[m]) * invTwoN, (splitReal[m] - splitReal[k]) * invTwoN)
            let sL = Self.smoothing * smoothedLeft[k] + (1 - Self.smoothing) * lMag
            let sR = Self.smoothing * smoothedRight[k] + (1 - Self.smoothing) * rMag
            smoothedLeft[k] = sL
            smoothedRight[k] = sR
            let bL = Self.toDbByte(sL)
            let bR = Self.toDbByte(sR)
            outBytes[k] = bL
            outBytes[bins + k] = bR
            if bL != 0 || bR != 0 { nonZero = true }
        }
        return nonZero
    }

    private static func toDbByte(_ magnitude: Float) -> UInt8 {
        guard magnitude > minLinear else { return 0 }
        let scaled = Int(((20.0 * log10f(magnitude) + 80.0) * (255.0 / 70.0)))
        return UInt8(clamping: max(0, min(255, scaled)))
    }

    private static func decodeSample(_ base: UnsafeRawPointer, offset: Int, bits: Int, isFloat: Bool, isBig: Bool) -> Float {
        if isFloat && bits == 32 {
            let raw = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let val = Float(bitPattern: isBig ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw))
            return val.isFinite ? max(-1, min(1, val)) : 0
        }
        if bits == 16 {
            let raw = base.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            return Float(isBig ? Int16(bigEndian: raw) : Int16(littleEndian: raw)) * (1.0 / 32768.0)
        }
        return 0
    }
}
