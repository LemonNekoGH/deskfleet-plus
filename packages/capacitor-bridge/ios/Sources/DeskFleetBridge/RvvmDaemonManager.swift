// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import CFNetwork
import Foundation
import RvvmRuntime
import UIKit

/// Manages the embedded pure-JIT librvvm (RISC-V 64-bit) Linux guest and DeskFleet daemon
/// on iOS, mirroring Android's ProotDaemonManager contract.
internal final class RvvmDaemonManager {
    private static let appGroupId = "group.moe.remon.deskfleet.plus"
    private static let defaultForkReleaseBase = "https://github.com/LemonNekoGH/deskfleet-plus/releases/download/ios-guest-riscv64"
    private static let defaultVcpuCount: Int = 2

    private let versionName: String
    private let fallbackMachineName: String
    private let onLog: (String) -> Void
    private let screenBridgeProvider: () -> RvvmDaemonCommands.ScreenBridgeConfig?
    private let lifecycle: RvvmLocalDaemonLifecycle
    private let lifecycleQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.rvvm.lifecycle", qos: .userInitiated)
    private let keepAlive = RvvmBackgroundKeepAlive()
    private let stateLock = NSLock()
    private let execLock = NSLock()

    private var vmHandle: OpaquePointer?
    private var nextRequestId: UInt64 = 1
    private var rxBuffer = Data()
    private var guestReady = false
    private var guestNetworkConfigured = false

    init(
        versionName: String,
        fallbackMachineName: String,
        onLog: @escaping (String) -> Void = { _ in },
        onStateChanged: @escaping ([String: Any]) -> Void = { _ in },
        screenBridgeProvider: @escaping () -> RvvmDaemonCommands.ScreenBridgeConfig? = { nil }
    ) {
        self.versionName = versionName
        self.fallbackMachineName = fallbackMachineName
        self.onLog = onLog
        self.screenBridgeProvider = screenBridgeProvider
        self.lifecycle = RvvmLocalDaemonLifecycle(
            hasExistingSetup: {
                Self.hasExistingSetupOnDisk()
            },
            onChanged: onStateChanged
        )
    }

    private static func hasExistingSetupOnDisk() -> Bool {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId),
           fm.fileExists(atPath: group.appendingPathComponent("pairingFile.plist").path) {
            return true
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let vmDir = docs.appendingPathComponent("VM", isDirectory: true)
            if fm.fileExists(atPath: vmDir.appendingPathComponent("pairingFile.plist").path)
                || fm.fileExists(atPath: vmDir.appendingPathComponent("deskfleet-riscv64.img").path) {
                return true
            }
        }
        return false
    }

    deinit {
        stopVM()
    }

    // MARK: - Logging helpers

    private func appendAndEmitLog(_ text: String) {
        lifecycle.appendLog(text)
        onLog(text)
    }

    private func emitStep(_ text: String) {
        appendAndEmitLog("\u{1B}[1;36m==> \(text)\u{1B}[0m\n")
    }

    private func emitInfo(_ text: String) {
        appendAndEmitLog("  \(text)\n")
    }

    private func emitSuccess(_ text: String) {
        appendAndEmitLog("\u{1B}[1;32m✓ \(text)\u{1B}[0m\n")
    }

    private func emitWarning(_ text: String) {
        appendAndEmitLog("\u{1B}[33m! \(text)\u{1B}[0m\n")
    }

    private func emitError(_ text: String) {
        appendAndEmitLog("\u{1B}[1;31m✗ \(text)\u{1B}[0m\n")
    }

    // MARK: - Local daemon lifecycle (Electron LocalAgentController parity)

    func localDaemonState() -> [String: Any] {
        return lifecycle.snapshot().toDictionary()
    }

    func recentLogs() -> String {
        return lifecycle.recentLogs()
    }

    /// Mirrors Electron's startup behavior: if the persisted local daemon toggle is enabled,
    /// attempts a silent background boot on app launch and records an error state (without
    /// forcing an unsolicited modal sheet) if JIT/LocalDevVPN or VM startup fails.
    func autoStartIfEnabled() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            guard self.lifecycle.isEnabled else { return }
            let current = self.lifecycle.snapshot()
            guard current.status == .stopped else { return }
            _ = self.startLocalDaemonLocked(interactive: false, presenterProvider: { nil })
        }
    }

    func setLocalDaemonEnabled(
        _ enabled: Bool,
        presenterProvider: @escaping () -> UIViewController?
    ) -> [String: Any] {
        return lifecycleQueue.sync {
            _ = lifecycle.setEnabledPreference(enabled)
            if enabled {
                return startLocalDaemonLocked(interactive: true, presenterProvider: presenterProvider)
            }
            _ = lifecycle.transition(to: .stopping)
            stopVM()
            return lifecycle.transition(to: .stopped).toDictionary()
        }
    }

    func startLocalDaemon(
        interactive: Bool,
        presenterProvider: @escaping () -> UIViewController?
    ) -> [String: Any] {
        return lifecycleQueue.sync {
            if interactive && !lifecycle.isEnabled {
                _ = lifecycle.setEnabledPreference(true)
            }
            return startLocalDaemonLocked(interactive: interactive, presenterProvider: presenterProvider)
        }
    }

    private func startLocalDaemonLocked(
        interactive: Bool,
        presenterProvider: @escaping () -> UIViewController?
    ) -> [String: Any] {
        if isVMRunning() && isGuestDaemonReady() {
            return lifecycle.transition(to: .running).toDictionary()
        }
        lifecycle.resetLogBuffer()
        _ = lifecycle.transition(to: .starting)
        do {
            try ensureRunningAndProvisioned(
                allowInteractiveJitPrompt: interactive,
                presenterProvider: presenterProvider
            )
            return lifecycle.transition(to: .running).toDictionary()
        } catch {
            let msg = error.localizedDescription
            return lifecycle.transition(to: .error, error: msg).toDictionary()
        }
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
            let output = try execInGuest(RvvmDaemonCommands.statusCommand(), timeoutSeconds: 30)
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
        try ensureStartedOnLifecycleQueue(interactive: true, presenterProvider: presenterProvider)
        emitStep("Preparing machine identity for \(serverUrl)...")
        let cmd = RvvmDaemonCommands.prepareEnrollmentCommand(serverUrl: serverUrl, teamId: teamId)
        let output = try execInGuest(cmd, timeoutSeconds: 60)
        emitSuccess("Machine identity prepared.")
        return try RvvmDaemonCommands.extractJsonObject(from: output)
    }

    func enroll(
        serverUrl: String,
        credentialsJson: String,
        presenterProvider: @escaping () -> UIViewController?
    ) throws -> [String: Any] {
        try ensureStartedOnLifecycleQueue(interactive: true, presenterProvider: presenterProvider)
        emitStep("Saving machine credentials into local daemon...")
        let proxy = resolveSystemProxy()
        let cmd = RvvmDaemonCommands.enrollCommand(serverUrl: serverUrl, credentialsJson: credentialsJson)
        let output: String
        do {
            output = try execInGuest(cmd, timeoutSeconds: 60)
        } catch {
            emitStep("Collecting guest network diagnostics...")
            if let diag = try? execInGuest(
                RvvmDaemonCommands.networkDiagnosticCommand(serverUrl: serverUrl, proxy: proxy),
                timeoutSeconds: 25
            ) {
                let trimmedDiag = diag.trimmingCharacters(in: .newlines)
                if !trimmedDiag.isEmpty {
                    appendAndEmitLog("\(trimmedDiag)\n")
                }
                if let probeErr = RvvmDaemonCommands.extractProbeError(from: trimmedDiag) {
                    let combined = "\(error.localizedDescription) (\(probeErr))"
                    throw NSError(
                        domain: "RvvmDaemonManager",
                        code: (error as NSError).code,
                        userInfo: [NSLocalizedDescriptionKey: combined]
                    )
                }
            }
            throw error
        }
        let enrolled = try RvvmDaemonCommands.extractJsonObject(from: output)
        emitSuccess("Local daemon enrolled.")
        let screenBridge = screenBridgeProvider()
        _ = try execInGuest(
            RvvmDaemonCommands.ensureDaemonRunningCommand(proxy: proxy, screenBridge: screenBridge),
            timeoutSeconds: 20
        )
        _ = try? execInGuest("sync >/dev/null 2>&1 || true", timeoutSeconds: 10)
        _ = lifecycle.setEnabledPreference(true)
        _ = lifecycle.transition(to: .running)
        return enrolled
    }

    private func ensureStartedOnLifecycleQueue(
        interactive: Bool,
        presenterProvider: @escaping () -> UIViewController?
    ) throws {
        var thrownError: Error?
        lifecycleQueue.sync {
            if interactive && !lifecycle.isEnabled {
                _ = lifecycle.setEnabledPreference(true)
            }
            if isVMRunning() && isGuestDaemonReady() {
                _ = lifecycle.transition(to: .running)
                return
            }
            lifecycle.resetLogBuffer()
            _ = lifecycle.transition(to: .starting)
            do {
                try ensureRunningAndProvisioned(
                    allowInteractiveJitPrompt: interactive,
                    presenterProvider: presenterProvider
                )
                _ = lifecycle.transition(to: .running)
            } catch {
                _ = lifecycle.transition(to: .error, error: error.localizedDescription)
                thrownError = error
            }
        }
        if let thrownError {
            throw thrownError
        }
    }

    func refreshCapabilitiesAsync() {
        guard isVMRunning() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.isVMRunning() else { return }
            _ = try? self.execInGuest(RvvmDaemonCommands.statusCommand(), timeoutSeconds: 15)
        }
    }

    func settings(args: [String]) throws -> [String: Any] {
        guard isVMRunning() else {
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Embedded Linux daemon is not running"]
            )
        }
        let cmd = RvvmDaemonCommands.settingsCommand(args: args)
        let output = try execInGuest(cmd, timeoutSeconds: 20)
        let parsed = try RvvmDaemonCommands.extractJsonObject(from: output)
        if args.first == "set" || args.first == "reset" {
            _ = try? execInGuest("sync >/dev/null 2>&1 || true", timeoutSeconds: 10)
        }
        return parsed
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
        guestNetworkConfigured = false
        stateLock.unlock()
        if let handle {
            rvvm_host_stop(handle)
        }
        rvvm_ram_donor_release_all()
        keepAlive.stop()
    }

    private func ensureRunningAndProvisioned(
        allowInteractiveJitPrompt: Bool,
        presenterProvider: @escaping () -> UIViewController?
    ) throws {
        try ensureJitEnabled(
            allowInteractiveJitPrompt: allowInteractiveJitPrompt,
            presenterProvider: presenterProvider
        )
        try ensureVMBooted()
        try ensureGuestDaemonProvisioned()
    }

    private func isJitReadyForColdStart() -> Bool {
        // On iOS 26+ (TXM devices like iPhone 17 Pro), CS_DEBUGGED alone (e.g. from devicectl
        // --console) is NOT enough for vma_multi_mmap: an attached TXM brk #0xf00d debugger
        // (P_TRACED == true) is required before librvvm prepares its RX JIT caches.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            return rvvm_host_is_traced()
        }
        return rvvm_host_check_jit_enabled()
    }

    private func ensureJitEnabled(
        allowInteractiveJitPrompt: Bool,
        presenterProvider: @escaping () -> UIViewController?
    ) throws {
        stateLock.lock()
        let alreadyRunning = (vmHandle != nil && rvvm_host_is_running(vmHandle))
        stateLock.unlock()
        if alreadyRunning {
            return
        }
        if isJitReadyForColdStart() {
            emitSuccess("Pure JIT is already active.")
            return
        }

        let pairingURL = pairingFileURL()
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let needsScript = majorVersion >= 26

        // Try silent activation first only when both a pairing file and LocalDevVPN are ready.
        let hasPairingFile = FileManager.default.fileExists(atPath: pairingURL.path)
        var silentFailureReason: String?
        if hasPairingFile {
            if RvvmJitSetupViewController.probeLocalDevVpnSync(timeout: 0.8) {
                emitStep("LocalDevVPN detected; activating Pure JIT for embedded Linux VM...")
                let helperLock = NSLock()
                var helperFailedMessage: String?
                RvvmJitHelperLauncher.activateJit(
                    withPairingPath: pairingURL.path,
                    targetPid: getpid(),
                    needsScript: needsScript
                ) { success, errorMessage in
                    guard !success else { return }
                    helperLock.lock()
                    helperFailedMessage = errorMessage ?? "JIT helper failed"
                    helperLock.unlock()
                }

                let quickDeadline = Date().addingTimeInterval(8.0)
                while Date() < quickDeadline {
                    if isJitReadyForColdStart() {
                        emitSuccess("Pure JIT activated.")
                        return
                    }
                    helperLock.lock()
                    let failure = helperFailedMessage
                    helperLock.unlock()
                    if let failure {
                        emitWarning("Silent JIT activation failed: \(failure)")
                        silentFailureReason = "Pure JIT activation failed: \(failure)"
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.15)
                }
                if silentFailureReason == nil {
                    silentFailureReason = "Timed out activating Pure JIT automatically."
                }
            } else {
                emitInfo("LocalDevVPN (10.7.0.1:62078) not detected.")
                silentFailureReason = "LocalDevVPN (10.7.0.1) is not active; unable to activate Pure JIT."
            }
        } else {
            silentFailureReason = "Pairing file is missing; open Local Daemon setup to pair."
        }

        if !allowInteractiveJitPrompt {
            let msg = silentFailureReason ?? "Pure JIT is required to run the embedded Linux daemon."
            emitError(msg)
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }

        emitStep("Waiting for JIT activation...")
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
            let controller = RvvmJitSetupViewController(
                pairingFileURL: pairingURL,
                autoLaunchVpnOnAppear: hasPairingFile
            ) { result in
                setupResult = result
                semaphore.signal()
            }
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .formSheet
            top.present(nav, animated: true)
        }

        semaphore.wait()
        try setupResult.get()

        guard isJitReadyForColdStart() else {
            let msg = "Pure JIT is required to run the embedded Linux daemon"
            emitError(msg)
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
        emitSuccess("Pure JIT activated.")
    }

    private func ensureVMBooted() throws {
        stateLock.lock()
        if let vmHandle, rvvm_host_is_running(vmHandle) {
            stateLock.unlock()
            try waitForGuestExecAgent(timeoutSeconds: 90, consoleLogURL: nil, initialConsoleOffset: 0)
            configureGuestNetworkAndClock()
            return
        }
        stateLock.unlock()

        let firmwareURL = try resolveGuestFirmwareURL()
        let rootDiskURL = try resolveGuestRootDiskURL()
        let kernelURL = resolveOptionalGuestKernelURL()
        let seedDiskURL = resolveOptionalSeedDiskURL()
        let consoleLogURL = vmDirectoryURL().appendingPathComponent("console.log")
        let initialConsoleOffset = fileSize(consoleLogURL)

        keepAlive.start()
        emitStep("Booting embedded RISC-V 64-bit Linux VM (librvvm + RVJIT)...")
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryBytes = RvvmDaemonCommands.recommendedMemoryBytes(physicalMemoryBytes: physicalMemory)
        let jitCacheBytes = RvvmDaemonCommands.recommendedJitCacheBytes(physicalMemoryBytes: physicalMemory)
        emitInfo("Guest RAM: \(memoryBytes / (1024 * 1024)) MiB, RVJIT cache: \(jitCacheBytes / (1024 * 1024)) MiB")

        let cmdline = RvvmDaemonCommands.guestBootCmdline()
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let startedHandle: OpaquePointer? = firmwareURL.path.withCString { fwCStr in
            rootDiskURL.path.withCString { diskCStr in
                consoleLogURL.path.withCString { logCStr in
                    withOptionalCString(kernelURL?.path) { kernelCStr in
                        withOptionalCString(seedDiskURL?.path) { seedCStr in
                            withOptionalCString(kernelURL != nil ? cmdline : nil) { cmdlineCStr in
                                var cfg = rvvm_host_config_t(
                                    memory_bytes: memoryBytes,
                                    vcpu_count: Self.defaultVcpuCount,
                                    jit_cache_bytes: jitCacheBytes,
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
            let msg = "Failed to start librvvm guest: \(errText)"
            emitError(msg)
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }

        stateLock.lock()
        vmHandle = startedHandle
        guestReady = false
        guestNetworkConfigured = false
        rxBuffer.removeAll(keepingCapacity: false)
        stateLock.unlock()

        try waitForGuestExecAgent(
            timeoutSeconds: 90,
            consoleLogURL: consoleLogURL,
            initialConsoleOffset: initialConsoleOffset
        )
        configureGuestNetworkAndClock()
    }

    private func resolveHostIpv4DnsServers() -> [String] {
        var buffer = [CChar](repeating: 0, count: 1024)
        let written = rvvm_host_copy_ipv4_dns_servers(&buffer, buffer.count)
        guard written > 0 else { return [] }
        let raw = String(cString: buffer)
        return raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func resolveSystemProxy() -> RvvmDaemonCommands.ProxyConfig? {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        func proxyEndpoint(enableKey: String, hostKey: String, portKey: String) -> String? {
            guard let enabled = raw[enableKey] as? NSNumber, enabled.boolValue,
                  let hostRaw = raw[hostKey] as? String else {
                return nil
            }
            let host = hostRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            let lower = host.lowercased()
            if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "0.0.0.0" {
                return nil
            }
            if let portNum = raw[portKey] as? NSNumber, portNum.intValue > 0 {
                return "http://\(host):\(portNum.intValue)"
            }
            return "http://\(host)"
        }
        let http = proxyEndpoint(enableKey: "HTTPEnable", hostKey: "HTTPProxy", portKey: "HTTPPort")
        let https = proxyEndpoint(enableKey: "HTTPSEnable", hostKey: "HTTPSProxy", portKey: "HTTPSPort") ?? http
        let config = RvvmDaemonCommands.ProxyConfig(httpProxy: http, httpsProxy: https)
        return config.hasAny ? config : nil
    }

    private func configureGuestNetworkAndClock() {
        stateLock.lock()
        if guestNetworkConfigured {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let dnsServers = resolveHostIpv4DnsServers()
        let proxy = resolveSystemProxy()
        emitStep("Configuring Linux guest network, DNS, and clock...")
        let unixSeconds = Int64(Date().timeIntervalSince1970)
        let cmd = RvvmDaemonCommands.configureGuestNetworkAndClockCommand(
            unixSeconds: unixSeconds,
            dnsServers: dnsServers
        )
        if let summary = try? execInGuest(cmd, timeoutSeconds: 25) {
            let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                emitInfo(clean)
            }
        }
        emitInfo("DNS: \(dnsServers.isEmpty ? "fallback 1.1.1.1, 8.8.8.8" : dnsServers.joined(separator: ", "))")
        if let proxy, proxy.hasAny {
            let desc = [proxy.httpProxy.map { "http=\($0)" }, proxy.httpsProxy.map { "https=\($0)" }]
                .compactMap { $0 }
                .joined(separator: " ")
            emitInfo("Proxy: \(desc)")
        }

        stateLock.lock()
        guestNetworkConfigured = true
        stateLock.unlock()
    }

    private func guestReleaseBaseURL() -> String {
        for key in ["DeskFleetGuestImageBaseURL", "DeskFleetDaemonReleaseBaseURL"] {
            if let configured = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !configured.isEmpty {
                return configured.hasSuffix("/") ? String(configured.dropLast()) : configured
            }
        }
        return Self.defaultForkReleaseBase
    }

    private func isGuestDaemonReady() -> Bool {
        // Fast pure-shell preflight before spawning Node 24 (`deskfleet-daemon status`), which can
        // take 15-25s under RVVM cold boot and otherwise clogs the single-threaded UART 1 exec loop.
        guard let probeOut = try? execInGuest(RvvmDaemonCommands.daemonProbeCommand(logOffset: 0), timeoutSeconds: 10),
              let probe = RvvmDaemonCommands.parseDaemonProbeOutput(probeOut),
              probe.alive,
              probe.discoveryReady else {
            return false
        }
        do {
            let output = try execInGuest(RvvmDaemonCommands.statusCommand(), timeoutSeconds: 45)
            let parsed = try RvvmDaemonCommands.extractJsonObject(from: output)
            return parsed["registrations"] != nil
        } catch {
            return false
        }
    }

    private func ensureGuestDaemonProvisioned() throws {
        emitStep("Checking /opt/deskfleet/deskfleet-daemon inside guest...")
        let releaseUrl = "\(guestReleaseBaseURL())/\(RvvmDaemonCommands.daemonReleaseAsset)"
        let script = RvvmDaemonCommands.provisionDaemonCommand(releaseUrl: releaseUrl, versionName: versionName)
        _ = try execInGuest(script, timeoutSeconds: 180)

        if isGuestDaemonReady() {
            emitSuccess("Local deskfleet-daemon is already running.")
            return
        }

        let logSizeRaw = (try? execInGuest(RvvmDaemonCommands.daemonLogSizeCommand(), timeoutSeconds: 10)) ?? "0"
        let initialOffset = UInt64(logSizeRaw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        emitStep("Starting local deskfleet-daemon service...")
        let proxy = resolveSystemProxy()
        let screenBridge = screenBridgeProvider()
        _ = try execInGuest(
            RvvmDaemonCommands.ensureDaemonRunningCommand(proxy: proxy, screenBridge: screenBridge),
            timeoutSeconds: 45
        )
        try waitForGuestDaemonReady(initialLogOffset: initialOffset, timeoutSeconds: 120)
    }

    private func waitForGuestDaemonReady(initialLogOffset: UInt64, timeoutSeconds: TimeInterval) throws {
        var logOffset = initialLogOffset
        let startGraceDeadline = Date().addingTimeInterval(5)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let probeOut = try? execInGuest(RvvmDaemonCommands.daemonProbeCommand(logOffset: logOffset), timeoutSeconds: 10),
               let probe = RvvmDaemonCommands.parseDaemonProbeOutput(probeOut) {
                if !probe.logChunk.isEmpty {
                    appendAndEmitLog(probe.logChunk)
                }
                logOffset = probe.nextOffset

                if !probe.alive && Date() >= startGraceDeadline {
                    let tail = ((try? execInGuest(RvvmDaemonCommands.daemonLogTailCommand(), timeoutSeconds: 10)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = tail.isEmpty
                        ? "Local deskfleet-daemon exited before becoming ready."
                        : "Local deskfleet-daemon exited unexpectedly:\n\(tail)"
                    emitError(msg)
                    throw NSError(
                        domain: "RvvmDaemonManager",
                        code: 25,
                        userInfo: [NSLocalizedDescriptionKey: msg]
                    )
                }

                if probe.alive && probe.discoveryReady && isGuestDaemonReady() {
                    emitSuccess("Local deskfleet-daemon is ready.")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let tail = ((try? execInGuest(RvvmDaemonCommands.daemonLogTailCommand(), timeoutSeconds: 10)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = tail.isEmpty
            ? "Timed out waiting for local deskfleet-daemon to become ready."
            : "Timed out waiting for local deskfleet-daemon to become ready:\n\(tail)"
        emitError(msg)
        throw NSError(
            domain: "RvvmDaemonManager",
            code: 26,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }

    // MARK: - Framed UART 1 exec protocol

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func drainFileLog(url: URL?, offset: UInt64, flushPartial: Bool = false) -> UInt64 {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else {
            return offset
        }
        defer { try? handle.close() }
        guard let endOffset = try? handle.seekToEnd(), endOffset > offset else {
            return offset
        }
        do {
            try handle.seek(toOffset: offset)
            let chunkSize = Int(min(endOffset - offset, 64 * 1024))
            guard chunkSize > 0 else { return offset }
            let data = handle.readData(ofLength: chunkSize)
            guard !data.isEmpty else { return offset }

            let emitData: Data
            if !flushPartial, let lastNewline = data.lastIndex(of: 0x0A) {
                emitData = data.subdata(in: 0..<(lastNewline + 1))
            } else if flushPartial {
                emitData = data
            } else {
                return offset
            }

            let text = String(decoding: emitData, as: UTF8.self)
            if !text.isEmpty {
                onLog(text)
            }
            return offset + UInt64(emitData.count)
        } catch {
            return offset
        }
    }

    private func waitForGuestExecAgent(
        timeoutSeconds: TimeInterval,
        consoleLogURL: URL?,
        initialConsoleOffset: UInt64
    ) throws {
        stateLock.lock()
        if guestReady {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var consoleOffset = initialConsoleOffset
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        while Date() < deadline {
            consoleOffset = drainFileLog(url: consoleLogURL, offset: consoleOffset)
            do {
                let pong = try execInGuest("printf 'ready\\n'\n", timeoutSeconds: 3)
                consoleOffset = drainFileLog(url: consoleLogURL, offset: consoleOffset)
                if pong.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" {
                    _ = drainFileLog(url: consoleLogURL, offset: consoleOffset, flushPartial: true)
                    stateLock.lock()
                    guestReady = true
                    stateLock.unlock()
                    emitSuccess("Linux guest is ready.")
                    return
                }
            } catch {
                lastError = error
                consoleOffset = drainFileLog(url: consoleLogURL, offset: consoleOffset)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        _ = drainFileLog(url: consoleLogURL, offset: consoleOffset, flushPartial: true)
        let err = lastError ?? NSError(
            domain: "RvvmDaemonManager",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Linux guest exec agent on /dev/ttyS1"]
        )
        emitError(err.localizedDescription)
        throw err
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

    internal func pairingFileURL() -> URL {
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
                emitSuccess("Using cached Linux guest image (\(name)).")
                return path
            }
        }
        return try downloadPrebakedGuestDiskImage()
    }

    private func downloadPrebakedGuestDiskImage() throws -> URL {
        let targetURL = vmDirectoryURL().appendingPathComponent("deskfleet-riscv64.img")
        let partURL = vmDirectoryURL().appendingPathComponent("deskfleet-riscv64.img.part")
        let stagingGz = vmDirectoryURL().appendingPathComponent("deskfleet-riscv64.img.gz.download")
        let downloadURLString = "\(guestReleaseBaseURL())/\(RvvmDaemonCommands.guestDiskArchiveAsset)"
        guard let remoteURL = URL(string: downloadURLString) else {
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Invalid guest image download URL: \(downloadURLString)"]
            )
        }

        keepAlive.start()
        var handedOffToVM = false
        defer {
            if !handedOffToVM {
                keepAlive.stop()
            }
        }

        emitStep("Downloading Linux guest image (\(RvvmDaemonCommands.guestDiskArchiveAsset))...")
        let delegate = RvvmAssetDownloadDelegate(stagingURL: stagingGz) { [onLog] downloaded, total in
            let line: String
            if total > 0 {
                let pct = min(max((downloaded * 100) / total, 0), 100)
                line = "Downloaded \(RvvmDaemonCommands.formatByteCount(downloaded)) / \(RvvmDaemonCommands.formatByteCount(total)) (\(pct)%)"
            } else {
                line = "Downloaded \(RvvmDaemonCommands.formatByteCount(downloaded))"
            }
            onLog("\r\u{1B}[2K  \(line)")
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let gzURL: URL
        var emittedDownloadProgress = false
        do {
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: remoteURL)
            task.resume()
            let outcome = try delegate.waitForResult()
            gzURL = outcome.url
            emittedDownloadProgress = outcome.emittedProgress
            if emittedDownloadProgress {
                onLog("\n")
            }
        } catch {
            if delegate.didEmitProgress() && !emittedDownloadProgress {
                onLog("\n")
            }
            emitError(error.localizedDescription)
            throw error
        }

        defer { try? FileManager.default.removeItem(at: gzURL) }
        try? FileManager.default.removeItem(at: partURL)

        emitStep("Decompressing guest disk image (\(RvvmDaemonCommands.guestDiskArchiveAsset))...")
        final class GunzipProgressBox {
            let onLog: (String) -> Void
            var sawProgress = false
            init(onLog: @escaping (String) -> Void) {
                self.onLog = onLog
            }
        }
        let progressBox = GunzipProgressBox(onLog: onLog)
        let gunzipCallback: rvvm_host_progress_cb_t = { doneBytes, totalBytes, ctx in
            guard let ctx else { return }
            let box = Unmanaged<GunzipProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            box.sawProgress = true
            let line: String
            if totalBytes > 0 {
                let pct = min((doneBytes * 100) / totalBytes, 100)
                line = "Decompressed \(RvvmDaemonCommands.formatByteCount(Int64(doneBytes))) / \(RvvmDaemonCommands.formatByteCount(Int64(totalBytes))) (\(pct)%)"
            } else {
                line = "Decompressed \(RvvmDaemonCommands.formatByteCount(Int64(doneBytes)))"
            }
            box.onLog("\r\u{1B}[2K  \(line)")
        }

        var errBuf = [CChar](repeating: 0, count: 512)
        let ok = withExtendedLifetime(progressBox) {
            let rawCtx = Unmanaged.passUnretained(progressBox).toOpaque()
            return gzURL.path.withCString { srcCStr in
                partURL.path.withCString { dstCStr in
                    rvvm_host_gunzip_file_with_progress(srcCStr, dstCStr, gunzipCallback, rawCtx, &errBuf, errBuf.count)
                }
            }
        }
        if progressBox.sawProgress {
            onLog("\n")
        }
        guard ok else {
            try? FileManager.default.removeItem(at: partURL)
            let errText = String(cString: errBuf)
            let msg = "Failed to decompress guest disk image: \(errText)"
            emitError(msg)
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 24,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }

        try? FileManager.default.removeItem(at: targetURL)
        try FileManager.default.moveItem(at: partURL, to: targetURL)
        handedOffToVM = true
        emitSuccess("Guest disk image ready.")
        return targetURL
    }

    private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        if let string {
            return string.withCString { body($0) }
        }
        return body(nil)
    }
}

private final class RvvmAssetDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let stagingURL: URL
    private let onProgress: (Int64, Int64) -> Void
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var lastEmitTime: TimeInterval = 0
    private var lastEmitBytes: Int64 = -1
    private var sawProgress = false
    private var result: Result<URL, Error>?

    init(stagingURL: URL, onProgress: @escaping (Int64, Int64) -> Void) {
        self.stagingURL = stagingURL
        self.onProgress = onProgress
    }

    func didEmitProgress() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawProgress
    }

    func waitForResult() throws -> (url: URL, emittedProgress: Bool) {
        semaphore.wait()
        lock.lock()
        let current = result
        let emitted = sawProgress
        lock.unlock()
        switch current {
        case .success(let url):
            return (url, emitted)
        case .failure(let error):
            throw error
        case .none:
            throw NSError(
                domain: "RvvmDaemonManager",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: "Unable to stage downloaded guest disk image"]
            )
        }
    }

    private func complete(with outcome: Result<URL, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        lock.unlock()
        semaphore.signal()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmit: Bool
        lock.lock()
        if lastEmitBytes < 0
            || totalBytesWritten - lastEmitBytes >= 256 * 1024
            || now - lastEmitTime >= 0.25
            || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite) {
            lastEmitBytes = totalBytesWritten
            lastEmitTime = now
            sawProgress = true
            shouldEmit = true
        } else {
            shouldEmit = false
        }
        lock.unlock()
        if shouldEmit {
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            complete(with: .failure(NSError(
                domain: "RvvmDaemonManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to download \(RvvmDaemonCommands.guestDiskArchiveAsset): HTTP \(http.statusCode)"]
            )))
            return
        }
        try? FileManager.default.removeItem(at: stagingURL)
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            complete(with: .success(stagingURL))
        } catch {
            complete(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(with: .failure(error))
        } else if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            complete(with: .failure(NSError(
                domain: "RvvmDaemonManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to download \(RvvmDaemonCommands.guestDiskArchiveAsset): HTTP \(http.statusCode)"]
            )))
        } else {
            complete(with: .failure(NSError(
                domain: "RvvmDaemonManager",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Empty download location for \(RvvmDaemonCommands.guestDiskArchiveAsset)"]
            )))
        }
    }
}
