// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation

/// Pure Foundation command builders and framed UART-exec helpers for the embedded
/// riscv64 Linux guest running under librvvm.
internal enum RvvmDaemonCommands {
    static let daemonBinaryPath = "/opt/deskfleet/deskfleet-daemon"
    static let daemonPidFile = "/run/deskfleet-daemon.pid"
    static let daemonLogFile = "/var/log/deskfleet-daemon.log"
    static let daemonDiscoveryPath = "/root/.deskfleet/daemon.json"
    static let daemonReleaseAsset = "deskfleet-linux-riscv64.tar.gz"
    static let guestDiskArchiveAsset = "deskfleet-riscv64.img.gz"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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

    static func ensureDaemonRunningCommand() -> String {
        """
        mkdir -p /run /var/log /opt/deskfleet /root/.deskfleet
        export HOME=/root
        if [ -f \(shellQuote(daemonPidFile)) ] && kill -0 "$(cat \(shellQuote(daemonPidFile)))" 2>/dev/null; then
          exit 0
        fi
        nohup \(shellQuote(daemonBinaryPath)) </dev/null >>\(shellQuote(daemonLogFile)) 2>&1 3>&- &
        echo $! >\(shellQuote(daemonPidFile))
        """
    }

    static func daemonLogSizeCommand() -> String {
        let qLog = shellQuote(daemonLogFile)
        return "if [ -f \(qLog) ]; then wc -c <\(qLog) | tr -d ' '; else echo 0; fi"
    }

    static func daemonProbeCommand(logOffset: UInt64) -> String {
        let qPid = shellQuote(daemonPidFile)
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

    /// Ensures /opt/deskfleet/deskfleet-daemon (riscv64) exists inside the Linux guest.
    /// Uses the pre-baked binary when already present in the guest image, falling back to
    /// downloading deskfleet-linux-riscv64.tar.gz if missing.
    static func provisionDaemonCommand(releaseUrl: String, versionName: String) -> String {
        let versionFile = "/opt/deskfleet/.version"
        let skipVersionMismatch = versionName == "1.0" || versionName == "0.0.0"
        let versionCheck = skipVersionMismatch
            ? "  exit 0"
            : """
                if [ ! -f \(shellQuote(versionFile)) ] || [ "$(cat \(shellQuote(versionFile)))" = \(shellQuote(versionName)) ]; then
                  exit 0
                fi
              """
        return """
        set -eu
        mkdir -p /opt/deskfleet /var/lib/deskfleet /var/log /run /root/.deskfleet
        if [ -x \(shellQuote(daemonBinaryPath)) ]; then
        \(versionCheck)
        fi
        tmp_archive="/tmp/deskfleet-daemon-riscv64.tar.gz"
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL \(shellQuote(releaseUrl)) -o "$tmp_archive"
        elif command -v wget >/dev/null 2>&1; then
          wget -qO "$tmp_archive" \(shellQuote(releaseUrl))
        else
          echo "Neither curl nor wget is installed in guest" >&2
          exit 1
        fi
        tar -xzf "$tmp_archive" -C /opt/deskfleet
        rm -f "$tmp_archive"
        chmod +x \(shellQuote(daemonBinaryPath))
        printf '%s' \(shellQuote(versionName)) >\(shellQuote(versionFile))
        """
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
              stty -F "$DEV" raw -echo -icrnl -onlcr 115200 2>/dev/null || true
              exec 3<>"$DEV"
              while IFS=' ' read -r req_id req_len <&3; do
                [ -z "$req_id" ] && continue
                case "$req_len" in
                  ''|*[!0-9]*) continue ;;
                esac
                cmd_file="/tmp/df-cmd-${req_id}.sh"
                out_file="/tmp/df-out-${req_id}.txt"
                dd bs=1 count="$req_len" of="$cmd_file" <&3 2>/dev/null
                set +e
                sh "$cmd_file" >"$out_file" 2>&1
                rc=$?
                set -e
                out_len=$(wc -c <"$out_file" | tr -d ' ')
                printf '%s %s %s\n' "$req_id" "$rc" "$out_len" >&3
                cat "$out_file" >&3
                rm -f "$cmd_file" "$out_file"
              done
          - path: /etc/systemd/system/deskfleet-exec-agent.service
            permissions: '0644'
            content: |
              [Unit]
              Description=DeskFleet UART1 Framed Exec Agent
              After=local-fs.target network-online.target
              [Service]
              ExecStart=/usr/local/bin/deskfleet-exec-agent.sh
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
