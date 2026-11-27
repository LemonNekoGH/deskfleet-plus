import Foundation
import XCTest
@testable import DeskFleetLocalFiles

final class RvvmLocalDaemonLifecycleTests: XCTestCase {
    private func makeDefaults(_ suffix: String) -> UserDefaults {
        let suite = "moe.remon.deskfleet.plus.tests.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsToEnabledWhenExistingSetupPresentAndDisabledOtherwise() {
        let fresh = RvvmLocalDaemonLifecycle(
            defaults: makeDefaults("fresh"),
            hasExistingSetup: { false }
        )
        XCTAssertFalse(fresh.isEnabled)
        XCTAssertEqual(fresh.snapshot().status, .stopped)

        let existing = RvvmLocalDaemonLifecycle(
            defaults: makeDefaults("existing"),
            hasExistingSetup: { true }
        )
        XCTAssertTrue(existing.isEnabled)
        XCTAssertEqual(existing.snapshot().status, .stopped)
    }

    func testExplicitPreferenceOverridesExistingSetupAndEmitsChanges() {
        let defaults = makeDefaults("override")
        var events: [[String: Any]] = []
        let lifecycle = RvvmLocalDaemonLifecycle(
            defaults: defaults,
            hasExistingSetup: { true },
            onChanged: { events.append($0) }
        )

        let disabled = lifecycle.setEnabledPreference(false)
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(lifecycle.isEnabled)

        let errored = lifecycle.transition(to: .error, error: "LocalDevVPN is off")
        XCTAssertEqual(errored.status, .error)
        XCTAssertEqual(errored.error, "LocalDevVPN is off")

        let running = lifecycle.transition(to: .running)
        XCTAssertEqual(running.status, .running)
        XCTAssertNil(running.error)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[1]["error"] as? String, "LocalDevVPN is off")
        XCTAssertNil(events[2]["error"])
    }

    func testLogBufferPreservesRecentOutputAndTruncatesCleanlyOnUtf8Boundary() {
        let lifecycle = RvvmLocalDaemonLifecycle(defaults: makeDefaults("logs"))
        lifecycle.appendLog("==> Starting\n")
        let repeated = String(repeating: "日志", count: 8000) // ~48 KiB UTF-8
        lifecycle.appendLog(repeated)

        let logs = lifecycle.recentLogs()
        XCTAssertLessThanOrEqual(logs.utf8.count, RvvmLocalDaemonLifecycle.maxLogBytes)
        XCTAssertTrue(logs.hasSuffix("日志"))

        lifecycle.resetLogBuffer()
        XCTAssertEqual(lifecycle.recentLogs(), "")
    }
}
