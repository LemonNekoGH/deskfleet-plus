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

    private let statusLabel = UILabel()
    private let pairingStateLabel = UILabel()
    private let vpnStateLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let importButton = UIButton(type: .system)
    private let pairButton = UIButton(type: .system)
    private let activateButton = UIButton(type: .system)

    init(pairingFileURL: URL, onComplete: @escaping (Result<Void, Error>) -> Void) {
        self.pairingFileURL = pairingFileURL
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        descriptionLabel.text = "DeskFleet runs an embedded RISC-V 64-bit Linux daemon using librvvm with RVJIT. Import your RemotePairing file and ensure LocalDevVPN is active on 10.7.0.1 to activate JIT."
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

        configureButton(importButton, title: "Import Pairing File (.plist)", style: .tinted)
        importButton.addTarget(self, action: #selector(importPairingTapped), for: .touchUpInside)

        configureButton(pairButton, title: "Pair On-Device (iOS 27+)", style: .tinted)
        pairButton.addTarget(self, action: #selector(onDevicePairTapped), for: .touchUpInside)
        pairButton.isHidden = !RvvmOnDevicePairing.isSupportedOnCurrentOS

        configureButton(activateButton, title: "Activate Pure JIT", style: .filled)
        activateButton.addTarget(self, action: #selector(activateJitTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            descriptionLabel,
            pairingStateLabel,
            vpnStateLabel,
            importButton,
            pairButton,
            activateButton,
            activityIndicator,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        refreshState()
        probeLocalDevVpn()
    }

    private func configureButton(_ button: UIButton, title: String, style: ButtonStyle) {
        var config: UIButton.Configuration = style == .filled ? .filled() : .tinted()
        config.title = title
        config.cornerStyle = .medium
        button.configuration = config
    }

    private enum ButtonStyle {
        case filled
        case tinted
    }

    private func refreshState() {
        let hasPairing = FileManager.default.fileExists(atPath: pairingFileURL.path)
        pairingStateLabel.text = hasPairing
            ? "Pairing file: Ready (\(pairingFileURL.lastPathComponent))"
            : "Pairing file: Not imported yet"
        pairingStateLabel.textColor = hasPairing ? .systemGreen : .systemOrange

        vpnStateLabel.text = vpnReachable
            ? "LocalDevVPN (10.7.0.1:62078): Reachable"
            : "LocalDevVPN (10.7.0.1:62078): Not detected (required on device)"
        vpnStateLabel.textColor = vpnReachable ? .systemGreen : .secondaryLabel

        activateButton.isEnabled = hasPairing
    }

    private func probeLocalDevVpn() {
        let connection = NWConnection(host: "10.7.0.1", port: 62078, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.cancel()
                DispatchQueue.main.async {
                    self?.vpnReachable = true
                    self?.refreshState()
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            connection.cancel()
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
            statusLabel.text = "Imported pairing file."
            refreshState()
        } catch {
            statusLabel.text = "Failed to save pairing file: \(error.localizedDescription)"
        }
    }

    @objc private func onDevicePairTapped() {
        setBusy(true, message: "Waiting for on-device RemotePairing confirmation...")
        onDevicePairing.start { [weak self] result in
            guard let self else { return }
            self.setBusy(false, message: nil)
            switch result {
            case .success(let data):
                do {
                    let parent = self.pairingFileURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try data.write(to: self.pairingFileURL, options: .atomic)
                    self.statusLabel.text = "On-device pairing succeeded."
                    self.refreshState()
                } catch {
                    self.statusLabel.text = "Failed to store pairing file: \(error.localizedDescription)"
                }
            case .failure(let error):
                self.statusLabel.text = error.localizedDescription
            }
        }
    }

    @objc private func activateJitTapped() {
        if rvvm_host_check_jit_enabled() {
            finish(.success(()))
            return
        }

        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let needsScript = majorVersion >= 26
        setBusy(true, message: "Activating Pure JIT via DeskFleetJITHelper...")

        var helperFailure: String?
        RvvmJitHelperLauncher.activateJit(
            withPairingPath: pairingFileURL.path,
            targetPid: getpid(),
            needsScript: needsScript
        ) { [weak self] success, errorMessage in
            DispatchQueue.main.async {
                guard let self, !self.completed else { return }
                if success && rvvm_host_check_jit_enabled() {
                    self.finish(.success(()))
                } else if !success {
                    helperFailure = errorMessage ?? "JIT helper failed"
                    self.setBusy(false, message: helperFailure)
                }
            }
        }

        // On iOS 26+, StikJIT's universal script keeps the helper request open until librvvm
        // allocates JIT caches and invokes rvvm_ios_jit_detach(), so poll csops(CS_DEBUGGED).
        let deadline = Date().addingTimeInterval(20.0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while Date() < deadline {
                if rvvm_host_check_jit_enabled() {
                    DispatchQueue.main.async {
                        self?.finish(.success(()))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            DispatchQueue.main.async {
                guard let self, !self.completed else { return }
                self.setBusy(false, message: helperFailure ?? "Timed out waiting for JIT activation. Verify LocalDevVPN and pairing file.")
            }
        }
    }

    @objc private func cancelTapped() {
        onDevicePairing.cancel()
        finish(.failure(NSError(
            domain: "RvvmJitSetupViewController",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "JIT activation cancelled by user"]
        )))
    }

    private func setBusy(_ busy: Bool, message: String?) {
        importButton.isEnabled = !busy
        pairButton.isEnabled = !busy
        activateButton.isEnabled = !busy && FileManager.default.fileExists(atPath: pairingFileURL.path)
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
        dismiss(animated: true) { [onComplete] in
            onComplete(result)
        }
    }
}
