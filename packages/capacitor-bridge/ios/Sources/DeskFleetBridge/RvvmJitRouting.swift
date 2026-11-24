// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation

/// Pure-Foundation URL routing and auto-activation predicates for the iOS Pure-JIT setup flow.
internal enum RvvmJitRouting {
    static let defaultCallbackScheme = "moe.remon.deskfleet.plus"
    static let localDevVpnHost = "10.7.0.1"
    static let localDevVpnPort: UInt16 = 62078
    static let localDevVpnScheme = "localdevvpn"

    /// Resolves the preferred callback URL scheme from registered `CFBundleURLSchemes`,
    /// preferring the current bundle identifier / DeskFleet Plus scheme over the upstream
    /// scheme so `localdevvpn://enable?scheme=...` callbacks always return to DeskFleet Plus.
    static func preferredCallbackScheme(registeredSchemes: [String], bundleIdentifier: String?) -> String {
        let normalized = registeredSchemes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleId.isEmpty,
           let exact = normalized.first(where: { $0.caseInsensitiveCompare(bundleId) == .orderedSame }) {
            return exact
        }
        if let forkDefault = normalized.first(where: { $0.caseInsensitiveCompare(defaultCallbackScheme) == .orderedSame }) {
            return forkDefault
        }
        return normalized.first ?? defaultCallbackScheme
    }

    static func bundleCallbackScheme(bundle: Bundle = .main) -> String {
        let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        return preferredCallbackScheme(registeredSchemes: schemes, bundleIdentifier: bundle.bundleIdentifier)
    }

    /// Builds `localdevvpn://enable?scheme=<callbackScheme>` (compatible with both LocalDevVPN
    /// and CalicoMeow's unified tunnel handler).
    static func localDevVpnEnableURL(callbackScheme: String = defaultCallbackScheme) -> URL {
        var components = URLComponents()
        components.scheme = localDevVpnScheme
        components.host = "enable"
        let trimmed = callbackScheme.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            components.queryItems = [URLQueryItem(name: "scheme", value: trimmed)]
        }
        return components.url!
    }

    /// Best-effort ordered Settings URLs targeting Privacy & Security -> Developer Mode
    /// (where iOS 27+ wireless RemotePairing lives), falling back to Privacy & Security
    /// and finally the public app-settings URL.
    static func developerModeSettingsURLs(fallbackSettingsURL: String) -> [URL] {
        let rawCandidates = [
            "App-Prefs:Privacy&path=DEVELOPER_MODE",
            "App-Prefs:root=Privacy&path=DEVELOPER_MODE",
            "App-Prefs:Privacy",
            fallbackSettingsURL,
        ]
        var seen = Set<String>()
        var urls: [URL] = []
        for raw in rawCandidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted, let url = URL(string: trimmed) else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    /// Returns true when the JIT setup sheet should automatically trigger JIT activation
    /// without requiring another user tap.
    static func shouldAutoActivateJit(
        hasPairingFile: Bool,
        vpnReachable: Bool,
        isBusy: Bool,
        isPairing: Bool,
        hasAttemptedAutoActivation: Bool
    ) -> Bool {
        hasPairingFile && vpnReachable && !isBusy && !isPairing && !hasAttemptedAutoActivation
    }

    /// Returns true when the JIT setup sheet should automatically hand off to
    /// `localdevvpn://enable?scheme=...` once to bring up the loopback interface.
    static func shouldAutoLaunchLocalDevVpn(
        autoTriggerRequested: Bool,
        hasPairingFile: Bool,
        vpnReachable: Bool,
        canOpenLocalDevVpn: Bool,
        isBusy: Bool,
        isPairing: Bool,
        hasAttemptedAutoLaunch: Bool
    ) -> Bool {
        autoTriggerRequested
            && hasPairingFile
            && !vpnReachable
            && canOpenLocalDevVpn
            && !isBusy
            && !isPairing
            && !hasAttemptedAutoLaunch
    }
}
