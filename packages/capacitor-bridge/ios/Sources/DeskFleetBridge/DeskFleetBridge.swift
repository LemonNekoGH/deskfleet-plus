import AuthenticationServices
import Capacitor
import Foundation
import ReplayKit
import UIKit

@_silgen_name("deskfleet_ios_start")
internal func deskfleetIosStart(_ onEvent: (@convention(c) (UnsafePointer<CChar>?) -> Void)?)

@_silgen_name("deskfleet_ios_send_command")
internal func deskfleetIosSendCommand(_ commandJson: UnsafePointer<CChar>?)

@_silgen_name("deskfleet_ios_stop")
internal func deskfleetIosStop()

@_silgen_name("deskfleet_ios_touch")
internal func deskfleetIosTouch(_ video: UnsafeMutableRawPointer?, _ kind: Int32,
                               _ x: Double, _ y: Double, _ dx: Double, _ dy: Double)

@_silgen_name("deskfleet_ios_test_nat")
internal func deskfleetIosTestNat(_ server: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("deskfleet_ios_ports_init")
internal func deskfleetIosPortsInit(_ onEvent: (@convention(c) (UnsafePointer<CChar>?) -> Void)?)

@_silgen_name("deskfleet_ios_ports_call")
internal func deskfleetIosPortsCall(_ requestJson: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("deskfleet_ios_ports_close_all")
internal func deskfleetIosPortsCloseAll()

@_silgen_name("deskfleet_ios_string_free")
internal func deskfleetIosStringFree(_ ptr: UnsafeMutablePointer<CChar>?)

private let viewerEventCallback: @convention(c) (UnsafePointer<CChar>?) -> Void = { payloadPtr in
    guard let payloadPtr else { return }
    let payload = String(cString: payloadPtr)
    DeskFleetBridge.activePlugin?.notifyListeners("viewerEvent", data: ["payload": payload])
}

private let portsEventCallback: @convention(c) (UnsafePointer<CChar>?) -> Void = { payloadPtr in
    guard let payloadPtr else { return }
    DeskFleetBridge.activePortsPlugin?.notifyListeners("portsEvent", data: ["payload": String(cString: payloadPtr)])
}

@objc(DeskFleetBridge)
public class DeskFleetBridge: CAPPlugin, CAPBridgedPlugin, ASWebAuthenticationPresentationContextProviding {
    public let identifier = "DeskFleetBridge"
    public let jsName = "DeskFleetBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "authenticate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "testNat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "portsCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openExternal", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "outlineAudioStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startOutlineAudio", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopOutlineAudio", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speechStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSpeech", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeech", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelSpeech", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "filesOpen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "filesCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "filesChooseDirectory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "filesClose", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTelemetryConsent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTelemetryUserId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "logTelemetryEvent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "haptic", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonSetEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonStart", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonLogs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonPrepareEnrollment", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonEnroll", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localDaemonSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "iosScreenShareStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "iosScreenShareProbeCoreDevice", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "iosScreenShareStartBroadcast", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "iosScreenShareStopBroadcast", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "iosScreenShareOpenLocalDevVpn", returnType: CAPPluginReturnPromise)
    ]

    nonisolated(unsafe) internal static weak var activePlugin: DeskFleetBridge?
    nonisolated(unsafe) internal static weak var activePortsPlugin: DeskFleetBridge?
    nonisolated(unsafe) internal static weak var activeController: RemoteDesktopViewController?
    private static let portsQueue = DispatchQueue(label: "ai.yetanother.deskfleet.ports")
    private static var portsInitialized = false
    private var authSession: ASWebAuthenticationSession?
    private var speechInput: SpeechInput?
    private lazy var impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private lazy var selectionFeedback = UISelectionFeedbackGenerator()
    private let localFiles = LocalFilesBridge()
    private var rvvmDaemon: RvvmDaemonManager?
    private var screenBridgeServer: IosScreenBridgeServer?
    private var pendingScreenShareCall: CAPPluginCall?
    private var screenSharePickerView: RPSystemBroadcastPickerView?
    private var screenShareLifecycleObservers: [NSObjectProtocol] = []
    private var screenShareWaitTimer: DispatchSourceTimer?
    private var screenSharePickerPresented = false
    private var screenShareStartDeadlineMs: UInt64 = 0

    private static func defaultPairingFileURL() -> URL {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: IosScreenShareProtocol.appGroupId
        ) {
            return group.appendingPathComponent("pairingFile.plist")
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return docs.appendingPathComponent("VM/pairingFile.plist")
    }

    private func screenBridge() -> IosScreenBridgeServer {
        if let screenBridgeServer { return screenBridgeServer }
        let server = IosScreenBridgeServer(
            pairingFileURLProvider: { [weak self] in
                self?.rvvmDaemon?.pairingFileURL() ?? Self.defaultPairingFileURL()
            },
            sharedStore: sharedStore,
            onStateChanged: { [weak self] state in
                guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else { return }
                self?.notifyListeners("iosScreenShareState", data: coerced)
            },
            onCapabilitiesChanged: { [weak self] in
                self?.rvvmDaemon?.refreshCapabilitiesAsync()
            }
        )
        screenBridgeServer = server
        return server
    }

    public override func load() {
        super.load()
        daemon().autoStartIfEnabled()
    }

    private func daemon() -> RvvmDaemonManager {
        if let rvvmDaemon { return rvvmDaemon }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let versionName = (version?.isEmpty == false) ? version! : "0.0.0"
        let deviceName: String = Thread.isMainThread
            ? UIDevice.current.name
            : DispatchQueue.main.sync { UIDevice.current.name }
        let fallbackName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "iOS" : deviceName
        let manager = RvvmDaemonManager(
            versionName: versionName,
            fallbackMachineName: fallbackName,
            onLog: { [weak self] chunk in
                self?.notifyListeners("localDaemonLog", data: ["chunk": chunk])
            },
            onStateChanged: { [weak self] state in
                guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else { return }
                self?.notifyListeners("localDaemonState", data: coerced)
            },
            screenBridgeProvider: { [weak self] in
                self?.screenBridge().ensureStarted()
            }
        )
        rvvmDaemon = manager
        return manager
    }

    @objc func localDaemonState(_ call: CAPPluginCall) {
        let state = daemon().localDaemonState()
        guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
            call.reject("Invalid local daemon state payload")
            return
        }
        call.resolve(coerced)
    }

    @objc func localDaemonSetEnabled(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            call.reject("Missing enabled flag")
            return
        }
        let manager = daemon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = manager.setLocalDaemonEnabled(enabled) { [weak self] in
                self?.bridge?.viewController
            }
            guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                call.reject("Invalid local daemon state payload")
                return
            }
            call.resolve(coerced)
        }
    }

    @objc func localDaemonStart(_ call: CAPPluginCall) {
        let manager = daemon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = manager.startLocalDaemon(interactive: true) { [weak self] in
                self?.bridge?.viewController
            }
            guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                call.reject("Invalid local daemon state payload")
                return
            }
            call.resolve(coerced)
        }
    }

    @objc func localDaemonLogs(_ call: CAPPluginCall) {
        call.resolve(["output": daemon().recentLogs()])
    }

    @objc func localDaemonStatus(_ call: CAPPluginCall) {
        let manager = daemon()
        DispatchQueue.global(qos: .userInitiated).async {
            let status = manager.status()
            guard let coerced = JSTypes.coerceDictionaryToJSObject(status) else {
                call.reject("Invalid local daemon status payload")
                return
            }
            call.resolve(coerced)
        }
    }

    @objc func localDaemonPrepareEnrollment(_ call: CAPPluginCall) {
        guard let serverUrl = call.getString("serverUrl")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverUrl.isEmpty else {
            call.reject("Missing serverUrl")
            return
        }
        guard let teamId = call.getString("teamId")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamId.isEmpty else {
            call.reject("Missing teamId")
            return
        }
        let manager = daemon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let prepared = try manager.prepareEnrollment(serverUrl: serverUrl, teamId: teamId) { [weak self] in
                    self?.bridge?.viewController
                }
                guard let coerced = JSTypes.coerceDictionaryToJSObject(prepared) else {
                    call.reject("Invalid prepare-enrollment payload")
                    return
                }
                call.resolve(coerced)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func localDaemonEnroll(_ call: CAPPluginCall) {
        guard let serverUrl = call.getString("serverUrl")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverUrl.isEmpty else {
            call.reject("Missing serverUrl")
            return
        }
        guard let machineId = call.getString("machineId")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !machineId.isEmpty else {
            call.reject("Missing machineId")
            return
        }
        guard let teamId = call.getString("teamId")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamId.isEmpty else {
            call.reject("Missing teamId")
            return
        }
        guard let token = call.getString("token")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            call.reject("Missing token")
            return
        }
        guard let originId = call.getString("originId")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !originId.isEmpty else {
            call.reject("Missing originId")
            return
        }
        let manager = daemon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let credentialsJson = try RvvmDaemonCommands.credentialsJson(
                    machineId: machineId,
                    teamId: teamId,
                    token: token,
                    originId: originId
                )
                let enrolled = try manager.enroll(serverUrl: serverUrl, credentialsJson: credentialsJson) { [weak self] in
                    self?.bridge?.viewController
                }
                guard let coerced = JSTypes.coerceDictionaryToJSObject(enrolled) else {
                    call.reject("Invalid enroll payload")
                    return
                }
                call.resolve(coerced)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func localDaemonSettings(_ call: CAPPluginCall) {
        let rawArgs = call.getArray("args") ?? []
        var args: [String] = []
        args.reserveCapacity(rawArgs.count)
        for item in rawArgs {
            guard let text = item as? String else {
                call.reject("Invalid settings argument")
                return
            }
            args.append(text)
        }
        let manager = daemon()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let settings = try manager.settings(args: args)
                guard let coerced = JSTypes.coerceDictionaryToJSObject(settings) else {
                    call.reject("Invalid local daemon settings payload")
                    return
                }
                call.resolve(coerced)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func filesOpen(_ call: CAPPluginCall) { localFiles.open(call) }
    @objc func filesCall(_ call: CAPPluginCall) { localFiles.perform(call) }
    @objc func filesChooseDirectory(_ call: CAPPluginCall) {
        localFiles.choose(call) { [weak self] in self?.bridge?.viewController }
    }
    @objc func filesClose(_ call: CAPPluginCall) { localFiles.close(call) }

    @objc func setTelemetryConsent(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled") ?? false
        call.resolve(["configured": FirebaseTelemetryBridge.setConsent(enabled: enabled)])
    }

    @objc func setTelemetryUserId(_ call: CAPPluginCall) {
        let userId = call.getString("userId")
        call.resolve(["configured": FirebaseTelemetryBridge.setUserId(userId)])
    }

    @objc func logTelemetryEvent(_ call: CAPPluginCall) {
        guard let name = call.getString("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            call.reject("Missing telemetry event name")
            return
        }
        let params = call.getObject("params")
        call.resolve(["configured": FirebaseTelemetryBridge.logEvent(name: name, params: params)])
    }

    @objc func haptic(_ call: CAPPluginCall) {
        let activate = call.getString("kind") == "activate"
        DispatchQueue.main.async { [weak self] in
            if activate {
                self?.impactFeedback.impactOccurred()
            } else {
                self?.selectionFeedback.selectionChanged()
            }
            self?.selectionFeedback.prepare()
            call.resolve()
        }
    }

    private func speech() -> SpeechInput {
        if let speechInput { return speechInput }
        let input = SpeechInput { [weak self] event in
            self?.notifyListeners("speechEvent", data: event)
        }
        speechInput = input
        return input
    }

    @objc func speechStatus(_ call: CAPPluginCall) {
        let locale = call.getString("locale") ?? Locale.current.identifier
        DispatchQueue.main.async { [weak self] in
            call.resolve(["supported": self?.speech().isSupported(locale: locale) ?? false])
        }
    }

    @objc func startSpeech(_ call: CAPPluginCall) {
        guard let id = call.getString("sessionId"), !id.isEmpty,
              let locale = call.getString("locale"), !locale.isEmpty else {
            call.reject("Missing speech session ID or locale")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return call.reject("Speech bridge unavailable", "unavailable") }
            self.speech().start(id: id, locale: locale) { call.resolve() }
        }
    }

    @objc func stopSpeech(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            if let id = call.getString("sessionId") { self?.speechInput?.stop(id: id) }
            call.resolve()
        }
    }

    @objc func cancelSpeech(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            if let id = call.getString("sessionId") { self?.speechInput?.cancel(id: id) }
            call.resolve()
        }
    }

    @objc func authenticate(_ call: CAPPluginCall) {
        guard let rawUrl = call.getString("url"),
              let url = URL(string: rawUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let callbackScheme = call.getString("callbackScheme"),
              !callbackScheme.isEmpty else {
            call.reject("Invalid authentication parameters")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                call.reject("Bridge unavailable")
                return
            }
            self.authSession?.cancel()

            weak var createdSession: ASWebAuthenticationSession?
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                DispatchQueue.main.async {
                    if let createdSession, self?.authSession === createdSession {
                        self?.authSession = nil
                    }
                    if let error {
                        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            call.reject("Sign-in canceled", "CANCELED", error)
                        } else {
                            call.reject(error.localizedDescription, nil, error)
                        }
                        return
                    }
                    guard let callbackURL else {
                        call.reject("Missing authentication callback URL")
                        return
                    }
                    call.resolve(["url": callbackURL.absoluteString])
                }
            }
            createdSession = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session

            if !session.start() {
                self.authSession = nil
                call.reject("Failed to start authentication session")
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            self.bridge?.viewController?.viewIfLoaded?.window
                ?? UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)
                ?? ASPresentationAnchor()
        }
    }

    private lazy var sharedStore = OutlineAudioSharedStore()
    private var pollTimer: DispatchSourceTimer?
    private var pendingStartCall: CAPPluginCall?
    private var pickerView: RPSystemBroadcastPickerView?
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var pickerPresented = false
    private var startDeadlineMs: UInt64 = 0
    private var lastAudioTs: UInt64 = 0

    @objc func open(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let root = self.bridge?.viewController else {
                call.reject("Activity unavailable")
                return
            }
            Self.activePlugin = self
            // Retire the previous view while its input and Metal surface still
            // address its own Rust session.
            if let previous = Self.activeController {
                previous.prepareForExternalStop()
                previous.dismiss(animated: false)
            }
            deskfleetIosStart(viewerEventCallback)

            let controller = RemoteDesktopViewController()
            controller.modalPresentationStyle = .fullScreen
            Self.activeController = controller

            var presenter: UIViewController = root
            while let next = presenter.presentedViewController, !next.isBeingDismissed {
                presenter = next
            }
            presenter.present(controller, animated: false) { call.resolve() }
        }
    }

    @objc func send(_ call: CAPPluginCall) {
        guard let command = call.getString("command"), !command.isEmpty else {
            call.reject("Missing command payload")
            return
        }
        DispatchQueue.main.async {
            if let data = command.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                Self.activeController?.applyViewerCommand(object)
            }
            command.withCString { deskfleetIosSendCommand($0) }
            call.resolve()
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        Self.stopSession { call.resolve() }
    }

    @objc func openExternal(_ call: CAPPluginCall) {
        guard let rawUrl = call.getString("url"),
              let url = URL(string: rawUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            call.reject("Invalid external URL")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened { call.resolve() }
                else { call.reject("Failed to open URL") }
            }
        }
    }

    @objc func portsCall(_ call: CAPPluginCall) {
        guard let request = call.getString("request"), !request.isEmpty else {
            call.reject("Missing port forwarding request")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.portsQueue.sync {
                Self.activePortsPlugin = self
                if !Self.portsInitialized {
                    deskfleetIosPortsInit(portsEventCallback)
                    Self.portsInitialized = true
                }
            }
            guard let ptr = request.withCString({ deskfleetIosPortsCall($0) }) else {
                call.reject("Failed to invoke port forwarding")
                return
            }
            defer { deskfleetIosStringFree(ptr) }
            call.resolve(["response": String(cString: ptr)])
        }
    }

    @objc func testNat(_ call: CAPPluginCall) {
        guard let server = call.getString("server"), !server.isEmpty else {
            call.reject("Missing STUN server")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let ptr = server.withCString({ deskfleetIosTestNat($0) }) else {
                call.reject("Failed to test NAT")
                return
            }
            defer { deskfleetIosStringFree(ptr) }
            guard let data = String(cString: ptr).data(using: .utf8),
                  let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                call.reject("Invalid NAT test response")
                return
            }
            if let error = response["error"] as? String, !error.isEmpty {
                call.reject(error)
                return
            }
            guard let rawResult = response["result"] as? [String: Any],
                  var result = JSTypes.coerceDictionaryToJSObject(rawResult) else {
                call.reject("Missing NAT test result")
                return
            }
            if result["publicAddress"] is NSNull {
                result.removeValue(forKey: "publicAddress")
            }
            call.resolve(result)
        }
    }

    @objc func outlineAudioStatus(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return call.resolve(["supported": false, "active": false]) }
            let active = self.sharedStore?.isCurrentlyActive() ?? false
            if active { self.startPollingBands() }
            call.resolve(["supported": self.sharedStore != nil, "active": active])
        }
    }

    @objc func startOutlineAudio(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let root = self.bridge?.viewController, let store = self.sharedStore else {
                call.reject("System audio broadcast is unavailable.", "unavailable")
                return
            }
            if store.isCurrentlyActive() {
                store.setConsumerActive(OutlineAudioSharedStore.consumerOutlineAudio, active: true)
                self.startPollingBands()
                call.resolve(["started": true])
                return
            }

            self.resolvePendingStart(started: false)
            store.setConsumerActive(OutlineAudioSharedStore.consumerOutlineAudio, active: true)
            self.pendingStartCall = call
            self.pickerPresented = false
            self.startDeadlineMs = OutlineAudioSharedStore.nowMs() + 2_000

            let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            picker.preferredExtension = "\(Bundle.main.bundleIdentifier ?? "moe.remon.deskfleet.plus").BroadcastUpload"
            picker.showsMicrophoneButton = false
            picker.isHidden = true
            picker.isUserInteractionEnabled = false
            root.view.addSubview(picker)
            self.pickerView = picker

            guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
                self.resolvePendingStart(started: false, failure: "Broadcast picker is unavailable.")
                return
            }

            let center = NotificationCenter.default
            self.appLifecycleObservers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.pickerPresented = true
                    self?.startDeadlineMs = .max
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    guard let self, self.pickerPresented else { return }
                    self.startDeadlineMs = OutlineAudioSharedStore.nowMs() + 1_500
                }
            ]
            self.startPollingBands()
            button.sendActions(for: .touchUpInside)
        }
    }

    @objc func stopOutlineAudio(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.resolvePendingStart(started: false)
            self?.stopPollingBands()
            self?.sharedStore?.setConsumerActive(OutlineAudioSharedStore.consumerOutlineAudio, active: false)
            call.resolve()
        }
    }

    // MARK: - iOS Remote Screen Sharing (CoreDevice + ReplayKit)

    @objc func iosScreenShareStatus(_ call: CAPPluginCall) {
        let probe = call.getBool("probeCoreDevice") ?? false
        let bridge = screenBridge()
        _ = bridge.ensureStarted()
        DispatchQueue.global(qos: .userInitiated).async {
            let state = bridge.refreshStatus(probeCoreDevice: probe)
            guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                call.reject("Invalid iOS screen share state payload")
                return
            }
            call.resolve(coerced)
        }
    }

    @objc func iosScreenShareProbeCoreDevice(_ call: CAPPluginCall) {
        let bridge = screenBridge()
        _ = bridge.ensureStarted()
        DispatchQueue.global(qos: .userInitiated).async {
            let state = bridge.refreshStatus(probeCoreDevice: true)
            guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                call.reject("Invalid iOS screen share state payload")
                return
            }
            call.resolve(coerced)
        }
    }

    @objc func iosScreenShareStartBroadcast(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let root = self.bridge?.viewController, let store = self.sharedStore else {
                call.reject("ReplayKit broadcast is unavailable.", "unavailable")
                return
            }
            let bridge = self.screenBridge()
            _ = bridge.ensureStarted()

            if store.isCurrentlyActive() {
                store.setConsumerActive(OutlineAudioSharedStore.consumerScreenShare, active: true)
                DispatchQueue.global(qos: .userInitiated).async {
                    let state = bridge.refreshStatus(probeCoreDevice: false)
                    guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                        call.reject("Invalid iOS screen share state payload")
                        return
                    }
                    call.resolve(coerced)
                }
                return
            }

            self.resolvePendingScreenShareStart(failure: nil)
            store.setConsumerActive(OutlineAudioSharedStore.consumerScreenShare, active: true)
            self.pendingScreenShareCall = call
            self.screenSharePickerPresented = false
            self.screenShareStartDeadlineMs = OutlineAudioSharedStore.nowMs() + 2_000

            let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            picker.preferredExtension = "\(Bundle.main.bundleIdentifier ?? "moe.remon.deskfleet.plus").BroadcastUpload"
            picker.showsMicrophoneButton = false
            picker.isHidden = true
            picker.isUserInteractionEnabled = false
            root.view.addSubview(picker)
            self.screenSharePickerView = picker

            guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
                self.resolvePendingScreenShareStart(failure: "Broadcast picker is unavailable.")
                return
            }

            let center = NotificationCenter.default
            self.screenShareLifecycleObservers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.screenSharePickerPresented = true
                    self?.screenShareStartDeadlineMs = .max
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    guard let self, self.screenSharePickerPresented else { return }
                    self.screenShareStartDeadlineMs = OutlineAudioSharedStore.nowMs() + 2_000
                }
            ]

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
            timer.setEventHandler { [weak self] in
                self?.pollScreenShareBroadcastStart()
            }
            self.screenShareWaitTimer = timer
            timer.resume()
            button.sendActions(for: .touchUpInside)
        }
    }

    @objc func iosScreenShareStopBroadcast(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return call.reject("Bridge unavailable") }
            self.resolvePendingScreenShareStart(failure: nil)
            self.sharedStore?.setConsumerActive(OutlineAudioSharedStore.consumerScreenShare, active: false)
            let bridge = self.screenBridge()
            DispatchQueue.global(qos: .userInitiated).async {
                let state = bridge.refreshStatus(probeCoreDevice: false)
                guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                    call.reject("Invalid iOS screen share state payload")
                    return
                }
                call.resolve(coerced)
            }
        }
    }

    @objc func iosScreenShareOpenLocalDevVpn(_ call: CAPPluginCall) {
        let scheme = RvvmJitRouting.bundleCallbackScheme()
        let url = RvvmJitRouting.localDevVpnEnableURL(callbackScheme: scheme)
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened {
                    call.resolve()
                } else {
                    call.reject("LocalDevVPN is not installed on this device.")
                }
            }
        }
    }

    private func pollScreenShareBroadcastStart() {
        guard let store = sharedStore else {
            resolvePendingScreenShareStart(failure: "Broadcast store unavailable.")
            return
        }
        let nowMs = OutlineAudioSharedStore.nowMs()
        if store.isCurrentlyActive(nowMs: nowMs) {
            resolvePendingScreenShareStart(failure: nil)
            return
        }
        if nowMs >= screenShareStartDeadlineMs {
            store.setConsumerActive(OutlineAudioSharedStore.consumerScreenShare, active: false)
            resolvePendingScreenShareStart(
                failure: screenSharePickerPresented ? nil : "Broadcast picker did not appear."
            )
        }
    }

    private func resolvePendingScreenShareStart(failure: String?) {
        screenShareWaitTimer?.cancel()
        screenShareWaitTimer = nil
        for observer in screenShareLifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        screenShareLifecycleObservers.removeAll()
        screenSharePickerView?.removeFromSuperview()
        screenSharePickerView = nil

        guard let call = pendingScreenShareCall else { return }
        pendingScreenShareCall = nil
        if let failure {
            call.reject(failure, "unavailable")
            return
        }
        let bridge = screenBridge()
        DispatchQueue.global(qos: .userInitiated).async {
            let state = bridge.refreshStatus(probeCoreDevice: false)
            guard let coerced = JSTypes.coerceDictionaryToJSObject(state) else {
                call.reject("Invalid iOS screen share state payload")
                return
            }
            call.resolve(coerced)
        }
    }

    private func resolvePendingStart(started: Bool, failure: String? = nil) {
        for observer in appLifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        appLifecycleObservers.removeAll()
        pickerView?.removeFromSuperview()
        pickerView = nil
        guard let call = pendingStartCall else { return }
        pendingStartCall = nil
        if let failure { call.reject(failure, "unavailable") }
        else { call.resolve(["started": started]) }
    }

    private func startPollingBands() {
        guard pollTimer == nil else { return }
        lastAudioTs = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(22), repeating: .milliseconds(22), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.pollSharedSpectrum() }
        pollTimer = timer
        timer.resume()
    }

    private func stopPollingBands() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func pollSharedSpectrum() {
        guard let store = sharedStore else { return }
        let nowMs = OutlineAudioSharedStore.nowMs()
        let (alive, sampleRate, binsBase64) = store.readState(nowMs: nowMs, lastAudioTs: &lastAudioTs)

        if pendingStartCall != nil {
            if alive {
                resolvePendingStart(started: true)
            } else if nowMs >= startDeadlineMs {
                stopPollingBands()
                resolvePendingStart(started: false, failure: pickerPresented ? nil : "Broadcast picker did not appear.")
            }
            return
        }

        guard alive else {
            stopPollingBands()
            notifyListeners("outlineAudioStopped", data: [:])
            return
        }

        if let binsBase64 {
            notifyListeners("outlineAudioBands", data: ["sampleRate": sampleRate, "bins": binsBase64])
        }
    }

    deinit {
        localFiles.dispose()
        let speech = speechInput
        DispatchQueue.main.async { speech?.dispose() }
        pollTimer?.cancel()
        screenShareWaitTimer?.cancel()
        for observer in appLifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in screenShareLifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        screenBridgeServer?.stop()
        let session = authSession
        authSession = nil
        if Thread.isMainThread {
            session?.cancel()
        } else {
            DispatchQueue.main.async { session?.cancel() }
        }
        Self.stopSession()
        deskfleetIosPortsCloseAll()
    }

    internal static func stopSession(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            if let controller = activeController {
                activeController = nil
                controller.prepareForExternalStop()
                if !controller.isBeingDismissed { controller.dismiss(animated: false) }
            }
            deskfleetIosStop()
            completion?()
        }
    }
}
