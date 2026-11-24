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
        XCTAssertTrue(cloudInit.contains("KillMode=process"))
        XCTAssertTrue(cloudInit.contains("clocal -hupcl"))
    }

    func testEnsureDaemonRunningCommandClosesExecChannelAndCreatesDiscoveryDir() {
        let cmd = RvvmDaemonCommands.ensureDaemonRunningCommand()
        XCTAssertTrue(cmd.contains("/root/.deskfleet"))
        XCTAssertTrue(cmd.contains("export HOME=/root"))
        XCTAssertTrue(cmd.contains("export PATH='/root/.local/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'"))
        XCTAssertTrue(cmd.contains("3>&-"))
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonPidFile))
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonLogFile))
        XCTAssertTrue(cmd.contains("/run/systemd/system/deskfleet-daemon.service"))
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonEnvFile))
        XCTAssertTrue(cmd.contains("Restart=always"))
        XCTAssertTrue(cmd.contains("deskfleet-exec-agent.service.d/killmode.conf"))
        XCTAssertTrue(cmd.contains("KillMode=process"))
    }

    func testProvisionScriptSkipsRedownloadOnDevVersionWhileKeepingAssetUrl() {
        let script = RvvmDaemonCommands.provisionDaemonCommand(
            releaseUrl: "https://example.invalid/deskfleet-linux-riscv64.tar.gz",
            versionName: "1.0"
        )
        XCTAssertTrue(script.contains("deskfleet-linux-riscv64.tar.gz"))
        XCTAssertTrue(script.contains("need_download=0"))
        XCTAssertFalse(script.contains("--jitless"))
        XCTAssertTrue(script.contains(RvvmDaemonCommands.nodeRuntimeFlags))
        XCTAssertTrue(script.contains("cmp -s"))
        XCTAssertTrue(script.contains("\nDESKFLEET_WRAPPER_EOF\n"))
    }

    func testDaemonProbeCommandAndOutputParsing() {
        let cmd = RvvmDaemonCommands.daemonProbeCommand(logOffset: 128)
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.daemonDiscoveryPath))
        XCTAssertTrue(cmd.contains("systemctl is-active --quiet 'deskfleet-daemon.service'"))
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

    func testConfigureGuestNetworkAndClockCommandWritesUniqueDnsAndWaitsForRoute() {
        let cmd = RvvmDaemonCommands.configureGuestNetworkAndClockCommand(
            unixSeconds: 1_763_700_000,
            dnsServers: ["198.18.0.2", "1.1.1.1", "198.18.0.2", "bad-ip", "10.0.0.1"]
        )
        XCTAssertTrue(cmd.contains("date -u -s '@1763700000'"))
        XCTAssertTrue(cmd.contains("nameserver 198.18.0.2\nnameserver 1.1.1.1\nnameserver 10.0.0.1\nnameserver 8.8.8.8"))
        XCTAssertTrue(cmd.contains("mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc"))
        XCTAssertTrue(cmd.contains(RvvmDaemonCommands.box64BinfmtRegistration))
        XCTAssertFalse(cmd.contains(":POC"))
        XCTAssertTrue(cmd.contains("mkdir -p /run/systemd/system/deskfleet-exec-agent.service.d"))
        XCTAssertTrue(cmd.contains("deskfleet-exec-agent.service.d/killmode.conf"))
        XCTAssertTrue(cmd.contains("KillMode=process"))
        XCTAssertTrue(cmd.contains("/etc/box64.box64rc"))
        XCTAssertTrue(cmd.contains("BOX64_ENV=GODEBUG=asyncpreemptoff=1"))
        let envRange = RvvmDaemonCommands.box64RcContent.range(of: "BOX64_ENV=GODEBUG=asyncpreemptoff=1")
        let agyRange = RvvmDaemonCommands.box64RcContent.range(of: "[agy]")
        XCTAssertNotNil(envRange)
        XCTAssertNotNil(agyRange)
        if let envRange, let agyRange {
            XCTAssertLessThan(envRange.lowerBound, agyRange.lowerBound)
        }
        XCTAssertTrue(cmd.contains("ip -4 route show default"))
        XCTAssertTrue(cmd.contains("networkctl reconfigure enp0s1"))
    }

    func testRecommendedMemoryAndJitCacheScaleWithPhysicalMemory() {
        let giB: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(RvvmDaemonCommands.recommendedMemoryBytes(physicalMemoryBytes: 4 * giB), 512 * 1024 * 1024)
        XCTAssertEqual(RvvmDaemonCommands.recommendedJitCacheBytes(physicalMemoryBytes: 4 * giB), 32 * 1024 * 1024)
        XCTAssertEqual(RvvmDaemonCommands.recommendedMemoryBytes(physicalMemoryBytes: 8 * giB), 1024 * 1024 * 1024)
        XCTAssertEqual(RvvmDaemonCommands.recommendedJitCacheBytes(physicalMemoryBytes: 8 * giB), 48 * 1024 * 1024)
        XCTAssertEqual(RvvmDaemonCommands.recommendedMemoryBytes(physicalMemoryBytes: 12 * giB), 1536 * 1024 * 1024)
        XCTAssertEqual(RvvmDaemonCommands.recommendedJitCacheBytes(physicalMemoryBytes: 12 * giB), 64 * 1024 * 1024)
    }

    func testEnsureDaemonRunningCommandConfiguresIpv4FirstAndOptionalProxy() {
        let plain = RvvmDaemonCommands.ensureDaemonRunningCommand()
        XCTAssertTrue(plain.contains("export GODEBUG='asyncpreemptoff=1'"))
        XCTAssertTrue(plain.contains("NODE_OPTIONS='--dns-result-order=ipv4first'"))
        XCTAssertFalse(plain.contains("--jitless"))
        XCTAssertFalse(plain.contains("--no-sparkplug"))
        XCTAssertFalse(plain.contains("NODE_USE_ENV_PROXY=1"))

        let proxied = RvvmDaemonCommands.ensureDaemonRunningCommand(
            proxy: RvvmDaemonCommands.ProxyConfig(
                httpProxy: "http://192.168.1.2:7890",
                httpsProxy: "http://192.168.1.2:7890"
            )
        )
        XCTAssertTrue(proxied.contains("NODE_OPTIONS='--dns-result-order=ipv4first --use-env-proxy'"))
        XCTAssertFalse(proxied.contains("--jitless"))
        XCTAssertFalse(proxied.contains("--no-sparkplug"))
        XCTAssertTrue(proxied.contains("export NODE_USE_ENV_PROXY=1"))
        XCTAssertTrue(proxied.contains("export HTTP_PROXY='http://192.168.1.2:7890'"))
        XCTAssertTrue(proxied.contains("export HTTPS_PROXY='http://192.168.1.2:7890'"))
        XCTAssertTrue(proxied.contains("export NO_PROXY='localhost,127.0.0.1,::1'"))
    }

    func testNetworkDiagnosticCommandAndProbeErrorExtraction() {
        let diag = RvvmDaemonCommands.networkDiagnosticCommand(
            serverUrl: "https://deskfleet.yetanother.ai/",
            proxy: RvvmDaemonCommands.ProxyConfig(
                httpProxy: "http://192.168.1.2:7890",
                httpsProxy: nil
            )
        )
        XCTAssertTrue(diag.contains("https://deskfleet.yetanother.ai/api/site"))
        XCTAssertTrue(diag.contains(RvvmDaemonCommands.nodeRuntimeFlags))
        XCTAssertFalse(diag.contains("--jitless"))
        XCTAssertTrue(diag.contains("export NODE_USE_ENV_PROXY=1"))
        XCTAssertTrue(diag.contains("/etc/resolv.conf"))

        XCTAssertNil(RvvmDaemonCommands.extractProbeError(from: "PROBE_HTTP 200\n"))
        XCTAssertEqual(
            RvvmDaemonCommands.extractProbeError(from: "ip addr\nPROBE_ERR fetch failed ENOTFOUND getaddrinfo getaddrinfo ENOTFOUND deskfleet.yetanother.ai\n"),
            "fetch failed ENOTFOUND getaddrinfo getaddrinfo ENOTFOUND deskfleet.yetanother.ai"
        )
    }

    func testSettingsCommandQuotesArgumentsAndSetsHome() {
        XCTAssertEqual(
            RvvmDaemonCommands.settingsCommand(args: ["get"]),
            "if [ -x '/opt/deskfleet/deskfleet-daemon' ]; then HOME=/root '/opt/deskfleet/deskfleet-daemon' settings 'get'; else exit 127; fi"
        )
        XCTAssertEqual(
            RvvmDaemonCommands.settingsCommand(args: ["set", "remoteAgents.allowRead", "true"]),
            "if [ -x '/opt/deskfleet/deskfleet-daemon' ]; then HOME=/root '/opt/deskfleet/deskfleet-daemon' settings 'set' 'remoteAgents.allowRead' 'true'; else exit 127; fi"
        )
        XCTAssertEqual(
            RvvmDaemonCommands.settingsCommand(args: ["set", "worktrees.root", "/tmp/a'b"]),
            "if [ -x '/opt/deskfleet/deskfleet-daemon' ]; then HOME=/root '/opt/deskfleet/deskfleet-daemon' settings 'set' 'worktrees.root' '/tmp/a'\"'\"'b'; else exit 127; fi"
        )
    }
}
