// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation
import XCTest
@testable import DeskFleetLocalFiles

final class RvvmJitRoutingTests: XCTestCase {
    func testPreferredCallbackSchemePrefersForkBundleIdentifierOverUpstream() {
        let scheme = RvvmJitRouting.preferredCallbackScheme(
            registeredSchemes: ["ai.yetanother.deskfleet", "moe.remon.deskfleet.plus"],
            bundleIdentifier: "moe.remon.deskfleet.plus"
        )
        XCTAssertEqual(scheme, "moe.remon.deskfleet.plus")

        // Re-signed sideloaded builds may rewrite bundleIdentifier to include a Team ID suffix,
        // while keeping DeskFleet Plus's URL scheme in Info.plist.
        let resigned = RvvmJitRouting.preferredCallbackScheme(
            registeredSchemes: ["ai.yetanother.deskfleet", "moe.remon.deskfleet.plus"],
            bundleIdentifier: "moe.remon.deskfleet.plus.TEAM123"
        )
        XCTAssertEqual(resigned, "moe.remon.deskfleet.plus")

        // Fallback when no URL types are registered.
        let fallback = RvvmJitRouting.preferredCallbackScheme(
            registeredSchemes: [],
            bundleIdentifier: nil
        )
        XCTAssertEqual(fallback, RvvmJitRouting.defaultCallbackScheme)
    }

    func testLocalDevVpnEnableURLIncludesCallbackScheme() {
        let url = RvvmJitRouting.localDevVpnEnableURL(callbackScheme: "moe.remon.deskfleet.plus")
        XCTAssertEqual(url.absoluteString, "localdevvpn://enable?scheme=moe.remon.deskfleet.plus")

        let noCallback = RvvmJitRouting.localDevVpnEnableURL(callbackScheme: "  ")
        XCTAssertEqual(noCallback.absoluteString, "localdevvpn://enable")
    }

    func testDeveloperModeSettingsURLsProvideOrderedFallbackChain() {
        let urls = RvvmJitRouting.developerModeSettingsURLs(fallbackSettingsURL: "app-settings:")
        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "App-Prefs:Privacy&path=DEVELOPER_MODE",
                "App-Prefs:root=Privacy&path=DEVELOPER_MODE",
                "App-Prefs:Privacy",
                "app-settings:",
            ]
        )

        let deduplicated = RvvmJitRouting.developerModeSettingsURLs(fallbackSettingsURL: "App-Prefs:Privacy")
        XCTAssertEqual(
            deduplicated.map(\.absoluteString),
            [
                "App-Prefs:Privacy&path=DEVELOPER_MODE",
                "App-Prefs:root=Privacy&path=DEVELOPER_MODE",
                "App-Prefs:Privacy",
            ]
        )
    }

    func testShouldAutoActivateJitRequiresPairingVpnIdleAndSingleAttempt() {
        XCTAssertTrue(RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: true,
            vpnReachable: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoActivation: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: false,
            vpnReachable: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoActivation: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: true,
            vpnReachable: false,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoActivation: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: true,
            vpnReachable: true,
            isBusy: true,
            isPairing: false,
            hasAttemptedAutoActivation: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: true,
            vpnReachable: true,
            isBusy: false,
            isPairing: true,
            hasAttemptedAutoActivation: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoActivateJit(
            hasPairingFile: true,
            vpnReachable: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoActivation: true
        ))
    }

    func testShouldAutoLaunchLocalDevVpnPreventsLoopsAndRespectsAvailability() {
        XCTAssertTrue(RvvmJitRouting.shouldAutoLaunchLocalDevVpn(
            autoTriggerRequested: true,
            hasPairingFile: true,
            vpnReachable: false,
            canOpenLocalDevVpn: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoLaunch: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoLaunchLocalDevVpn(
            autoTriggerRequested: false,
            hasPairingFile: true,
            vpnReachable: false,
            canOpenLocalDevVpn: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoLaunch: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoLaunchLocalDevVpn(
            autoTriggerRequested: true,
            hasPairingFile: true,
            vpnReachable: true,
            canOpenLocalDevVpn: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoLaunch: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoLaunchLocalDevVpn(
            autoTriggerRequested: true,
            hasPairingFile: true,
            vpnReachable: false,
            canOpenLocalDevVpn: false,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoLaunch: false
        ))
        XCTAssertFalse(RvvmJitRouting.shouldAutoLaunchLocalDevVpn(
            autoTriggerRequested: true,
            hasPairingFile: true,
            vpnReachable: false,
            canOpenLocalDevVpn: true,
            isBusy: false,
            isPairing: false,
            hasAttemptedAutoLaunch: true
        ))
    }
}
