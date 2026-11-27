// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation

/// Pure-Foundation state machine and preference store for the iOS embedded RVVM
/// local daemon, mirroring Electron's `LocalAgentController` (`LocalAgentState`).
internal final class RvvmLocalDaemonLifecycle {
    enum Status: String {
        case stopped
        case starting
        case running
        case stopping
        case error
    }

    struct Snapshot: Equatable {
        let enabled: Bool
        let status: Status
        let error: String?

        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "enabled": enabled,
                "status": status.rawValue,
            ]
            if let error, !error.isEmpty {
                dict["error"] = error
            }
            return dict
        }
    }

    static let defaultPreferenceKey = "moe.remon.deskfleet.plus.localDaemonEnabled"
    static let maxLogBytes = 32 * 1024

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let preferenceKey: String
    private let hasExistingSetup: () -> Bool
    private let onChanged: ([String: Any]) -> Void

    private var status: Status = .stopped
    private var errorMessage: String?
    private var logBuffer = ""

    init(
        defaults: UserDefaults = .standard,
        preferenceKey: String = RvvmLocalDaemonLifecycle.defaultPreferenceKey,
        hasExistingSetup: @escaping () -> Bool = { false },
        onChanged: @escaping ([String: Any]) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.hasExistingSetup = hasExistingSetup
        self.onChanged = onChanged
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readEnabledLocked()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(enabled: readEnabledLocked(), status: status, error: errorMessage)
    }

    func setEnabledPreference(_ enabled: Bool) -> Snapshot {
        lock.lock()
        defaults.set(enabled, forKey: preferenceKey)
        let snap = Snapshot(enabled: enabled, status: status, error: errorMessage)
        lock.unlock()
        onChanged(snap.toDictionary())
        return snap
    }

    func transition(to nextStatus: Status, error: String? = nil) -> Snapshot {
        lock.lock()
        status = nextStatus
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = error
        } else {
            errorMessage = nil
        }
        let snap = Snapshot(enabled: readEnabledLocked(), status: status, error: errorMessage)
        lock.unlock()
        onChanged(snap.toDictionary())
        return snap
    }

    func resetLogBuffer() {
        lock.lock()
        logBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func appendLog(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        logBuffer.append(chunk)
        if logBuffer.utf8.count > Self.maxLogBytes {
            let overflow = logBuffer.utf8.count - Self.maxLogBytes
            var dropIndex = logBuffer.utf8.index(
                logBuffer.utf8.startIndex,
                offsetBy: min(overflow, logBuffer.utf8.count)
            )
            while dropIndex < logBuffer.endIndex && dropIndex.samePosition(in: logBuffer) == nil {
                dropIndex = logBuffer.utf8.index(after: dropIndex)
            }
            if let scalarIndex = dropIndex.samePosition(in: logBuffer) {
                logBuffer = String(logBuffer[scalarIndex...])
            } else {
                logBuffer.removeAll(keepingCapacity: true)
            }
        }
        lock.unlock()
    }

    func recentLogs() -> String {
        lock.lock()
        defer { lock.unlock() }
        return logBuffer
    }

    private func readEnabledLocked() -> Bool {
        if defaults.object(forKey: preferenceKey) != nil {
            return defaults.bool(forKey: preferenceKey)
        }
        return hasExistingSetup()
    }
}
