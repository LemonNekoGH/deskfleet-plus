// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
// Wraps the MIT-licensed rppairing static library for iOS 27+ on-device RemotePairing.
import Foundation
import IshPlusRPPairing
import UIKit
import UserNotifications

internal final class RvvmOnDevicePairing: NSObject, NetServiceDelegate {
    enum Event {
        case listening(hostName: String, port: UInt16)
        case published(hostName: String, port: UInt16)
        case pinReceived(String)
    }

    private let advertisedHostName = "DeskFleet Plus"
    private let workQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.rppairing")
    private let stateLock = NSLock()
    private let keepAlive = RvvmBackgroundKeepAlive()

    private var advertisedService: NetService?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var active = false
    private var eventHandler: ((Event) -> Void)?
    private var advertisedPort: UInt16 = 0
    private var publishErrorMessage: String?

    static var isSupportedOnCurrentOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    deinit {
        ishplus_pairing_cancel()
        keepAlive.stop()
        stateLock.lock()
        let service = advertisedService
        advertisedService = nil
        let taskId = backgroundTaskId
        backgroundTaskId = .invalid
        eventHandler = nil
        stateLock.unlock()
        if service != nil || taskId != .invalid {
            DispatchQueue.main.async {
                service?.stop()
                if taskId != .invalid {
                    UIApplication.shared.endBackgroundTask(taskId)
                }
            }
        }
    }

    func start(
        onEvent: @escaping (Event) -> Void,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        stateLock.lock()
        if active {
            stateLock.unlock()
            DispatchQueue.main.async {
                completion(.failure(NSError(
                    domain: "RvvmOnDevicePairing",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "On-device pairing is already running"]
                )))
            }
            return
        }
        active = true
        publishErrorMessage = nil
        advertisedPort = 0
        eventHandler = onEvent
        stateLock.unlock()

        let hostName = advertisedHostName
        let modelName = Thread.isMainThread ? UIDevice.current.model : DispatchQueue.main.sync { UIDevice.current.model }

        DispatchQueue.main.async { [weak self] in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            guard let self, self.isActive() else { return }
            self.beginBackgroundTaskOnMain()
            self.keepAlive.start()
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            let ctx = Unmanaged.passUnretained(self).toOpaque()

            let readyCb: ishplus_pairing_ready_cb = { rawCtx, serviceNamePtr, port, keysPtr, valuesPtr, count in
                guard let rawCtx, let serviceNamePtr else { return }
                let pairing = Unmanaged<RvvmOnDevicePairing>.fromOpaque(rawCtx).takeUnretainedValue()
                let serviceName = String(cString: serviceNamePtr)
                var txtRecords: [String: Data] = [:]
                if let keysPtr, let valuesPtr, count > 0 {
                    for index in 0..<count {
                        if let k = keysPtr[index], let v = valuesPtr[index] {
                            txtRecords[String(cString: k)] = Data(String(cString: v).utf8)
                        }
                    }
                }
                pairing.setAdvertisedPort(port)
                pairing.emitEvent(.listening(hostName: pairing.advertisedHostName, port: port))
                pairing.publishBonjourService(name: serviceName, port: Int32(port), txt: txtRecords)
            }

            let pinCb: ishplus_pairing_pin_cb = { rawCtx, pinPtr in
                guard let pinPtr else { return }
                let pin = String(cString: pinPtr)
                if let rawCtx {
                    let pairing = Unmanaged<RvvmOnDevicePairing>.fromOpaque(rawCtx).takeUnretainedValue()
                    pairing.emitEvent(.pinReceived(pin))
                }
                RvvmOnDevicePairing.postPinNotification(pin: pin)
            }

            var outFile: UnsafeMutablePointer<UInt8>?
            var outLen: Int = 0
            var outDevice: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?

            let rc: Int32 = hostName.withCString { nameCStr in
                modelName.withCString { modelCStr in
                    ishplus_pairing_run(
                        nameCStr,
                        modelCStr,
                        readyCb,
                        pinCb,
                        ctx,
                        &outFile,
                        &outLen,
                        &outDevice,
                        &outError
                    )
                }
            }

            self.stopBonjourService()
            self.keepAlive.stop()
            self.endBackgroundTask()

            self.stateLock.lock()
            let publishErr = self.publishErrorMessage
            self.publishErrorMessage = nil
            self.eventHandler = nil
            self.active = false
            self.stateLock.unlock()

            if let outDevice {
                ishplus_pairing_free_string(outDevice)
            }

            if rc == 0, let outFile, outLen > 0 {
                let pairingData = Data(bytes: outFile, count: outLen)
                ishplus_pairing_free(outFile, outLen)
                if let outError {
                    ishplus_pairing_free_string(outError)
                }
                DispatchQueue.main.async {
                    completion(.success(pairingData))
                }
            } else {
                let errMsg: String
                if let publishErr, !publishErr.isEmpty {
                    errMsg = publishErr
                    if let outError {
                        ishplus_pairing_free_string(outError)
                    }
                } else if let outError {
                    errMsg = String(cString: outError)
                    ishplus_pairing_free_string(outError)
                } else {
                    errMsg = "On-device RemotePairing failed (code \(rc))"
                }
                if let outFile {
                    ishplus_pairing_free(outFile, outLen)
                }
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "RvvmOnDevicePairing",
                        code: Int(rc),
                        userInfo: [NSLocalizedDescriptionKey: errMsg]
                    )))
                }
            }
        }
    }

    func cancel() {
        ishplus_pairing_cancel()
        stopBonjourService()
        keepAlive.stop()
        endBackgroundTask()
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        stateLock.lock()
        let port = advertisedPort > 0 ? advertisedPort : UInt16(clamping: max(sender.port, 0))
        stateLock.unlock()
        emitEvent(.published(hostName: advertisedHostName, port: port))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let message: String
        if code == -72008 {
            message = "Local Network permission denied or Bonjour advertising failed (-72008). Enable Settings → Privacy & Security → Local Network for DeskFleet Plus, then try again."
        } else {
            message = "Failed to advertise Bonjour pairing service (error \(code)). Check Local Network permission for DeskFleet Plus in iOS Settings."
        }
        stateLock.lock()
        publishErrorMessage = message
        stateLock.unlock()
        ishplus_pairing_cancel()
    }

    // MARK: - Helpers

    private func isActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    private func setAdvertisedPort(_ port: UInt16) {
        stateLock.lock()
        advertisedPort = port
        stateLock.unlock()
    }

    private func emitEvent(_ event: Event) {
        stateLock.lock()
        let handler = eventHandler
        stateLock.unlock()
        guard let handler else { return }
        if Thread.isMainThread {
            handler(event)
        } else {
            DispatchQueue.main.async {
                handler(event)
            }
        }
    }

    private func beginBackgroundTaskOnMain() {
        stateLock.lock()
        let previousTask = backgroundTaskId
        backgroundTaskId = .invalid
        stateLock.unlock()
        if previousTask != .invalid {
            UIApplication.shared.endBackgroundTask(previousTask)
        }
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "DeskFleetOnDevicePairing") { [weak self] in
            self?.endBackgroundTask()
        }
        stateLock.lock()
        if active {
            backgroundTaskId = taskId
            stateLock.unlock()
        } else {
            stateLock.unlock()
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
            }
        }
    }

    private func endBackgroundTask() {
        stateLock.lock()
        let taskId = backgroundTaskId
        backgroundTaskId = .invalid
        stateLock.unlock()
        guard taskId != .invalid else { return }
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    private func publishBonjourService(name: String, port: Int32, txt: [String: Data]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive() else { return }
            self.stateLock.lock()
            self.advertisedService?.stop()
            self.advertisedService = nil
            self.stateLock.unlock()

            let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: port)
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            self.stateLock.lock()
            if self.active {
                self.advertisedService = service
                self.stateLock.unlock()
                service.publish()
            } else {
                self.stateLock.unlock()
            }
        }
    }

    private func stopBonjourService() {
        stateLock.lock()
        let service = advertisedService
        advertisedService = nil
        stateLock.unlock()
        guard let service else { return }
        DispatchQueue.main.async {
            service.stop()
        }
    }

    private static func postPinNotification(pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "DeskFleet Plus Pairing PIN"
        content.body = "Enter PIN \(pin) in Settings → Privacy & Security → Developer Mode."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "deskfleet.rppairing.pin",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
