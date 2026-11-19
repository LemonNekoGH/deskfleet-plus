// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation
import RvvmRuntime
import UIKit

/// Manages the embedded pure-JIT librvvm (RISC-V 64-bit) Linux guest and DeskFleet daemon
/// on iOS, mirroring Android's ProotDaemonManager contract.
internal final class RvvmDaemonManager {
    private static let appGroupId = "group.ai.yetanother.deskfleet"
    private static let defaultDaemonReleaseBase = "https://github.com/yet-another-ai/deskfleet/releases/latest/download"
    private static let defaultMemoryBytes: Int = 512 * 1024 * 1024
    private static let defaultVcpuCount: Int = 2
    private static let defaultJitCacheBytes: Int = 32 * 1024 * 1024

    private let versionName: String
    private let fallbackMachineName: String
    private let keepAlive = RvvmBackgroundKeepAlive()
    private let stateLock = NSLock()
    private let execLock = NSLock()

    private var vmHandle: OpaquePointer?
    private var nextRequestId: UInt64 = 1
    private var rxBuffer = Data()
    private var guestReady = false

    init(versionName: String, fallbackMachineName: String) {
        self.versionName = versionName
        self.fallbackMachineName = fallbackMachineName
    }

    deinit {
        stopVM()
    }

    // MARK: - LocalDaemonBridgePlugin operations

    func status() -> [String: Any] {
        guard isVMRunning() else {
            return [
                "machineName": fallbackMachineName,
                "registrations": [],
            ]
        }
        do {
            let output = try execInGuest(RvvmDaemonCommands.statusCommand(), timeoutSeconds: 15)
            let parsed = try RvvmDaemonCommands.extractJsonObject(from: output)
            if parsed["registrations"] != nil {
                return parsed
            }
        } catch {
            // Passive status queries should never crash or prompt for JIT; fall back to idle payload.
        }
        return [
            "machineName": fallbackMachineName,
            "registrations": [],
        ]
    }

    func prepareEnrollment(
        serverUrl: String,
        teamId: String,
        presenterProvider: @escaping () -> UIViewController?
    ) throws -> [String: Any] {
        try ensureRunningAndProvisioned(presenterProvider: presenterProvider)
        let cmd = RvvmDaemonCommands.prepareEnrollmentCommand(serverUrl: serverUrl, teamId: teamId)
        let output = try execInGuest(cmd, timeoutSeconds: 60)
        return try RvvmDaemonCommands.extractJsonObject(from: output)
    }

    func enroll(
        serverUrl: String,
        credentialsJson: String,
        presenterProvider: @escaping () -> UIViewController?
    ) throws -> [String: Any] {
        try ensureRunningAndProvisioned(presenterProvider: presenterProvider)
        let cmd = RvvmDaemonCommands.enrollCommand(serverUrl: serverUrl, credentialsJson: credentialsJson)
        let output = try execInGuest(cmd, timeoutSeconds: 60)
        let enrolled = try RvvmDaemonCommands.extractJsonObject(from: output)
        _ = try execInGuest(RvvmDaemonCommands.ensureDaemonRunningCommand(), timeoutSeconds: 20)
        return enrolled
    }

    // MARK: - VM lifecycle

    private func isVMRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let vmHandle else { return false }
        return rvvm_host_is_running(vmHandle)
    }

    private func stopVM() {
        stateLock.lock()
        let handle = vmHandle
        vmHandle = nil
        guestReady = false
        stateLock.unlock()
        if let handle {
            rvvm_host_stop(handle)
        }
        rvvm_ram_donor_release_all()
        keepAlive.stop()
    }

    private func ensureRunningAndProvisioned(
        presenterProvider: @escaping () -> UIViewController?
    ) throws {
        try ensureJitEnabled(presenterProvider: presenterProvider)
        try ensureVMBooted()
        try ensureGuestDaemonProvisioned()
    }

    private func ensureJitEnabled(presenterProvider: @escaping () -> UIViewController?) throws {
        if rvvm_host_check_jit_enabled() {
            return
        }

        let pairingURL = pairingFileURL()
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let needsScript = majorVersion >= 26

        // Try silent activation first if a pairing file already exists.
        if FileManager.default.fileExists(atPath: pairingURL.path) {
            RvvmJitHelperLauncher.activateJit(
                withPairingPath: pairingURL.path,
                targetPid: getpid(),
                needsScript: needsScript
            ) { _, _ in }

            let quickDeadline = Date().addingTimeInterval(6.0)
            while Date() < quickDeadline {
                if rvvm_host_check_jit_enabled() {
                    return
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var setupResult: Result<Void, Error> = .failure(NSError(
            domain: "RvvmDaemonManager",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Unable to present JIT activation sheet"]
        ))

        DispatchQueue.main.async {
            guard let presenter = presenterProvider() else {
                semaphore.signal()
                return
            }
            var top = presenter
            while let next = top.presentedViewController, !next.isBeingDismissed {
                top = next
            }
            let controller = RvvmJitSetupViewController(pairingFileURL: pairingURL) { result in
                setupResult = result
                semaphore.signal()
            }
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .formSheet
            top.present(nav, animated: true)
        }

        semaphore.wait()
        try setupResult.get()

        guard rvvm_host_check_jit_enabled() else {
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Pure JIT is required to run the embedded Linux daemon"]
            )
        }
    }

    private func ensureVMBooted() throws {
        stateLock.lock()
        if let vmHandle, rvvm_host_is_running(vmHandle) {
            stateLock.unlock()
            try waitForGuestExecAgent(timeoutSeconds: 90)
            return
        }
        stateLock.unlock()

        let firmwareURL = try resolveGuestFirmwareURL()
        let rootDiskURL = try resolveGuestRootDiskURL()
        let kernelURL = resolveOptionalGuestKernelURL()
        let seedDiskURL = resolveOptionalSeedDiskURL()
        let consoleLogURL = vmDirectoryURL().appendingPathComponent("console.log")

        keepAlive.start()

        let cmdline = RvvmDaemonCommands.guestBootCmdline()
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let startedHandle: OpaquePointer? = firmwareURL.path.withCString { fwCStr in
            rootDiskURL.path.withCString { diskCStr in
                consoleLogURL.path.withCString { logCStr in
                    withOptionalCString(kernelURL?.path) { kernelCStr in
                        withOptionalCString(seedDiskURL?.path) { seedCStr in
                            withOptionalCString(kernelURL != nil ? cmdline : nil) { cmdlineCStr in
                                var cfg = rvvm_host_config_t(
                                    memory_bytes: Self.defaultMemoryBytes,
                                    vcpu_count: Self.defaultVcpuCount,
                                    jit_cache_bytes: Self.defaultJitCacheBytes,
                                    enable_jit: true,
                                    enable_network: true,
                                    firmware_path: fwCStr,
                                    kernel_path: kernelCStr,
                                    cmdline: cmdlineCStr,
                                    root_disk_path: diskCStr,
                                    seed_disk_path: seedCStr,
                                    console_log_path: logCStr
                                )
                                return rvvm_host_start(&cfg, &errorBuffer, errorBuffer.count)
                            }
                        }
                    }
                }
            }
        }

        guard let startedHandle else {
            keepAlive.stop()
            let errText = String(cString: errorBuffer)
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start librvvm guest: \(errText)"]
            )
        }

        stateLock.lock()
        vmHandle = startedHandle
        guestReady = false
        rxBuffer.removeAll(keepingCapacity: false)
        stateLock.unlock()

        try waitForGuestExecAgent(timeoutSeconds: 90)
    }

    private func ensureGuestDaemonProvisioned() throws {
        let releaseBase = (Bundle.main.object(forInfoDictionaryKey: "DeskFleetDaemonReleaseBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (releaseBase?.isEmpty == false) ? releaseBase! : Self.defaultDaemonReleaseBase
        let releaseUrl = "\(base)/\(RvvmDaemonCommands.daemonReleaseAsset)"
        let script = RvvmDaemonCommands.provisionDaemonCommand(releaseUrl: releaseUrl, versionName: versionName)
        _ = try execInGuest(script, timeoutSeconds: 180)
        _ = try execInGuest(RvvmDaemonCommands.ensureDaemonRunningCommand(), timeoutSeconds: 20)
    }

    // MARK: - Framed UART 1 exec protocol

    private func waitForGuestExecAgent(timeoutSeconds: TimeInterval) throws {
        stateLock.lock()
        if guestReady {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        while Date() < deadline {
            do {
                let pong = try execInGuest("printf 'ready'", timeoutSeconds: 3)
                if pong.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" {
                    stateLock.lock()
                    guestReady = true
                    stateLock.unlock()
                    return
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw lastError ?? NSError(
            domain: "RvvmDaemonManager",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Linux guest exec agent on /dev/ttyS1"]
        )
    }

    private func execInGuest(_ command: String, timeoutSeconds: TimeInterval) throws -> String {
        execLock.lock()
        defer { execLock.unlock() }

        stateLock.lock()
        let handle = vmHandle
        stateLock.unlock()

        guard let handle, rvvm_host_is_running(handle) else {
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Embedded librvvm guest is not running"]
            )
        }

        let reqId = nextRequestId
        nextRequestId += 1
        let frame = RvvmDaemonCommands.formatExecRequest(id: reqId, command: command)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        try writeAll(handle: handle, data: frame, deadline: deadline)

        while Date() < deadline {
            let line = try readLine(handle: handle, deadline: deadline)
            guard let header = RvvmDaemonCommands.parseExecResponseHeader(line) else {
                continue
            }
            let payloadData = try readExact(handle: handle, count: header.byteLength, deadline: deadline)
            guard header.id == reqId else {
                continue
            }
            let text = String(data: payloadData, encoding: .utf8) ?? ""
            if header.exitCode != 0 {
                throw NSError(
                    domain: "RvvmDaemonManager",
                    code: header.exitCode,
                    userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Guest command failed (exit \(header.exitCode))" : text]
                )
            }
            return text
        }

        throw NSError(
            domain: "RvvmDaemonManager",
            code: 15,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for guest command response"]
        )
    }

    private func writeAll(handle: OpaquePointer, data: Data, deadline: Date) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count {
                if Date() >= deadline {
                    throw NSError(
                        domain: "RvvmDaemonManager",
                        code: 16,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out writing command to UART 1"]
                    )
                }
                let written = rvvm_host_channel_write(handle, base.advanced(by: offset), data.count - offset)
                if written == 0 {
                    Thread.sleep(forTimeInterval: 0.01)
                } else {
                    offset += written
                }
            }
        }
    }

    private func readLine(handle: OpaquePointer, deadline: Date) throws -> String {
        while true {
            if let newlineIdx = rxBuffer.firstIndex(of: 0x0A) {
                let lineData = rxBuffer.subdata(in: 0..<newlineIdx)
                rxBuffer.removeSubrange(0...newlineIdx)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            try pumpRx(handle: handle, deadline: deadline)
        }
    }

    private func readExact(handle: OpaquePointer, count: Int, deadline: Date) throws -> Data {
        while rxBuffer.count < count {
            try pumpRx(handle: handle, deadline: deadline)
        }
        let result = rxBuffer.subdata(in: 0..<count)
        rxBuffer.removeSubrange(0..<count)
        return result
    }

    private func pumpRx(handle: OpaquePointer, deadline: Date) throws {
        let remainingMs = Int(deadline.timeIntervalSinceNow * 1000.0)
        if remainingMs <= 0 {
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "Timed out reading from UART 1"]
            )
        }
        let waitMs = UInt32(min(max(remainingMs, 10), 250))
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = rvvm_host_channel_read(handle, &chunk, chunk.count, waitMs)
        if n < 0 {
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 18,
                userInfo: [NSLocalizedDescriptionKey: "UART 1 channel closed"]
            )
        }
        if n > 0 {
            rxBuffer.append(contentsOf: chunk[0..<Int(n)])
        }
    }

    // MARK: - Paths & Guest Assets

    private func vmDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = docs.appendingPathComponent("VM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pairingFileURL() -> URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            return group.appendingPathComponent("pairingFile.plist")
        }
        return vmDirectoryURL().appendingPathComponent("pairingFile.plist")
    }

    private func resolveGuestFirmwareURL() throws -> URL {
        let hasKernel = resolveOptionalGuestKernelURL() != nil
        let preferred = hasKernel ? ["fw_jump.bin", "fw_payload.bin"] : ["fw_payload.bin", "fw_jump.bin"]
        for name in preferred {
            let userPath = vmDirectoryURL().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: userPath.path) {
                return userPath
            }
            if let bundled = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "bin", subdirectory: "Guest") {
                return bundled
            }
        }
        throw NSError(
            domain: "RvvmDaemonManager",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "Missing RISC-V OpenSBI firmware (fw_payload.bin / fw_jump.bin) in Guest bundle"]
        )
    }

    private func resolveOptionalGuestKernelURL() -> URL? {
        let userKernel = vmDirectoryURL().appendingPathComponent("Image")
        if FileManager.default.fileExists(atPath: userKernel.path) {
            return userKernel
        }
        return Bundle.main.url(forResource: "Image", withExtension: nil, subdirectory: "Guest")
    }

    private func resolveOptionalSeedDiskURL() -> URL? {
        let userSeed = vmDirectoryURL().appendingPathComponent("seed.img")
        if FileManager.default.fileExists(atPath: userSeed.path) {
            return userSeed
        }
        return nil
    }

    private func resolveGuestRootDiskURL() throws -> URL {
        let candidates = ["deskfleet-riscv64.img", "rootfs.img", "linux-riscv64.img"]
        for name in candidates {
            let path = vmDirectoryURL().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        throw NSError(
            domain: "RvvmDaemonManager",
            code: 21,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Missing riscv64 Linux disk image at Documents/VM/deskfleet-riscv64.img. Place a bootable riscv64 Ubuntu/Debian image with deskfleet-exec-agent.service in Files → DeskFleet → VM.",
            ]
        )
    }

    private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        if let string {
            return string.withCString { body($0) }
        }
        return body(nil)
    }
}
