// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
// Wraps the MIT-licensed rppairing static library for iOS 27+ on-device RemotePairing.
import Foundation
import IshPlusRPPairing
import UIKit
import UserNotifications

internal final class RvvmOnDevicePairing: NSObject, NetServiceDelegate {
    private var advertisedService: NetService?
    private let workQueue = DispatchQueue(label: "moe.remon.deskfleet.plus.rppairing")
    private var active = false

    static var isSupportedOnCurrentOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    func start(
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard !self.active else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "RvvmOnDevicePairing",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "On-device pairing is already running"]
                    )))
                }
                return
            }
            self.active = true

            let hostName: String = DispatchQueue.main.sync { UIDevice.current.name }
            let modelName: String = DispatchQueue.main.sync { UIDevice.current.model }
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
                pairing.publishBonjourService(name: serviceName, port: Int32(port), txt: txtRecords)
            }

            let pinCb: ishplus_pairing_pin_cb = { _, pinPtr in
                guard let pinPtr else { return }
                let pin = String(cString: pinPtr)
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
            self.active = false

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
                if let outError {
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
    }

    private func publishBonjourService(name: String, port: Int32, txt: [String: Data]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advertisedService?.stop()
            let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: port)
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            service.publish()
            self.advertisedService = service
        }
    }

    private func stopBonjourService() {
        DispatchQueue.main.async { [weak self] in
            self?.advertisedService?.stop()
            self?.advertisedService = nil
        }
    }

    private static func postPinNotification(pin: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "DeskFleet Pairing PIN"
            content.body = "Enter PIN \(pin) in Settings → General → Remote Pairing."
            let request = UNNotificationRequest(
                identifier: "deskfleet.rppairing.pin",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
