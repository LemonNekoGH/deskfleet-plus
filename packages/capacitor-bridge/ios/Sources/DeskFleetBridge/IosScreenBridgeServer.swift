// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Darwin
import Foundation
import IshPlusRPPairing
import Security
import UIKit

/// Local TCP bridge (`127.0.0.1:<ephemeral>`) accessed from the embedded RVVM Linux guest
/// via `192.168.0.254:<port>`. Routes guest screen streaming and input control requests to:
///   1. Apple CoreDevice (`displayservice` HEVC + `universalhidservice`/`indigo` + `pasteboard`),
///      when LocalDevVPN (`10.7.0.1`) and a lockdown `pairingFile.plist` are active.
///   2. ReplayKit Broadcast Upload Extension (`BroadcastUpload.appex`, VideoToolbox H.264/H.265,
///      view-only) over the App Group Unix domain socket when CoreDevice is unavailable.
internal final class IosScreenBridgeServer: @unchecked Sendable {
    private let pairingFileURLProvider: () -> URL
    private let sharedStore: OutlineAudioSharedStore?
    private let onStateChanged: ([String: Any]) -> Void
    private let onCapabilitiesChanged: () -> Void

    private let lock = NSLock()
    private let authToken: String
    private lazy var coreDeviceSession: IosCoreDeviceSessionManager = {
        IosCoreDeviceSessionManager(
            pairingFileURLProvider: pairingFileURLProvider,
            onSessionClosed: { [weak self] error in
                guard let self else { return }
                if let error, !error.isEmpty {
                    self.lock.lock()
                    self.coreDeviceDetail = error
                    self.lock.unlock()
                }
                self.notifyIfStateChanged()
            }
        )
    }()

    private var listenFd: Int32 = -1
    private var boundPort: UInt16 = 0
    private var stopped = false

    // Physical display geometry (native pixels).
    private var screenWidth: Int
    private var screenHeight: Int

    // Live availability state.
    private var pairingFilePresent = false
    private var localDevVpnReachable = false
    private var coreDeviceAvailable = false
    private var coreDeviceControl = false
    private var coreDevicePasteboard = false
    private var coreDeviceCodecs: [String] = []
    private var coreDeviceDetail: String?
    private var replayKitActive = false
    private var replayKitWidth = 0
    private var replayKitHeight = 0
    private var replayKitFps = 30
    private var lastEmittedSignature = ""
    private var lastCapabilitySignature = ""
    private var monitorTimer: DispatchSourceTimer?

    init(
        pairingFileURLProvider: @escaping () -> URL,
        sharedStore: OutlineAudioSharedStore?,
        onStateChanged: @escaping ([String: Any]) -> Void,
        onCapabilitiesChanged: @escaping () -> Void
    ) {
        self.pairingFileURLProvider = pairingFileURLProvider
        self.sharedStore = sharedStore
        self.onStateChanged = onStateChanged
        self.onCapabilitiesChanged = onCapabilitiesChanged
        self.authToken = Self.generateToken()

        let nativeBounds: CGRect = Thread.isMainThread
            ? UIScreen.main.nativeBounds
            : DispatchQueue.main.sync { UIScreen.main.nativeBounds }
        self.screenWidth = max(2, Int(nativeBounds.width.rounded()) & ~1)
        self.screenHeight = max(2, Int(nativeBounds.height.rounded()) & ~1)
    }

    deinit {
        stop()
    }

    // MARK: - Server Lifecycle

    func ensureStarted() -> RvvmDaemonCommands.ScreenBridgeConfig? {
        lock.lock()
        if boundPort > 0 && listenFd >= 0 && !stopped {
            let cfg = RvvmDaemonCommands.ScreenBridgeConfig(
                host: IosScreenShareProtocol.guestBridgeHost,
                port: boundPort,
                token: authToken
            )
            lock.unlock()
            return cfg
        }
        stopped = false
        lock.unlock()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        IosScreenShareProtocol.configureNoSigPipe(fd)
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOk = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOk = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(fd, sa, &addrLen)
            }
        }
        guard nameOk == 0 else {
            Darwin.close(fd)
            return nil
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        lock.lock()
        listenFd = fd
        boundPort = port
        lock.unlock()

        startMonitorTimer()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(listenFd: fd)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.refreshStatus(probeCoreDevice: true)
        }

        return RvvmDaemonCommands.ScreenBridgeConfig(
            host: IosScreenShareProtocol.guestBridgeHost,
            port: port,
            token: authToken
        )
    }

    func stop() {
        lock.lock()
        stopped = true
        let lfd = listenFd
        listenFd = -1
        boundPort = 0
        monitorTimer?.cancel()
        monitorTimer = nil
        lock.unlock()

        if lfd >= 0 {
            Darwin.shutdown(lfd, SHUT_RDWR)
            Darwin.close(lfd)
        }
        coreDeviceSession.stopNow()
    }

    // MARK: - Status & Probing

    func refreshStatus(probeCoreDevice: Bool) -> [String: Any] {
        refreshReplayKitState()
        let pairingPath = pairingFileURLProvider().path
        let hasPairing = FileManager.default.fileExists(atPath: pairingPath)

        lock.lock()
        pairingFilePresent = hasPairing
        if !hasPairing {
            coreDeviceAvailable = false
            coreDeviceControl = false
            coreDevicePasteboard = false
            coreDeviceCodecs = []
            coreDeviceDetail = nil
        }
        lock.unlock()

        if probeCoreDevice {
            runCoreDeviceProbe(pairingPath: pairingPath, hasPairing: hasPairing)
        } else if hasPairing {
            let vpnUp = RvvmJitSetupViewController.probeLocalDevVpnSync(timeout: 0.6)
            lock.lock()
            let shouldAutoProbe = vpnUp && (!localDevVpnReachable || !coreDeviceAvailable)
            localDevVpnReachable = vpnUp
            if !vpnUp {
                coreDeviceAvailable = false
                coreDeviceControl = false
                coreDevicePasteboard = false
                coreDeviceCodecs = []
                coreDeviceDetail = "LocalDevVPN (10.7.0.1) is not active."
            }
            lock.unlock()
            if shouldAutoProbe {
                runCoreDeviceProbe(pairingPath: pairingPath, hasPairing: true)
            }
        }

        notifyIfStateChanged()
        return buildStateSnapshot()
    }

    private func runCoreDeviceProbe(pairingPath: String, hasPairing: Bool) {
        guard hasPairing else {
            lock.lock()
            localDevVpnReachable = RvvmJitSetupViewController.probeLocalDevVpnSync(timeout: 0.6)
            coreDeviceAvailable = false
            coreDeviceControl = false
            coreDevicePasteboard = false
            coreDeviceCodecs = []
            coreDeviceDetail = "Import or create a pairing file in Local Daemon setup to enable CoreDevice remote control."
            lock.unlock()
            return
        }

        let vpnUp = RvvmJitSetupViewController.probeLocalDevVpnSync(timeout: 0.9)
        guard vpnUp else {
            lock.lock()
            localDevVpnReachable = false
            coreDeviceAvailable = false
            coreDeviceControl = false
            coreDevicePasteboard = false
            coreDeviceCodecs = []
            coreDeviceDetail = "LocalDevVPN (10.7.0.1) is not active."
            lock.unlock()
            return
        }

        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = IosScreenShareProtocol.coreDeviceHostIp.withCString { hostCStr in
            pairingPath.withCString { pairCStr in
                deskfleet_coredevice_probe(hostCStr, pairCStr, &outJson, &outErr)
            }
        }
        defer {
            if let outJson { ishplus_pairing_free_string(outJson) }
            if let outErr { ishplus_pairing_free_string(outErr) }
        }

        if rc == 0,
           let outJson,
           let rawJson = Optional(String(cString: outJson)),
           let parsed = IosScreenShareProtocol.parseCoreDeviceProbeJson(rawJson) {
            NSLog("[IosScreenBridge] CoreDevice probe OK: %@", rawJson)
            lock.lock()
            localDevVpnReachable = true
            coreDeviceAvailable = parsed.available
            coreDeviceControl = parsed.control
            coreDevicePasteboard = parsed.pasteboard
            coreDeviceCodecs = parsed.codecs
            coreDeviceDetail = parsed.available
                ? nil
                : "CoreDevice connected, but com.apple.coredevice.displayservice was not advertised."
            lock.unlock()
        } else {
            let errMsg = outErr.map { String(cString: $0) } ?? "Failed to probe CoreDevice services."
            NSLog("[IosScreenBridge] CoreDevice probe failed: %@", errMsg)
            lock.lock()
            localDevVpnReachable = true
            coreDeviceAvailable = false
            coreDeviceControl = false
            coreDevicePasteboard = false
            coreDeviceCodecs = []
            coreDeviceDetail = errMsg
            lock.unlock()
        }
    }

    private func startMonitorTimer() {
        lock.lock()
        guard monitorTimer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(1_500), repeating: .milliseconds(1_500), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshReplayKitState()
            self.notifyIfStateChanged()
        }
        monitorTimer = timer
        lock.unlock()
        timer.resume()
    }

    func refreshReplayKitState() {
        let geom = sharedStore?.readVideoGeometry() ?? (alive: false, width: 0, height: 0, fps: 0)
        lock.lock()
        replayKitActive = geom.alive
        if geom.alive {
            if geom.width > 0 && geom.height > 0 {
                replayKitWidth = geom.width
                replayKitHeight = geom.height
            }
            if geom.fps > 0 {
                replayKitFps = geom.fps
            }
        } else {
            replayKitWidth = 0
            replayKitHeight = 0
        }
        lock.unlock()
    }

    private func buildStateSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let mode: String
        let available: Bool
        let control: Bool
        let codecs: [String]
        let width: Int
        let height: Int
        if coreDeviceAvailable {
            mode = "coredevice"
            available = true
            control = coreDeviceControl
            // Hardware VideoToolbox transcoding supports both HEVC (native viewer) and H.264 (Electron/Web).
            codecs = ["h265", "h264"]
            width = screenWidth
            height = screenHeight
        } else if replayKitActive {
            mode = "replaykit"
            available = true
            control = false
            codecs = ["h264", "h265"]
            width = replayKitWidth > 0 ? replayKitWidth : screenWidth
            height = replayKitHeight > 0 ? replayKitHeight : screenHeight
        } else {
            mode = "unavailable"
            available = false
            control = false
            codecs = []
            width = screenWidth
            height = screenHeight
        }

        var result: [String: Any] = [
            "mode": mode,
            "available": available,
            "control": control,
            "pasteboard": coreDeviceAvailable && coreDevicePasteboard,
            "pairingFilePresent": pairingFilePresent,
            "localDevVpnReachable": localDevVpnReachable,
            "coreDeviceAvailable": coreDeviceAvailable,
            "replayKitActive": replayKitActive,
            "width": width,
            "height": height,
            "codecs": codecs,
        ]
        if let detail = coreDeviceDetail, !detail.isEmpty {
            result["detail"] = detail
        }
        return result
    }

    private func notifyIfStateChanged() {
        let snapshot = buildStateSnapshot()
        let sig = "\(snapshot["mode"] ?? "")|\(snapshot["available"] ?? false)|\(snapshot["control"] ?? false)|\(snapshot["replayKitActive"] ?? false)|\(snapshot["coreDeviceAvailable"] ?? false)|\(snapshot["localDevVpnReachable"] ?? false)|\(snapshot["pairingFilePresent"] ?? false)|\(snapshot["detail"] ?? "")"
        let capSig = "\(snapshot["available"] ?? false)|\(snapshot["control"] ?? false)|\(snapshot["mode"] ?? "")"

        lock.lock()
        let changed = sig != lastEmittedSignature
        let capChanged = capSig != lastCapabilitySignature
        if changed { lastEmittedSignature = sig }
        if capChanged { lastCapabilitySignature = capSig }
        lock.unlock()

        if changed {
            onStateChanged(snapshot)
        }
        if capChanged {
            onCapabilitiesChanged()
        }
    }

    // MARK: - Guest TCP Protocol

    private func acceptLoop(listenFd: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFd, sa, &len)
                }
            }
            if cfd < 0 {
                if errno == EINTR { continue }
                break
            }
            IosScreenShareProtocol.configureNoSigPipe(cfd)
            var one: Int32 = 1
            _ = Darwin.setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleGuestConnection(fd: cfd)
            }
        }
    }

    private func handleGuestConnection(fd: Int32) {
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        guard let authLine = IosScreenShareProtocol.posixReadLine(fd: fd, maxBytes: 512) else {
            return
        }
        if authLine != "AUTH \(authToken)" {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR unauthorized\n".utf8))
            return
        }
        guard IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("OK\n".utf8)) else {
            return
        }
        guard let cmdLine = IosScreenShareProtocol.posixReadLine(fd: fd, maxBytes: 1024) else {
            return
        }

        if cmdLine == "INFO" {
            handleInfoCommand(fd: fd)
        } else if cmdLine.hasPrefix("VIDEO ") {
            handleVideoCommand(fd: fd, line: cmdLine)
        } else if cmdLine == "INPUT" {
            handleInputCommand(fd: fd)
        } else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR unknown command\n".utf8))
        }
    }

    private func handleInfoCommand(fd: Int32) {
        refreshReplayKitState()
        let snap = buildStateSnapshot()
        let available = (snap["available"] as? Bool) ?? false
        let control = (snap["control"] as? Bool) ?? false
        let width = (snap["width"] as? Int) ?? screenWidth
        let height = (snap["height"] as? Int) ?? screenHeight
        let codecs = (snap["codecs"] as? [String]) ?? []
        let fps: Double = (snap["mode"] as? String) == "replaykit" ? Double(max(15, replayKitFps)) : 60.0
        let json = IosScreenShareProtocol.encodeGuestInfoJson(
            available: available,
            control: control,
            width: width,
            height: height,
            fps: fps,
            codecs: codecs
        )
        _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("\(json)\n".utf8))
    }

    private func handleVideoCommand(fd: Int32, line: String) {
        guard let request = IosScreenShareProtocol.parseVideoRequest(line) else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR invalid VIDEO arguments\n".utf8))
            return
        }
        refreshReplayKitState()
        lock.lock()
        let useCoreDevice = coreDeviceAvailable
        let useReplayKit = replayKitActive
        let width = screenWidth
        let height = screenHeight
        lock.unlock()

        if useCoreDevice {
            handleCoreDeviceVideo(fd: fd, request: request, width: width, height: height)
        } else if useReplayKit {
            handleReplayKitVideo(fd: fd, request: request)
        } else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR iOS screen sharing is not active\n".utf8))
        }
    }

    private func handleCoreDeviceVideo(
        fd: Int32,
        request: IosScreenShareProtocol.VideoStreamRequest,
        width: Int,
        height: Int
    ) {
        NSLog(
            "[IosScreenBridge] CoreDevice VIDEO request: codec=%@ fps=%d bps=%d max=%dx%d",
            request.codec,
            request.fps,
            request.bitrateBps,
            request.maxWidth,
            request.maxHeight
        )
        do {
            try coreDeviceSession.ensureSessionRunning()
        } catch {
            lock.lock()
            coreDeviceDetail = error.localizedDescription
            lock.unlock()
            _ = IosScreenShareProtocol.posixWriteAll(
                fd: fd,
                data: Data("ERR \(error.localizedDescription)\n".utf8)
            )
            return
        }

        let dims = IosScreenShareProtocol.computeScaledEvenDimensions(
            srcWidth: width,
            srcHeight: height,
            maxWidth: request.maxWidth,
            maxHeight: request.maxHeight
        )
        // Write the handshake line BEFORE attaching the subscriber so frames never race ahead of OK.
        guard IosScreenShareProtocol.posixWriteAll(
            fd: fd,
            data: Data("OK \(request.codec) \(dims.width) \(dims.height)\n".utf8)
        ) else {
            coreDeviceSession.release(videoSubId: nil, inputSubId: nil)
            return
        }

        let subId = UUID()
        let sub = IosCoreDeviceVideoSubscriber(id: subId, fd: fd, request: request) { [weak self] in
            self?.coreDeviceSession.release(videoSubId: subId, inputSubId: nil)
        }
        coreDeviceSession.attach(videoSub: sub, inputSub: nil)
        defer {
            coreDeviceSession.release(videoSubId: sub.id, inputSubId: nil)
        }
        coreDeviceSession.requestKeyframe(for: sub.id)

        let keepalive = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        keepalive.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        keepalive.setEventHandler {
            sub.sendKeepalive()
        }
        keepalive.resume()
        defer { keepalive.cancel() }

        while let kindData = IosScreenShareProtocol.posixReadExact(fd: fd, count: 1),
              let kind = kindData.first {
            if kind == IosScreenShareProtocol.controlKindKeyframe {
                coreDeviceSession.requestKeyframe(for: sub.id)
            } else if kind == IosScreenShareProtocol.controlKindBitrate {
                guard let bpsData = IosScreenShareProtocol.posixReadExact(fd: fd, count: 4) else {
                    break
                }
                let bps = bpsData.withUnsafeBytes {
                    Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
                }
                coreDeviceSession.updateBitrate(for: sub.id, bitrateBps: bps)
            }
        }
    }

    private func handleReplayKitVideo(fd: Int32, request: IosScreenShareProtocol.VideoStreamRequest) {
        guard let sockPath = IosScreenShareProtocol.replayKitSocketPath() else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR App Group container unavailable\n".utf8))
            return
        }
        let extFd = IosScreenShareProtocol.connectUnixSocket(path: sockPath)
        guard extFd >= 0 else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR ReplayKit broadcast is not listening\n".utf8))
            return
        }
        defer {
            Darwin.shutdown(extFd, SHUT_RDWR)
            Darwin.close(extFd)
        }

        let startCmd = IosScreenShareProtocol.encodeReplayKitStartCommand(request)
        guard IosScreenShareProtocol.posixWriteAll(fd: extFd, data: startCmd),
              let okLine = IosScreenShareProtocol.posixReadLine(fd: extFd, maxBytes: 256) else {
            _ = IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("ERR ReplayKit handshake failed\n".utf8))
            return
        }
        guard IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("\(okLine)\n".utf8)),
              okLine.hasPrefix("OK ") else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            while let kindData = IosScreenShareProtocol.posixReadExact(fd: fd, count: 1),
                  let kind = kindData.first {
                if kind == IosScreenShareProtocol.controlKindKeyframe {
                    if !IosScreenShareProtocol.posixWriteAll(fd: extFd, data: kindData) { break }
                } else if kind == IosScreenShareProtocol.controlKindBitrate {
                    guard let bps = IosScreenShareProtocol.posixReadExact(fd: fd, count: 4) else { break }
                    var pkt = Data(capacity: 5)
                    pkt.append(kind)
                    pkt.append(bps)
                    if !IosScreenShareProtocol.posixWriteAll(fd: extFd, data: pkt) { break }
                }
            }
            Darwin.shutdown(extFd, SHUT_RDWR)
        }

        while let header = IosScreenShareProtocol.posixReadExact(fd: extFd, count: 14),
              let parsed = IosScreenShareProtocol.decodeFrameHeader(header) {
            if parsed.length > IosScreenShareProtocol.maxFramePayloadBytes { break }
            let payload: Data
            if parsed.length > 0 {
                guard let body = IosScreenShareProtocol.posixReadExact(fd: extFd, count: parsed.length) else {
                    break
                }
                payload = body
            } else {
                payload = Data()
            }
            var packet = Data(capacity: 14 + payload.count)
            packet.append(header)
            packet.append(payload)
            if !IosScreenShareProtocol.posixWriteAll(fd: fd, data: packet) {
                break
            }
        }
    }

    private func handleInputCommand(fd: Int32) {
        lock.lock()
        let controlReady = coreDeviceAvailable && coreDeviceControl
        lock.unlock()
        guard controlReady else {
            _ = IosScreenShareProtocol.posixWriteAll(
                fd: fd,
                data: Data("ERR CoreDevice remote control is not available\n".utf8)
            )
            return
        }

        do {
            try coreDeviceSession.ensureSessionRunning()
        } catch {
            lock.lock()
            coreDeviceDetail = error.localizedDescription
            lock.unlock()
            _ = IosScreenShareProtocol.posixWriteAll(
                fd: fd,
                data: Data("ERR \(error.localizedDescription)\n".utf8)
            )
            return
        }

        // Write OK before attaching so clipboard events cannot interleave with the handshake line.
        guard IosScreenShareProtocol.posixWriteAll(fd: fd, data: Data("OK\n".utf8)) else {
            coreDeviceSession.release(videoSubId: nil, inputSubId: nil)
            return
        }

        let sub = IosCoreDeviceSessionManager.InputSubscriber(fd: fd)
        coreDeviceSession.attach(videoSub: nil, inputSub: sub)
        defer {
            coreDeviceSession.release(videoSubId: nil, inputSubId: sub.id)
        }

        while let line = IosScreenShareProtocol.posixReadLine(fd: fd, maxBytes: 64 * 1024) {
            if line.isEmpty { continue }
            coreDeviceSession.sendInput(line)
        }
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
