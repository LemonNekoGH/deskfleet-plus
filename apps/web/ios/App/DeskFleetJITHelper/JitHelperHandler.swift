// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation
#if !targetEnvironment(simulator)
import StikJIT
#endif

@objc(DeskFleetJitHelper)
public final class DeskFleetJitHelper: NSObject {
    @objc(handleRequestWithContext:pairingPath:pairingData:targetPid:needsScript:)
    public static func handleRequest(
        withContext context: NSExtensionContext,
        pairingPath: String,
        pairingData: Data?,
        targetPid: Int32,
        needsScript: Bool
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let resultItem = NSExtensionItem()
            #if targetEnvironment(simulator)
            resultItem.userInfo = ["success": true]
            context.completeRequest(returningItems: [resultItem], completionHandler: nil)
            #else
            do {
                guard targetPid > 0 else {
                    throw NSError(
                        domain: "DeskFleetJITHelper",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid host PID for JIT activation"]
                    )
                }

                let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let resolvedPairingURL: URL
                if let pairingData, !pairingData.isEmpty {
                    try FileManager.default.createDirectory(at: cacheBase, withIntermediateDirectories: true)
                    let localPairingURL = cacheBase.appendingPathComponent("StikJIT-pairingFile.plist")
                    try pairingData.write(to: localPairingURL, options: .atomic)
                    resolvedPairingURL = localPairingURL
                } else {
                    guard !pairingPath.isEmpty else {
                        throw NSError(
                            domain: "DeskFleetJITHelper",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Missing RemotePairing file path"]
                        )
                    }
                    resolvedPairingURL = URL(fileURLWithPath: pairingPath)
                }

                let ddiDirectory = cacheBase.appendingPathComponent("StikJIT-DDI", isDirectory: true)
                try FileManager.default.createDirectory(at: ddiDirectory, withIntermediateDirectories: true)
                let ddiPaths = DDIPaths.default(in: ddiDirectory)

                try StikJIT.enableJIT(
                    targetPID: targetPid,
                    pairingFile: resolvedPairingURL,
                    ddiPaths: ddiPaths,
                    configuration: .default,
                    script: .universal,
                    forceScript: needsScript,
                    preparationProgress: { stage in
                        NSLog("[DeskFleetJITHelper] preparation stage: %@", String(describing: stage))
                    },
                    progress: { message in
                        NSLog("[DeskFleetJITHelper] progress: %@", message)
                    }
                )
                resultItem.userInfo = ["success": true]
            } catch {
                NSLog("[DeskFleetJITHelper] enableJIT error: %@", error.localizedDescription)
                resultItem.userInfo = [
                    "success": false,
                    "error": error.localizedDescription,
                ]
            }
            context.completeRequest(returningItems: [resultItem], completionHandler: nil)
            #endif
        }
    }
}
