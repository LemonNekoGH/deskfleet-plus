// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation
import XCTest
@testable import DeskFleetLocalFiles

final class RvvmDaemonCommandsTests: XCTestCase {
    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(RvvmDaemonCommands.shellQuote("simple"), "'simple'")
        XCTAssertEqual(RvvmDaemonCommands.shellQuote("a'b"), "'a'\"'\"'b'")
    }

    func testCredentialsJsonRoundTrips() throws {
        let json = try RvvmDaemonCommands.credentialsJson(
            machineId: "m-1",
            teamId: "t-2",
            token: "sec-tok",
            originId: "orig-3"
        )
        let parsed = try RvvmDaemonCommands.extractJsonObject(from: json)
        XCTAssertEqual(parsed["machineId"] as? String, "m-1")
        XCTAssertEqual(parsed["teamId"] as? String, "t-2")
        XCTAssertEqual(parsed["token"] as? String, "sec-tok")
        XCTAssertEqual(parsed["originId"] as? String, "orig-3")
    }

    func testEnrollCommandUsesBase64StdinPipe() {
        let cmd = RvvmDaemonCommands.enrollCommand(
            serverUrl: "https://fleet.example",
            credentialsJson: #"{"token":"super-secret"}"#
        )
        XCTAssertFalse(cmd.contains("super-secret"))
        XCTAssertTrue(cmd.contains("base64 -d"))
        XCTAssertTrue(cmd.contains("'/opt/deskfleet/deskfleet-daemon' enroll --server-url 'https://fleet.example'"))
    }

    func testPrepareEnrollmentCommandFormatsFlags() {
        let cmd = RvvmDaemonCommands.prepareEnrollmentCommand(
            serverUrl: "https://fleet.example",
            teamId: "team-42"
        )
        XCTAssertEqual(
            cmd,
            "'/opt/deskfleet/deskfleet-daemon' prepare-enrollment --server-url 'https://fleet.example' --team-id 'team-42'"
        )
    }

    func testFramedExecRequestAndResponseHeaderParsing() {
        let frame = RvvmDaemonCommands.formatExecRequest(id: 7, command: "echo hi")
        XCTAssertEqual(String(data: frame, encoding: .utf8), "7 7\necho hi")

        let header = RvvmDaemonCommands.parseExecResponseHeader("7 0 128\r\n")
        XCTAssertEqual(header?.id, 7)
        XCTAssertEqual(header?.exitCode, 0)
        XCTAssertEqual(header?.byteLength, 128)

        XCTAssertNil(RvvmDaemonCommands.parseExecResponseHeader("bad header"))
        XCTAssertNil(RvvmDaemonCommands.parseExecResponseHeader("7 0 -1"))
    }

    func testExtractJsonObjectIgnoresLeadingLogs() throws {
        let noisy = """
        [boot] starting daemon check
        {"machineName":"iPhone","registrations":[]}
        """
        let parsed = try RvvmDaemonCommands.extractJsonObject(from: noisy)
        XCTAssertEqual(parsed["machineName"] as? String, "iPhone")
    }

    func testProvisionScriptTargetsRiscv64Asset() {
        XCTAssertEqual(RvvmDaemonCommands.daemonReleaseAsset, "deskfleet-linux-riscv64.tar.gz")
        let script = RvvmDaemonCommands.provisionDaemonCommand(
            releaseUrl: "https://example.invalid/deskfleet-linux-riscv64.tar.gz",
            versionName: "1.2.3"
        )
        XCTAssertTrue(script.contains("deskfleet-linux-riscv64.tar.gz"))
        XCTAssertTrue(script.contains("/opt/deskfleet/deskfleet-daemon"))
    }

    func testGuestBootAndCloudInitHelpers() {
        let cmdline = RvvmDaemonCommands.guestBootCmdline()
        XCTAssertTrue(cmdline.contains("console=ttyS0,115200"))
        XCTAssertTrue(cmdline.contains("root=/dev/nvme0n1p1"))

        let cloudInit = RvvmDaemonCommands.guestExecAgentCloudInit()
        XCTAssertTrue(cloudInit.hasPrefix("#cloud-config"))
        XCTAssertTrue(cloudInit.contains("/dev/ttyS1"))
        XCTAssertTrue(cloudInit.contains("deskfleet-exec-agent.service"))
    }

    func testEnsureDaemonRunningCommandClosesExecChannelAndCreatesDiscoveryDir() {
        let cmd = RvvmDaemonCommands.ensureDaemonRunningCommand()
        XCTAssertTrue(cmd.contains("/root/.deskfleet"))
        XCTAssertTrue(cmd.contains("export HOME=/root"))
        XCTAssertTrue(cmd.contains("3>&-"))
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonPidFile))
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonLogFile))
    }

    func testProvisionScriptSkipsRedownloadOnDevVersionWhileKeepingAssetUrl() {
        let script = RvvmDaemonCommands.provisionDaemonCommand(
            releaseUrl: "https://example.invalid/deskfleet-linux-riscv64.tar.gz",
            versionName: "1.0"
        )
        XCTAssertTrue(script.contains("deskfleet-linux-riscv64.tar.gz"))
        XCTAssertTrue(script.contains("exit 0"))
    }

    func testDaemonProbeCommandAndOutputParsing() {
        let cmd = RvvmDaemonCommands.daemonProbeCommand(logOffset: 128)
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonDiscoveryPath))
        XCTAssertTrue(cmd.contains("tail -c +$((128 + 1))"))

        let waiting = RvvmDaemonCommands.parseDaemonProbeOutput("STATE alive waiting 64\nbooting...\n")
        XCTAssertEqual(waiting?.alive, true)
        XCTAssertEqual(waiting?.discoveryReady, false)
        XCTAssertEqual(waiting?.nextOffset, 64)
        XCTAssertEqual(waiting?.logChunk, "booting...\n")

        let ready = RvvmDaemonCommands.parseDaemonProbeOutput("STATE alive ready 128\n{\"event\":\"ready\"}\nnext\n")
        XCTAssertEqual(ready?.alive, true)
        XCTAssertEqual(ready?.discoveryReady, true)
        XCTAssertEqual(ready?.nextOffset, 128)
        XCTAssertEqual(ready?.logChunk, "{\"event\":\"ready\"}\nnext\n")

        let dead = RvvmDaemonCommands.parseDaemonProbeOutput("STATE dead waiting 0\n")
        XCTAssertEqual(dead?.alive, false)
        XCTAssertEqual(dead?.discoveryReady, false)
        XCTAssertEqual(dead?.nextOffset, 0)
        XCTAssertEqual(dead?.logChunk, "")

        XCTAssertNil(RvvmDaemonCommands.parseDaemonProbeOutput("garbage output"))
    }

    func testFormatByteCountFormatsUnitsConsistently() {
        XCTAssertEqual(RvvmDaemonCommands.formatByteCount(512), "512 B")
        XCTAssertEqual(RvvmDaemonCommands.formatByteCount(1536), "1.5 KiB")
        XCTAssertEqual(RvvmDaemonCommands.formatByteCount(342 * 1024 * 1024), "342.0 MiB")
    }
}
