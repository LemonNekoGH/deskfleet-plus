// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation
import Network
import RvvmRuntime
import UIKit
import UniformTypeIdentifiers

/// Clean-room native modal sheet guiding the user through Pure-JIT activation via
/// DeskFleetJITHelper (StikJIT) before booting the embedded librvvm Linux runtime.
/// Never offers an interpreter fallback.
internal final class RvvmJitSetupViewController: UIViewController, UIDocumentPickerDelegate {
    private let pairingFileURL: URL
    private let onComplete: (Result<Void, Error>) -> Void

    private var completed = false
    private let onDevicePairing = RvvmOnDevicePairing()
    private var vpnReachable = false
    private var isBusy = false
    private var isPairing = false
    private var autoLaunchVpnRequested: Bool
    private var didInitialProbe = false
    private var hasAttemptedAutoVpnLaunch = false
    private var hasAttemptedAutoActivation = false
    private var awaitingVpnReturn = false
    private var probeGeneration = 0
    private let jitStateLock = NSLock()
    private var activeJitToken: UUID?
    private var foregroundObserver: NSObjectProtocol?

    private let statusLabel = UILabel()
    private let pairingStateLabel = UILabel()
    private let vpnStateLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let openVpnButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)
    private let pairButton = UIButton(type: .system)
    private let openDeveloperModeButton = UIButton(type: .system)
    private let activateButton = UIButton(type: .system)

    init(
        pairingFileURL: URL,
        autoLaunchVpnOnAppear: Bool = false,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        self.pairingFileURL = pairingFileURL
        self.autoLaunchVpnRequested = autoLaunchVpnOnAppear
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    static func probeLocalDevVpnOnce(
        timeout: TimeInterval = 1.5,
        completion: @escaping (Bool) -> Void
    ) {
        guard let port = NWEndpoint.Port(rawValue: RvvmJitRouting.localDevVpnPort) else {
            completion(false)
            return
        }
        let queue = DispatchQueue(label: "moe.remon.deskfleet.plus.vpn-probe")
        let connection = NWConnection(
            host: NWEndpoint.Host(RvvmJitRouting.localDevVpnHost),
            port: port,
            using: .tcp
        )
        let lock = NSLock()
        var finished = false
        let finishProbe: (Bool) -> Void = { reachable in
            lock.lock()
            let alreadyFinished = finished
            finished = true
            lock.unlock()
            guard !alreadyFinished else { return }
            connection.cancel()
            completion(reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finishProbe(true)
            case .failed, .cancelled:
                finishProbe(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finishProbe(false)
        }
    }

    static func probeLocalDevVpnSync(timeout: TimeInterval = 0.8) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        probeLocalDevVpnOnce(timeout: timeout) { reachable in
            result = reachable
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout + 0.3)
        return result
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Enable JIT for Local Daemon"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        let titleLabel = UILabel()
        titleLabel.text = "Pure-JIT Linux Runtime (librvvm)"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0

        let descriptionLabel = UILabel()
        descriptionLabel.text = "DeskFleet runs an embedded RISC-V 64-bit Linux daemon using librvvm with RVJIT. Import or pair your RemotePairing file and enable LocalDevVPN (or CalicoMeow) on 10.7.0.1 to activate JIT."
        descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = 0

        pairingStateLabel.font = .preferredFont(forTextStyle: .footnote)
        pairingStateLabel.numberOfLines = 0

        vpnStateLabel.font = .preferredFont(forTextStyle: .footnote)
        vpnStateLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        configureButton(openVpnButton, title: "Enable LocalDevVPN", style: .tinted)
        openVpnButton.addTarget(self, action: #selector(openLocalDevVpnTapped), for: .touchUpInside)

        configureButton(importButton, title: "Import Pairing File (.plist)", style: .tinted)
        importButton.addTarget(self, action: #selector(importPairingTapped), for: .touchUpInside)

        configureButton(pairButton, title: "Pair On-Device (iOS 27+)", style: .tinted)
        pairButton.addTarget(self, action: #selector(onDevicePairTapped), for: .touchUpInside)
        pairButton.isHidden = !RvvmOnDevicePairing.isSupportedOnCurrentOS

        let devModeTitle = RvvmOnDevicePairing.isSupportedOnCurrentOS
            ? "Open Developer Mode (Wireless Pairing)"
            : "Open Developer Mode Settings"
        configureButton(openDeveloperModeButton, title: devModeTitle, style: .tinted)
        openDeveloperModeButton.addTarget(self, action: #selector(openDeveloperModeSettingsTapped), for: .touchUpInside)

        configureButton(activateButton, title: "Activate Pure JIT", style: .filled)
        activateButton.addTarget(self, action: #selector(activateJitTapped), for: .touchUpInside)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            descriptionLabel,
            pairingStateLabel,
            vpnStateLabel,
            openVpnButton,
            importButton,
            pairButton,
            openDeveloperModeButton,
            activateButton,
            activityIndicator,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
        ])

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidBecomeActive()
        }

        refreshState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didInitialProbe else { return }
        didInitialProbe = true
        if isJitReadyForColdStart {
            finish(.success(()))
            return
        }
        probeLocalDevVpn(
            retriesRemaining: 0,
            retryInterval: 0.35,
            allowAutoLaunchVpn: autoLaunchVpnRequested,
            isReturningFromVpn: false
        )
    }

    private func handleDidBecomeActive() {
        guard !completed else { return }
        if isJitReadyForColdStart {
            finish(.success(()))
            return
        }
        refreshState()
        if awaitingVpnReturn {
            awaitingVpnReturn = false
            statusLabel.text = "Returned from VPN app. Waiting for LocalDevVPN (10.7.0.1:62078)..."
            probeLocalDevVpn(
                retriesRemaining: 6,
                retryInterval: 0.4,
                allowAutoLaunchVpn: false,
                isReturningFromVpn: true
            )
        } else {
            probeLocalDevVpn(
                retriesRemaining: 2,
                retryInterval: 0.35,
                allowAutoLaunchVpn: autoLaunchVpnRequested,
                isReturningFromVpn: false
            )
        }
    }

    private func configureButton(_ button: UIButton, title: String, style: ButtonStyle) {
        var config: UIButton.Configuration = style == .filled ? .filled() : .tinted()
        config.title = title
        config.cornerStyle = .medium
        button.configuration = config
    }

    private func setPairButtonTitle(_ title: String) {
        var config = pairButton.configuration ?? .tinted()
        config.title = title
        config.cornerStyle = .medium
        pairButton.configuration = config
    }

    private enum ButtonStyle {
        case filled
        case tinted
    }

    private var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    private func canOpenLocalDevVpn() -> Bool {
        let probeURL = RvvmJitRouting.localDevVpnEnableURL(callbackScheme: RvvmJitRouting.bundleCallbackScheme())
        return UIApplication.shared.canOpenURL(probeURL)
    }

    private func refreshState() {
        let hasPairing = hasPairingFile
        pairingStateLabel.text = hasPairing
            ? "Pairing file: Ready (\(pairingFileURL.lastPathComponent))"
            : "Pairing file: Not imported yet"
        pairingStateLabel.textColor = hasPairing ? .systemGreen : .systemOrange

        vpnStateLabel.text = vpnReachable
            ? "LocalDevVPN (10.7.0.1:62078): Reachable"
            : "LocalDevVPN (10.7.0.1:62078): Not detected (required on device)"
        vpnStateLabel.textColor = vpnReachable ? .systemGreen : .secondaryLabel

        openVpnButton.isEnabled = !isBusy
        openDeveloperModeButton.isEnabled = true
        activateButton.isEnabled = !isBusy && hasPairing
    }

    private func probeLocalDevVpn(
        retriesRemaining: Int,
        retryInterval: TimeInterval,
        allowAutoLaunchVpn: Bool,
        isReturningFromVpn: Bool
    ) {
        probeGeneration += 1
        let generation = probeGeneration
        runProbeAttempt(
            generation: generation,
            retriesRemaining: retriesRemaining,
            retryInterval: retryInterval,
            allowAutoLaunchVpn: allowAutoLaunchVpn,
            isReturningFromVpn: isReturningFromVpn
        )
    }

    private func runProbeAttempt(
        generation: Int,
        retriesRemaining: Int,
        retryInterval: TimeInterval,
        allowAutoLaunchVpn: Bool,
        isReturningFromVpn: Bool
    ) {
        Self.probeLocalDevVpnOnce(timeout: 1.2) { [weak self] reachable in
            DispatchQueue.main.async {
                guard let self, !self.completed, self.probeGeneration == generation else { return }
                if reachable {
                    self.vpnReachable = true
                    self.awaitingVpnReturn = false
                    self.refreshState()
                    self.triggerAutoActivationIfReady()
                    return
                }
                if retriesRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                        guard let self, !self.completed, self.probeGeneration == generation else { return }
                        self.runProbeAttempt(
                            generation: generation,
                            retriesRemaining: retriesRemaining - 1,
                            retryInterval: retryInterval,
                            allowAutoLaunchVpn: allowAutoLaunchVpn,
                            isReturningFromVpn: isReturningFromVpn
                        )
                    }
                    return
                }

                self.vpnReachable = false
                self.refreshState()
                if isReturningFromVpn {
                    self.statusLabel.text = "LocalDevVPN (10.7.0.1:62078) is still unreachable. Verify LocalDevVPN or CalicoMeow is enabled, then try again."
                    return
                }
                if RvvmJitRouting.shouldAutoLaunchLocalDevVpn(
                    autoTriggerRequested: allowAutoLaunchVpn,
                    hasPairingFile: self.hasPairingFile,
                    vpnReachable: false,
                    canOpenLocalDevVpn: self.canOpenLocalDevVpn(),
                    isBusy: self.isBusy,
                    isPairing: self.isPairing,
                    hasAttemptedAutoLaunch: self.hasAttemptedAutoVpnLaunch
                ) {
                    self.hasAttemptedAutoVpnLaunch = true
                    self.openLocalDevVpn(automatic: true)
                }
            }
        }
    }

    private func triggerAutoActivationIfReady() {
        guard RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: hasPairingFile,
            vpnReachable: vpnReachable,
            isBusy: isBusy,
            isPairing: isPairing,
            hasAttemptedAutoActivation: hasAttemptedAutoActivation
        ) else {
            return
        }
        hasAttemptedAutoActivation = true
        activateJitTapped()
    }

    @objc private func openLocalDevVpnTapped() {
        openLocalDevVpn(automatic: false)
    }

    private func openLocalDevVpn(automatic: Bool) {
        let callbackScheme = RvvmJitRouting.bundleCallbackScheme()
        let url = RvvmJitRouting.localDevVpnEnableURL(callbackScheme: callbackScheme)
        awaitingVpnReturn = true
        hasAttemptedAutoActivation = false
        statusLabel.text = automatic
            ? "Opening LocalDevVPN automatically... DeskFleet Plus will activate JIT upon return."
            : "Opening LocalDevVPN... DeskFleet Plus will activate JIT upon return."

        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self, !self.completed else { return }
                if !opened {
                    self.awaitingVpnReturn = false
                    self.statusLabel.text = "No app handling localdevvpn:// was found. Install LocalDevVPN or CalicoMeow, or enable your loopback VPN manually."
                }
            }
        }
    }

    @objc private func openDeveloperModeSettingsTapped() {
        let candidates = RvvmJitRouting.developerModeSettingsURLs(
            fallbackSettingsURL: UIApplication.openSettingsURLString
        )
        openFirstAvailableURL(candidates, index: 0)
    }

    private func openFirstAvailableURL(_ urls: [URL], index: Int) {
        guard index < urls.count else {
            if !isPairing {
                statusLabel.text = "Unable to open iOS Settings. Open Settings → Privacy & Security → Developer Mode manually."
            }
            return
        }
        UIApplication.shared.open(urls[index], options: [:]) { [weak self] opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                self?.openFirstAvailableURL(urls, index: index + 1)
            }
        }
    }

    @objc private func importPairingTapped() {
        var types: [UTType] = [.propertyList, .xml, .data]
        if let pairingType = UTType(filenameExtension: "mobiledevicepairing") {
            types.insert(pairingType, at: 0)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let picked = urls.first else { return }
        do {
            let parent = pairingFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: pairingFileURL.path) {
                try FileManager.default.removeItem(at: pairingFileURL)
            }
            try FileManager.default.copyItem(at: picked, to: pairingFileURL)
            hasAttemptedAutoActivation = false
            statusLabel.text = "Imported pairing file."
            refreshState()
            triggerAutoActivationIfReady()
        } catch {
            statusLabel.text = "Failed to save pairing file: \(error.localizedDescription)"
        }
    }

    @objc private func onDevicePairTapped() {
        if isPairing {
            statusLabel.text = "Stopping on-device pairing..."
            onDevicePairing.cancel()
            return
        }

        isPairing = true
        setPairButtonTitle("Stop On-Device Pairing")
        setBusy(true, message: "Preparing on-device RemotePairing...")
        onDevicePairing.start(
            onEvent: { [weak self] event in
                guard let self, !self.completed, self.isPairing else { return }
                switch event {
                case .listening(let hostName, let port):
                    self.statusLabel.text = "Starting Bonjour service for \"\(hostName)\" (port \(port))..."
                case .published(let hostName, let port):
                    self.statusLabel.text = """
                    Advertising "\(hostName)" (port \(port)).
                    1. Tap "Open Developer Mode (Wireless Pairing)" below, or open iOS Settings → Privacy & Security → Developer Mode.
                    2. Tap "\(hostName)" to start pairing.
                    3. Enter the 6-digit PIN from the notification (it will also appear here).
                    """
                case .pinReceived(let pin):
                    self.statusLabel.text = """
                    Pairing PIN: \(pin)
                    Enter this 6-digit PIN in Settings → Privacy & Security → Developer Mode.
                    """
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isPairing = false
                self.setPairButtonTitle("Pair On-Device (iOS 27+)")
                self.setBusy(false, message: nil)
                switch result {
                case .success(let data):
                    do {
                        let parent = self.pairingFileURL.deletingLastPathComponent()
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                        try data.write(to: self.pairingFileURL, options: .atomic)
                        self.hasAttemptedAutoActivation = false
                        self.autoLaunchVpnRequested = true
                        self.statusLabel.text = "On-device pairing succeeded. Checking LocalDevVPN to activate JIT..."
                        self.refreshState()
                        if UIApplication.shared.applicationState == .active {
                            self.probeLocalDevVpn(
                                retriesRemaining: 1,
                                retryInterval: 0.3,
                                allowAutoLaunchVpn: true,
                                isReturningFromVpn: false
                            )
                        }
                    } catch {
                        self.statusLabel.text = "Failed to store pairing file: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        )
    }

    private var isJitReadyForColdStart: Bool {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            return rvvm_host_is_traced()
        }
        return rvvm_host_check_jit_enabled()
    }

    private func setActiveJitToken(_ token: UUID?) {
        jitStateLock.lock()
        activeJitToken = token
        jitStateLock.unlock()
    }

    private func isJitTokenActive(_ token: UUID) -> Bool {
        jitStateLock.lock()
        defer { jitStateLock.unlock() }
        return activeJitToken == token
    }

    private func clearJitTokenIfMatching(_ token: UUID) -> Bool {
        jitStateLock.lock()
        defer { jitStateLock.unlock() }
        guard activeJitToken == token else { return false }
        activeJitToken = nil
        return true
    }

    @objc private func activateJitTapped() {
        if isJitReadyForColdStart {
            finish(.success(()))
            return
        }

        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let needsScript = majorVersion >= 26
        let token = UUID()
        setActiveJitToken(token)
        setBusy(true, message: "Activating Pure JIT via DeskFleetJITHelper (first run may download Developer Disk Image)...")

        RvvmJitHelperLauncher.activateJit(
            withPairingPath: pairingFileURL.path,
            targetPid: getpid(),
            needsScript: needsScript
        ) { [weak self] success, errorMessage in
            DispatchQueue.main.async {
                guard let self, !self.completed, self.isJitTokenActive(token) else { return }
                if success && self.isJitReadyForColdStart {
                    _ = self.clearJitTokenIfMatching(token)
                    self.finish(.success(()))
                } else if !success {
                    guard self.clearJitTokenIfMatching(token) else { return }
                    self.setBusy(false, message: errorMessage ?? "JIT helper failed")
                }
            }
        }

        // On iOS 26+, StikJIT's universal script keeps the helper request open until librvvm
        // allocates JIT caches and invokes rvvm_ios_jit_detach(), so poll P_TRACED (or CS_DEBUGGED
        // on iOS 17.4-18). First run may take 30-90s to download and mount the Developer Disk Image.
        let deadline = Date().addingTimeInterval(120.0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while Date() < deadline {
                guard let self, self.isJitTokenActive(token) else { return }
                if self.isJitReadyForColdStart {
                    DispatchQueue.main.async {
                        guard self.clearJitTokenIfMatching(token), !self.completed else { return }
                        self.finish(.success(()))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            DispatchQueue.main.async {
                guard let self, self.clearJitTokenIfMatching(token), !self.completed else { return }
                self.setBusy(false, message: "Timed out waiting for JIT activation. Verify LocalDevVPN and pairing file.")
            }
        }
    }

    @objc private func cancelTapped() {
        probeGeneration += 1
        setActiveJitToken(nil)
        onDevicePairing.cancel()
        finish(.failure(NSError(
            domain: "RvvmJitSetupViewController",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "JIT activation cancelled by user"]
        )))
    }

    private func setBusy(_ busy: Bool, message: String?) {
        isBusy = busy
        openVpnButton.isEnabled = !busy
        importButton.isEnabled = !busy
        pairButton.isEnabled = !busy || isPairing
        openDeveloperModeButton.isEnabled = true
        activateButton.isEnabled = !busy && hasPairingFile
        if busy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        if let message {
            statusLabel.text = message
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        probeGeneration += 1
        setActiveJitToken(nil)
        dismiss(animated: true) { [onComplete] in
            onComplete(result)
        }
    }
}
