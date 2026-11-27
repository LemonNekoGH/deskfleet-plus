// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation

/// Pure Foundation command builders and framed UART-exec helpers for the embedded
/// riscv64 Linux guest running under librvvm.
internal enum RvvmDaemonCommands {
    struct ProxyConfig: Equatable {
        let httpProxy: String?
        let httpsProxy: String?

        var hasAny: Bool {
            (httpProxy?.isEmpty == false) || (httpsProxy?.isEmpty == false)
        }
    }

    struct ScreenBridgeConfig: Equatable {
        let host: String
        let port: UInt16
        let token: String
    }

    static let daemonBinaryPath = "/opt/deskfleet/deskfleet-daemon"
    static let daemonPidFile = "/run/deskfleet-daemon.pid"
    static let daemonEnvFile = "/run/deskfleet-daemon.env"
    static let daemonServiceName = "deskfleet-daemon.service"
    static let daemonLogFile = "/var/log/deskfleet-daemon.log"
    static let daemonDiscoveryPath = "/root/.deskfleet/daemon.json"
    static let daemonReleaseAsset = "deskfleet-linux-riscv64.tar.gz"
    static let guestDiskArchiveAsset = "deskfleet-riscv64.img.gz"
    static let box64BinfmtRegistration = ":box64:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\x00\\x00\\x00\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/usr/local/bin/box64:"
    // Box64 calls GatherEnv() before per-binary ApplyEnvFileEntry(), so BOX64_ENV must live in [*].
    static let box64RcContent = [
        "[*]",
        "BOX64_NOBANNER=1",
        "BOX64_DYNAREC_NOHOSTEXT=zicond,zbc,zicbop",
        "BOX64_ENV=GODEBUG=asyncpreemptoff=1",
        "",
        "[agy]",
        "BOX64_DYNAREC_CALLRET=0",
        "BOX64_DYNACACHE=1",
    ].joined(separator: "\n")

    static func recommendedMemoryBytes(physicalMemoryBytes: UInt64) -> Int {
        let giB: UInt64 = 1024 * 1024 * 1024
        if physicalMemoryBytes >= 10 * giB {
            return 1536 * 1024 * 1024
        }
        if physicalMemoryBytes >= 7 * giB {
            return 1024 * 1024 * 1024
        }
        return 512 * 1024 * 1024
    }

    static func recommendedJitCacheBytes(physicalMemoryBytes: UInt64) -> Int {
        let giB: UInt64 = 1024 * 1024 * 1024
        if physicalMemoryBytes >= 10 * giB {
            return 64 * 1024 * 1024
        }
        if physicalMemoryBytes >= 7 * giB {
            return 48 * 1024 * 1024
        }
        return 32 * 1024 * 1024
    }

    /// Disables V8 Sparkplug/Maglev/TurboFan/Wasm tier-up (which segfault under RVVM on riscv64)
    /// while keeping `WebAssembly` enabled so Node 24's undici `fetch`/`WebSocket` llhttp WASM works.
    static let nodeRuntimeFlags = "--no-sparkplug --no-maglev --no-opt --no-regexp-tier-up --liftoff-only --no-wasm-tier-up"

    static func daemonWrapperScript() -> String {
        [
            "#!/bin/sh",
            #"DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)""#,
            #"exec "$DIR/node" \#(nodeRuntimeFlags) "$DIR/daemon.cjs" "$@""#,
            "",
        ].joined(separator: "\n")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func isValidIpv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && UInt8(part) != nil
        }
    }

    static func credentialsJson(
        machineId: String,
        teamId: String,
        token: String,
        originId: String
    ) throws -> String {
        let payload: [String: String] = [
            "machineId": machineId,
            "teamId": teamId,
            "token": token,
            "originId": originId,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "RvvmDaemonCommands",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode daemon credentials JSON"]
            )
        }
        return text
    }

    static func statusCommand() -> String {
        "if [ -x \(shellQuote(daemonBinaryPath)) ]; then \(shellQuote(daemonBinaryPath)) status; else exit 127; fi"
    }

    static func prepareEnrollmentCommand(serverUrl: String, teamId: String) -> String {
        "\(shellQuote(daemonBinaryPath)) prepare-enrollment --server-url \(shellQuote(serverUrl)) --team-id \(shellQuote(teamId))"
    }

    /// Pipes credentials JSON via base64 into stdin so tokens never appear in argv/ps.
    static func enrollCommand(serverUrl: String, credentialsJson: String) -> String {
        let encoded = Data(credentialsJson.utf8).base64EncodedString()
        return "printf '%s' \(shellQuote(encoded)) | base64 -d | \(shellQuote(daemonBinaryPath)) enroll --server-url \(shellQuote(serverUrl))"
    }

    static func settingsCommand(args: [String]) -> String {
        let quotedArgs = args.map(shellQuote).joined(separator: " ")
        let suffix = quotedArgs.isEmpty ? "" : " \(quotedArgs)"
        return "if [ -x \(shellQuote(daemonBinaryPath)) ]; then HOME=/root \(shellQuote(daemonBinaryPath)) settings\(suffix); else exit 127; fi"
    }

    static func nodeOptions(proxy: ProxyConfig? = nil) -> String {
        proxy?.hasAny == true
            ? "--dns-result-order=ipv4first --use-env-proxy"
            : "--dns-result-order=ipv4first"
    }

    private static func execAgentKillModeDropInLines() -> String {
        [
            "mkdir -p /run/systemd/system/deskfleet-exec-agent.service.d",
            "cat <<'DESKFLEET_KILLMODE_EOF' >/run/systemd/system/deskfleet-exec-agent.service.d/killmode.conf",
            "[Service]",
            "KillMode=process",
            "DESKFLEET_KILLMODE_EOF",
        ].joined(separator: "\n")
    }

    static func configureGuestNetworkAndClockCommand(unixSeconds: Int64, dnsServers: [String]) -> String {
        var resolvedDns: [String] = []
        for candidate in dnsServers + ["1.1.1.1", "8.8.8.8"] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIpv4(trimmed), !resolvedDns.contains(trimmed) else { continue }
            resolvedDns.append(trimmed)
        }
        let resolvLines = resolvedDns.map { "nameserver \($0)" }.joined(separator: "\n")
        let killModeLines = execAgentKillModeDropInLines()
        return """
        date -u -s '@\(unixSeconds)' >/dev/null 2>&1 || true
        cat <<'EOF' >/etc/resolv.conf
        \(resolvLines)
        EOF
        if [ -x /usr/local/bin/box64 ] && [ ! -e /proc/sys/fs/binfmt_misc/box64 ]; then
          mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc >/dev/null 2>&1 || true
          if [ -w /proc/sys/fs/binfmt_misc/register ]; then
            printf '%s\\n' \(shellQuote(box64BinfmtRegistration)) >/proc/sys/fs/binfmt_misc/register 2>/dev/null || true
          fi
        fi
        if [ -x /usr/local/bin/box64 ]; then
          cat <<'DESKFLEET_BOX64RC_EOF' >/etc/box64.box64rc
        \(box64RcContent)
        DESKFLEET_BOX64RC_EOF
          chmod 0644 /etc/box64.box64rc 2>/dev/null || true
        fi
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        \(killModeLines)
          systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        i=1
        while [ "$i" -le 15 ]; do
          if ip -4 route show default 2>/dev/null | grep -q default; then
            break
          fi
          if [ "$i" -eq 5 ]; then
            (command -v networkctl >/dev/null 2>&1 && networkctl reconfigure enp0s1) >/dev/null 2>&1 || ip link set enp0s1 up >/dev/null 2>&1 || true
          fi
          i=$((i + 1))
          sleep 1
        done
        ip_summary=$(ip -4 -o addr show dev enp0s1 2>/dev/null | awk '{print $4}' | tr '\\n' ' ' | sed 's/ *$//' || true)
        gw_summary=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n 1 || true)
        printf 'IP=%s GW=%s\\n' "${ip_summary:-none}" "${gw_summary:-none}"
        """
    }

    static func ensureDaemonRunningCommand(
        proxy: ProxyConfig? = nil,
        screenBridge: ScreenBridgeConfig? = nil
    ) -> String {
        let stripNewlines: (String) -> String = {
            $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
        var envLines = [
            "export HOME=/root",
            "export PATH='/root/.local/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'",
            "export GODEBUG='asyncpreemptoff=1'",
            "export NODE_OPTIONS=\(shellQuote(nodeOptions(proxy: proxy)))",
        ]
        if let screenBridge, screenBridge.port > 0, !screenBridge.host.isEmpty {
            let addr = "\(stripNewlines(screenBridge.host)):\(screenBridge.port)"
            envLines.append("export DESKFLEET_IOS_SCREEN_ADDR=\(shellQuote(addr))")
            envLines.append("export DESKFLEET_IOS_SCREEN_TOKEN=\(shellQuote(stripNewlines(screenBridge.token)))")
        }
        if let proxy, proxy.hasAny {
            envLines.append("export NODE_USE_ENV_PROXY=1")
            if let httpProxy = proxy.httpProxy, !httpProxy.isEmpty {
                envLines.append("export HTTP_PROXY=\(shellQuote(stripNewlines(httpProxy)))")
            }
            if let httpsProxy = proxy.httpsProxy, !httpsProxy.isEmpty {
                envLines.append("export HTTPS_PROXY=\(shellQuote(stripNewlines(httpsProxy)))")
            }
            envLines.append("export NO_PROXY='localhost,127.0.0.1,::1'")
        }
        let envBlock = envLines.joined(separator: "\n")
        let killModeLines = execAgentKillModeDropInLines()
        let qEnv = shellQuote(daemonEnvFile)
        let qService = shellQuote(daemonServiceName)
        let qPid = shellQuote(daemonPidFile)
        let qDiscovery = shellQuote(daemonDiscoveryPath)
        let qDaemon = shellQuote(daemonBinaryPath)
        let qLog = shellQuote(daemonLogFile)
        return """
        mkdir -p /run /var/log /opt/deskfleet /root/.deskfleet
        cat <<'DESKFLEET_ENV_EOF' >\(qEnv)
        \(envBlock)
        DESKFLEET_ENV_EOF
        chmod 0600 \(qEnv)
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        \(killModeLines)
          cat <<'DESKFLEET_SERVICE_EOF' >/run/systemd/system/\(daemonServiceName)
        [Unit]
        Description=DeskFleet Machine Daemon
        After=network.target

        [Service]
        Type=simple
        WorkingDirectory=/root
        ExecStart=/bin/sh -c '. \(daemonEnvFile); echo $$ >\(daemonPidFile); exec \(daemonBinaryPath)'
        StandardOutput=append:\(daemonLogFile)
        StandardError=append:\(daemonLogFile)
        Restart=always
        RestartSec=2

        [Install]
        WantedBy=multi-user.target
        DESKFLEET_SERVICE_EOF
          systemctl daemon-reload >/dev/null 2>&1 || true
          if systemctl is-active --quiet \(qService) || { [ -f \(qPid) ] && kill -0 "$(cat \(qPid) 2>/dev/null)" 2>/dev/null; }; then
            exit 0
          fi
          rm -f \(qDiscovery)
          systemctl start --no-block \(qService)
          exit 0
        fi
        . \(qEnv)
        if [ -f \(qPid) ] && kill -0 "$(cat \(qPid) 2>/dev/null)" 2>/dev/null; then
          exit 0
        fi
        rm -f \(qDiscovery)
        nohup \(qDaemon) </dev/null >>\(qLog) 2>&1 3>&- &
        echo $! >\(qPid)
        """
    }

    static func networkDiagnosticCommand(serverUrl: String, proxy: ProxyConfig? = nil) -> String {
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let probeUrl = "\(base)/api/site"
        let opts = nodeOptions(proxy: proxy)
        var proxyLines: [String] = []
        if let proxy, proxy.hasAny {
            proxyLines.append("export NODE_USE_ENV_PROXY=1")
            if let httpProxy = proxy.httpProxy, !httpProxy.isEmpty {
                proxyLines.append("export HTTP_PROXY=\(shellQuote(httpProxy))")
            }
            if let httpsProxy = proxy.httpsProxy, !httpsProxy.isEmpty {
                proxyLines.append("export HTTPS_PROXY=\(shellQuote(httpsProxy))")
            }
            proxyLines.append("export NO_PROXY='localhost,127.0.0.1,::1'")
        }
        let proxyPrefix = proxyLines.isEmpty ? "" : "\(proxyLines.joined(separator: "\n"))\n"
        let probeScript = "fetch(process.argv[1]).then(r=>console.log('PROBE_HTTP '+r.status)).catch(e=>{const c=e&&e.cause?e.cause:{};console.log(['PROBE_ERR',e&&e.message||String(e),c.code||'',c.syscall||'',c.message||''].join(' '))})"
        return """
        echo '--- date ---'
        date -u 2>&1 || true
        echo '--- ip addr ---'
        ip -4 -o addr show 2>&1 || true
        echo '--- ip route ---'
        ip -4 route show 2>&1 || true
        echo '--- resolv.conf ---'
        cat /etc/resolv.conf 2>/dev/null || true
        echo '--- node fetch probe ---'
        \(proxyPrefix)timeout 12 /opt/deskfleet/node \(nodeRuntimeFlags) \(opts) -e \(shellQuote(probeScript)) \(shellQuote(probeUrl)) 2>&1 || true
        echo '--- daemon log tail ---'
        tail -n 20 \(shellQuote(daemonLogFile)) 2>/dev/null || true
        """
    }

    static func extractProbeError(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("PROBE_ERR ") {
                let detail = String(trimmed.dropFirst("PROBE_ERR ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? nil : detail
            }
        }
        return nil
    }

    static func daemonLogSizeCommand() -> String {
        let qLog = shellQuote(daemonLogFile)
        return "if [ -f \(qLog) ]; then wc -c <\(qLog) | tr -d ' '; else echo 0; fi"
    }

    static func daemonProbeCommand(logOffset: UInt64) -> String {
        let qPid = shellQuote(daemonPidFile)
        let qService = shellQuote(daemonServiceName)
        let qDiscovery = shellQuote(daemonDiscoveryPath)
        let qLog = shellQuote(daemonLogFile)
        return """
        alive=dead
        if [ -f \(qPid) ]; then
          pid=$(cat \(qPid) 2>/dev/null || true)
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            alive=alive
          fi
        fi
        if [ "$alive" = "dead" ] && command -v systemctl >/dev/null 2>&1; then
          svc_state=$(systemctl is-active \(qService) 2>/dev/null || true)
          if [ "$svc_state" = "active" ] || [ "$svc_state" = "activating" ] || [ "$svc_state" = "reloading" ]; then
            alive=alive
          fi
        fi
        ready=waiting
        if [ -s \(qDiscovery) ]; then
          ready=ready
        fi
        size=0
        if [ -f \(qLog) ]; then
          size=$(wc -c <\(qLog) 2>/dev/null | tr -d ' ' || echo 0)
          case "$size" in ''|*[!0-9]*) size=0 ;; esac
        fi
        printf 'STATE %s %s %s\\n' "$alive" "$ready" "$size"
        if [ "$size" -gt \(logOffset) ] 2>/dev/null && [ -f \(qLog) ]; then
          tail -c +$((\(logOffset) + 1)) \(qLog) 2>/dev/null || true
        fi
        """
    }

    static func parseDaemonProbeOutput(
        _ output: String
    ) -> (alive: Bool, discoveryReady: Bool, nextOffset: UInt64, logChunk: String)? {
        let firstLine: String
        let rest: String
        if let newlineIdx = output.firstIndex(of: "\n") {
            firstLine = String(output[..<newlineIdx])
            rest = String(output[output.index(after: newlineIdx)...])
        } else {
            firstLine = output
            rest = ""
        }
        let parts = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 4,
              parts[0] == "STATE",
              parts[1] == "alive" || parts[1] == "dead",
              parts[2] == "ready" || parts[2] == "waiting",
              let nextOffset = UInt64(parts[3]) else {
            return nil
        }
        return (
            alive: parts[1] == "alive",
            discoveryReady: parts[2] == "ready",
            nextOffset: nextOffset,
            logChunk: rest
        )
    }

    static func daemonLogTailCommand(lines: Int = 40) -> String {
        "tail -n \(max(lines, 1)) \(shellQuote(daemonLogFile)) 2>/dev/null || true"
    }

    static func formatByteCount(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kib = Double(bytes) / 1024.0
        if kib < 1024.0 {
            return String(format: "%.1f KiB", kib)
        }
        return String(format: "%.1f MiB", kib / 1024.0)
    }

    /// Ensures /opt/deskfleet/deskfleet-daemon (riscv64) exists inside the Linux guest and
    /// keeps the launcher wrapper in sync on cached guest disk images.
    static func provisionDaemonCommand(releaseUrl: String, versionName: String) -> String {
        let versionFile = "/opt/deskfleet/.version"
        let skipVersionMismatch = versionName == "1.0" || versionName == "0.0.0"
        let versionCheckLines: [String] = skipVersionMismatch
            ? ["  need_download=0"]
            : [
                "  if [ ! -f \(shellQuote(versionFile)) ] || [ \"$(cat \(shellQuote(versionFile)))\" = \(shellQuote(versionName)) ]; then",
                "    need_download=0",
                "  fi",
            ]
        let wrapperBody = daemonWrapperScript().trimmingCharacters(in: .newlines)
        let qDaemon = shellQuote(daemonBinaryPath)
        let qService = shellQuote(daemonServiceName)
        let qPid = shellQuote(daemonPidFile)
        let qDiscovery = shellQuote(daemonDiscoveryPath)
        let lines = [
            "set -eu",
            "mkdir -p /opt/deskfleet /var/lib/deskfleet /var/log /run /root/.deskfleet",
            "need_download=1",
            "if [ -x \(qDaemon) ]; then",
        ] + versionCheckLines + [
            "fi",
            "if [ \"$need_download\" -eq 1 ]; then",
            "  tmp_archive=\"/tmp/deskfleet-daemon-riscv64.tar.gz\"",
            "  if command -v curl >/dev/null 2>&1; then",
            "    curl -fsSL \(shellQuote(releaseUrl)) -o \"$tmp_archive\"",
            "  elif command -v wget >/dev/null 2>&1; then",
            "    wget -qO \"$tmp_archive\" \(shellQuote(releaseUrl))",
            "  else",
            "    echo \"Neither curl nor wget is installed in guest\" >&2",
            "    exit 1",
            "  fi",
            "  tar -xzf \"$tmp_archive\" -C /opt/deskfleet",
            "  rm -f \"$tmp_archive\"",
            "  chmod +x \(qDaemon)",
            "  printf '%s' \(shellQuote(versionName)) >\(shellQuote(versionFile))",
            "fi",
            "if [ -x '/opt/deskfleet/node' ] && [ -f '/opt/deskfleet/daemon.cjs' ]; then",
            "  tmp_wrapper='/opt/deskfleet/.deskfleet-daemon.tmp'",
            "  cat <<'DESKFLEET_WRAPPER_EOF' >\"$tmp_wrapper\"",
            wrapperBody,
            "DESKFLEET_WRAPPER_EOF",
            "  if ! cmp -s \"$tmp_wrapper\" \(qDaemon) 2>/dev/null; then",
            "    chmod 0755 \"$tmp_wrapper\"",
            "    mv \"$tmp_wrapper\" \(qDaemon)",
            "    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet \(qService); then",
            "      systemctl stop \(qService) >/dev/null 2>&1 || true",
            "    fi",
            "    if [ -f \(qPid) ]; then",
            "      old_pid=$(cat \(qPid) 2>/dev/null || true)",
            "      if [ -n \"$old_pid\" ] && kill -0 \"$old_pid\" 2>/dev/null; then",
            "        kill \"$old_pid\" 2>/dev/null || true",
            "        wait_i=0",
            "        while [ \"$wait_i\" -lt 10 ] && kill -0 \"$old_pid\" 2>/dev/null; do",
            "          wait_i=$((wait_i + 1))",
            "          sleep 0.2",
            "        done",
            "        if kill -0 \"$old_pid\" 2>/dev/null; then",
            "          kill -9 \"$old_pid\" 2>/dev/null || true",
            "        fi",
            "      fi",
            "    fi",
            "    rm -f \(qPid) \(qDiscovery)",
            "    sync >/dev/null 2>&1 || true",
            "  else",
            "    rm -f \"$tmp_wrapper\"",
            "  fi",
            "fi",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Formats a framed host -> guest exec request sent over UART 1 (/dev/ttyS1):
    /// `<id> <utf8_byte_length>\n<command_utf8>`
    static func formatExecRequest(id: UInt64, command: String) -> Data {
        let body = Data(command.utf8)
        var frame = Data("\(id) \(body.count)\n".utf8)
        frame.append(body)
        return frame
    }

    /// Parses a guest -> host response header line `<id> <exit_code> <byte_length>`.
    static func parseExecResponseHeader(_ line: String) -> (id: UInt64, exitCode: Int, byteLength: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              let id = UInt64(parts[0]),
              let exitCode = Int(parts[1]),
              let byteLength = Int(parts[2]),
              byteLength >= 0 else {
            return nil
        }
        return (id: id, exitCode: exitCode, byteLength: byteLength)
    }

    /// Extracts the last valid JSON object from noisy guest command output.
    static func extractJsonObject(from rawOutput: String) throws -> [String: Any] {
        let lines = rawOutput
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("{") && $0.hasSuffix("}") }

        for candidate in lines.reversed() {
            if let data = candidate.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        if let first = rawOutput.firstIndex(of: "{"),
           let last = rawOutput.lastIndex(of: "}"),
           first < last {
            let slice = String(rawOutput[first...last])
            if let data = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        throw NSError(
            domain: "RvvmDaemonCommands",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Expected JSON object from guest daemon, got: \(rawOutput.prefix(240))"]
        )
    }

    /// Default Linux kernel command line when booting OpenSBI (`fw_jump.bin`) + kernel `Image`.
    static func guestBootCmdline(rootDevice: String = "/dev/nvme0n1p1") -> String {
        "console=ttyS0,115200 root=\(rootDevice) rw rootwait quiet"
    }

    /// Generates cloud-init NoCloud `user-data` configuring the framed `/dev/ttyS1` exec agent
    /// inside a standard riscv64 Linux guest image.
    static func guestExecAgentCloudInit() -> String {
        """
        #cloud-config
        write_files:
          - path: /usr/local/bin/deskfleet-exec-agent.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              set -u
              DEV="/dev/ttyS1"
              while true; do
                stty -F "$DEV" raw -echo -icrnl -onlcr clocal -hupcl 115200 2>/dev/null || true
                if exec 3<>"$DEV"; then
                  printf '\\n' >&3 2>/dev/null || true
                  while IFS=' ' read -r req_id req_len <&3; do
                    [ -z "$req_id" ] && continue
                    case "$req_len" in
                      ''|*[!0-9]*) continue ;;
                    esac
                    cmd_file="/tmp/df-cmd-${req_id}.sh"
                    out_file="/tmp/df-out-${req_id}.txt"
                    dd bs=1 count="$req_len" of="$cmd_file" <&3 2>/dev/null || true
                    sh "$cmd_file" >"$out_file" 2>&1
                    rc=$?
                    out_len=$(wc -c <"$out_file" | tr -d ' ')
                    printf '\\n%s %s %s\\n' "$req_id" "$rc" "$out_len" >&3 2>/dev/null || break
                    cat "$out_file" >&3 2>/dev/null || break
                    rm -f "$cmd_file" "$out_file"
                  done
                  exec 3>&- 2>/dev/null || true
                fi
                sleep 0.2
              done
          - path: /etc/systemd/system/deskfleet-exec-agent.service
            permissions: '0644'
            content: |
              [Unit]
              Description=DeskFleet UART1 Framed Exec Agent
              After=local-fs.target network-online.target
              [Service]
              ExecStart=/usr/local/bin/deskfleet-exec-agent.sh
              KillMode=process
              Restart=always
              RestartSec=1
              [Install]
              WantedBy=multi-user.target
        runcmd:
          - systemctl daemon-reload
          - systemctl enable --now deskfleet-exec-agent.service
        """
    }
}
