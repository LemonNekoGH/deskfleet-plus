import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
  chmodSync,
  closeSync,
  copyFileSync,
  createReadStream,
  createWriteStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
  writeSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { pipeline } from "node:stream/promises"
import { createGzip } from "node:zlib"

export const RISCV64_RUST_TARGET = "riscv64gc-unknown-linux-gnu"
export const DEFAULT_GUEST_PARTITION_MIB = 1536
export const MBR_PARTITION_START_SECTOR = 2048 // 1 MiB alignment

export function nodeRiscv64DownloadUrl(nodeVersion: string = process.version): string {
  const normalized = nodeVersion.startsWith("v") ? nodeVersion : `v${nodeVersion}`
  return `https://unofficial-builds.nodejs.org/download/release/${normalized}/node-${normalized}-linux-riscv64.tar.xz`
}

export function buildDaemonWrapperScript(): string {
  return [
    "#!/bin/sh",
    'DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"',
    'exec "$DIR/node" "$DIR/daemon.cjs" "$@"',
    "",
  ].join("\n")
}

export function buildExtlinuxConf(): string {
  return [
    "DEFAULT deskfleet",
    "TIMEOUT 10",
    "",
    "LABEL deskfleet",
    "  MENU LABEL DeskFleet RISC-V 64 Linux",
    "  LINUX /boot/vmlinuz",
    "  INITRD /boot/initrd.img",
    "  APPEND console=ttyS0,115200 root=/dev/nvme0n1p1 rw rootwait quiet",
    "",
  ].join("\n")
}

export function buildExecAgentScript(): string {
  return [
    "#!/bin/sh",
    "set -u",
    'DEV="/dev/ttyS1"',
    'stty -F "$DEV" raw -echo -icrnl -onlcr 115200 2>/dev/null || true',
    'exec 3<>"$DEV"',
    "while IFS=' ' read -r req_id req_len <&3; do",
    '  [ -z "$req_id" ] && continue',
    '  case "$req_len" in',
    "    ''|*[!0-9]*) continue ;;",
    "  esac",
    '  cmd_file="/tmp/df-cmd-${req_id}.sh"',
    '  out_file="/tmp/df-out-${req_id}.txt"',
    '  dd bs=1 count="$req_len" of="$cmd_file" <&3 2>/dev/null',
    "  set +e",
    '  sh "$cmd_file" >"$out_file" 2>&1',
    "  rc=$?",
    "  set -e",
    '  out_len=$(wc -c <"$out_file" | tr -d \' \')',
    '  printf \'%s %s %s\\n\' "$req_id" "$rc" "$out_len" >&3',
    '  cat "$out_file" >&3',
    '  rm -f "$cmd_file" "$out_file"',
    "done",
    "",
  ].join("\n")
}

export function buildExecAgentSystemdUnit(): string {
  return [
    "[Unit]",
    "Description=DeskFleet UART1 Framed Exec Agent",
    "After=local-fs.target network-online.target",
    "",
    "[Service]",
    "ExecStart=/usr/local/bin/deskfleet-exec-agent.sh",
    "Restart=always",
    "RestartSec=1",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n")
}

export function buildGuestRootfsDockerfile(version: string): string {
  return [
    "FROM --platform=linux/riscv64 ubuntu:24.04 AS rootfs",
    "ENV DEBIAN_FRONTEND=noninteractive",
    "RUN apt-get update \\",
    "  && apt-get install -y --no-install-recommends \\",
    "    systemd systemd-sysv dbus udev \\",
    "    linux-image-virtual initramfs-tools \\",
    "    ca-certificates curl git iproute2 openssh-client bash coreutils \\",
    "  && printf 'nvme\\nnvme_core\\nr8169\\next4\\n' >> /etc/initramfs-tools/modules \\",
    "  && update-initramfs -u -k all \\",
    "  && ln -sf \"$(ls /boot/vmlinuz-* | sort -V | tail -n 1)\" /boot/vmlinuz \\",
    "  && ln -sf \"$(ls /boot/initrd.img-* | sort -V | tail -n 1)\" /boot/initrd.img \\",
    "  && apt-get clean \\",
    "  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /usr/share/doc/* /usr/share/man/* /usr/share/info/*",
    "COPY daemon/ /opt/deskfleet/",
    "COPY extlinux.conf /boot/extlinux/extlinux.conf",
    "COPY deskfleet-exec-agent.sh /usr/local/bin/deskfleet-exec-agent.sh",
    "COPY deskfleet-exec-agent.service /etc/systemd/system/deskfleet-exec-agent.service",
    "RUN mkdir -p /opt/deskfleet /var/lib/deskfleet /root/workspace /etc/systemd/network \\",
    "  && chmod 0755 /opt/deskfleet/deskfleet-daemon /opt/deskfleet/node /usr/local/bin/deskfleet-exec-agent.sh \\",
    "  && chmod 0644 /opt/deskfleet/daemon.cjs /opt/deskfleet/deskfleet.node /boot/extlinux/extlinux.conf /etc/systemd/system/deskfleet-exec-agent.service \\",
    `  && printf '%s' '${version.replace(/'/g, "'\\''")}' > /opt/deskfleet/.version \\`,
    "  && printf 'deskfleet-ios\\n' > /etc/hostname \\",
    "  && printf '/dev/nvme0n1p1 / ext4 defaults,noatime 0 1\\n' > /etc/fstab \\",
    "  && printf '[Match]\\nName=en* eth*\\n\\n[Network]\\nDHCP=yes\\n' > /etc/systemd/network/20-rtl8169.network \\",
    "  && mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/network-online.target.wants \\",
    "  && ln -sf /etc/systemd/system/deskfleet-exec-agent.service /etc/systemd/system/multi-user.target.wants/deskfleet-exec-agent.service \\",
    "  && ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service \\",
    "  && ln -sf /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service \\",
    "  && /opt/deskfleet/node --version \\",
    "  && /opt/deskfleet/node -e \"console.log('node-js-ok')\" \\",
    "  && ldd /opt/deskfleet/deskfleet.node \\",
    "  && (/opt/deskfleet/node -e \"const m={exports:{}}; process.dlopen(m, '/opt/deskfleet/deskfleet.node'); console.log('dlopen-ok', Object.keys(m.exports).length)\" || /opt/deskfleet/node --jitless -e \"const m={exports:{}}; process.dlopen(m, '/opt/deskfleet/deskfleet.node'); console.log('dlopen-jitless-ok', Object.keys(m.exports).length)\") \\",
    "  && status_json=\"$(HOME=/tmp XDG_CONFIG_HOME=/tmp XDG_DATA_HOME=/tmp /opt/deskfleet/deskfleet-daemon status || HOME=/tmp XDG_CONFIG_HOME=/tmp XDG_DATA_HOME=/tmp /opt/deskfleet/node --jitless /opt/deskfleet/daemon.cjs status)\" \\",
    "  && echo \"Verified pre-baked riscv64 daemon status: $status_json\" \\",
    "  && echo \"$status_json\" | grep -q '\"registrations\"'",
    "",
    "FROM scratch AS export",
    "COPY --from=rootfs / /",
    "",
  ].join("\n")
}

/**
 * Writes a bootable single-partition MBR header at byte 0 of an existing disk image
 * where partition 1 starts at `startSector` (512-byte sectors) and spans `partitionBytes`.
 */
export function writeMbrPartitionTable(
  diskImagePath: string,
  partitionBytes: number,
  startSector: number = MBR_PARTITION_START_SECTOR,
): void {
  const sectorSize = 512
  const sectorCount = Math.floor(partitionBytes / sectorSize)
  if (sectorCount <= 0 || sectorCount > 0xffff_ffff) {
    throw new Error(`Invalid MBR partition sector count: ${sectorCount}`)
  }
  const mbr = Buffer.alloc(sectorSize, 0)
  mbr.writeUInt32LE(0xdf_20_26_01, 440)
  const entry = 446
  mbr[entry + 0] = 0x80 // Bootable (required by U-Boot distro_bootcmd)
  mbr[entry + 1] = 0xfe
  mbr[entry + 2] = 0xff
  mbr[entry + 3] = 0xff
  mbr[entry + 4] = 0x83 // Linux native ext4
  mbr[entry + 5] = 0xfe
  mbr[entry + 6] = 0xff
  mbr[entry + 7] = 0xff
  mbr.writeUInt32LE(startSector >>> 0, entry + 8)
  mbr.writeUInt32LE(sectorCount >>> 0, entry + 12)
  mbr[510] = 0x55
  mbr[511] = 0xaa

  const fd = openSync(diskImagePath, "r+")
  try {
    writeSync(fd, mbr, 0, mbr.length, 0)
  } finally {
    closeSync(fd)
  }
}

async function sha256File(filePath: string): Promise<string> {
  return new Promise((resolveHash, rejectHash) => {
    const hash = createHash("sha256")
    const stream = createReadStream(filePath)
    stream.on("data", chunk => hash.update(chunk))
    stream.on("error", rejectHash)
    stream.on("end", () => resolveHash(hash.digest("hex")))
  })
}

async function downloadFile(url: string, destPath: string): Promise<void> {
  const response = await fetch(url)
  if (!response.ok) {
    throw new Error(`Failed to download ${url}: HTTP ${response.status}`)
  }
  const payload = Buffer.from(await response.arrayBuffer())
  writeFileSync(destPath, payload)
}

/**
 * Stages a self-contained riscv64 daemon directory containing the untouched Node.js riscv64
 * runtime, esbuild daemon bundle, cross-compiled deskfleet.node addon, and launcher script.
 */
export async function buildRiscv64DaemonBundle(
  repoRoot: string,
  bundleDir: string,
  nodeVersion: string = process.version,
): Promise<string> {
  rmSync(bundleDir, { recursive: true, force: true })
  mkdirSync(bundleDir, { recursive: true })

  // 1. Ensure Rust riscv64 target is installed
  const installed = execFileSync("rustup", ["target", "list", "--installed"], {
    cwd: repoRoot,
    encoding: "utf8",
  })
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
  if (!installed.includes(RISCV64_RUST_TARGET)) {
    execFileSync("rustup", ["target", "add", RISCV64_RUST_TARGET], {
      cwd: repoRoot,
      stdio: "inherit",
    })
  }

  // 2. Cross-compile crates/node (deskfleet.node) for riscv64gc-unknown-linux-gnu
  execFileSync(
    "cargo",
    ["build", "-p", "deskfleet-node", "--release", "--target", RISCV64_RUST_TARGET, "--locked"],
    {
      cwd: repoRoot,
      stdio: "inherit",
      env: {
        ...process.env,
        CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER: "riscv64-linux-gnu-gcc",
        CC_riscv64gc_unknown_linux_gnu: "riscv64-linux-gnu-gcc",
        CXX_riscv64gc_unknown_linux_gnu: "riscv64-linux-gnu-g++",
        AR_riscv64gc_unknown_linux_gnu: "riscv64-linux-gnu-ar",
      },
    },
  )

  const nativeSo = join(repoRoot, "target", RISCV64_RUST_TARGET, "release/libdeskfleet_node.so")
  if (!existsSync(nativeSo)) {
    throw new Error(`Expected cross-compiled native addon at ${nativeSo}`)
  }
  copyFileSync(nativeSo, join(bundleDir, "deskfleet.node"))

  // 3. Bundle apps/daemon/src/main.ts into a single CJS script
  const { build: esbuild } = await import("esbuild")
  await esbuild({
    absWorkingDir: repoRoot,
    entryPoints: ["apps/daemon/src/main.ts"],
    outfile: join(bundleDir, "daemon.cjs"),
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node24",
    define: {
      "import.meta.dirname": "__dirname",
      "import.meta.url": "__deskfleet_module_url",
    },
    banner: { js: "const __deskfleet_module_url = require('node:url').pathToFileURL(__filename).href;" },
  })

  // 4. Fetch untouched Node.js riscv64 runtime matching the locked Node version
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-riscv64-node-"))
  try {
    const nodeTar = join(workDir, "node-riscv64.tar.xz")
    const nodeUrl = nodeRiscv64DownloadUrl(nodeVersion)
    console.log(`Downloading ${nodeUrl}`)
    await downloadFile(nodeUrl, nodeTar)
    const nodeExtract = join(workDir, "node-riscv64")
    mkdirSync(nodeExtract, { recursive: true })
    execFileSync("tar", ["-xJf", nodeTar, "-C", nodeExtract, "--strip-components=1"], { stdio: "inherit" })

    const nodeBin = join(bundleDir, "node")
    copyFileSync(join(nodeExtract, "bin/node"), nodeBin)
    chmodSync(nodeBin, 0o755)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }

  const wrapperPath = join(bundleDir, "deskfleet-daemon")
  writeFileSync(wrapperPath, buildDaemonWrapperScript(), "utf8")
  chmodSync(wrapperPath, 0o755)
  return bundleDir
}

export async function buildRiscv64GuestDiskImage(options: {
  readonly daemonBundleDir: string
  readonly outDir: string
  readonly version: string
  readonly partitionMiB?: number
}): Promise<{ readonly rawImagePath: string; readonly gzImagePath: string }> {
  const partitionMiB = options.partitionMiB ?? DEFAULT_GUEST_PARTITION_MIB
  mkdirSync(options.outDir, { recursive: true })

  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-riscv64-img-"))
  try {
    const contextDir = join(workDir, "context")
    const contextDaemonDir = join(contextDir, "daemon")
    const rootfsDir = join(workDir, "rootfs")
    mkdirSync(contextDaemonDir, { recursive: true })
    mkdirSync(rootfsDir, { recursive: true })

    for (const file of ["deskfleet-daemon", "node", "daemon.cjs", "deskfleet.node"]) {
      copyFileSync(join(options.daemonBundleDir, file), join(contextDaemonDir, file))
    }
    chmodSync(join(contextDaemonDir, "deskfleet-daemon"), 0o755)
    chmodSync(join(contextDaemonDir, "node"), 0o755)
    writeFileSync(join(contextDir, "extlinux.conf"), buildExtlinuxConf(), "utf8")
    writeFileSync(join(contextDir, "deskfleet-exec-agent.sh"), buildExecAgentScript(), "utf8")
    writeFileSync(join(contextDir, "deskfleet-exec-agent.service"), buildExecAgentSystemdUnit(), "utf8")
    writeFileSync(join(contextDir, "Dockerfile"), buildGuestRootfsDockerfile(options.version), "utf8")

    // Build, smoke-test inside linux/riscv64 container, and export the complete rootfs
    const buildxArgs = [
      "buildx",
      "build",
      "--platform",
      "linux/riscv64",
      "--target",
      "export",
      "--progress=plain",
    ]
    if (process.env.GITHUB_ACTIONS === "true") {
      buildxArgs.push(
        "--cache-from",
        "type=gha,scope=ios-guest-riscv64",
        "--cache-to",
        "type=gha,mode=max,scope=ios-guest-riscv64",
      )
    }
    buildxArgs.push("--output", `type=local,dest=${rootfsDir}`, contextDir)
    execFileSync("docker", buildxArgs, { stdio: "inherit" })

    // Populate /etc/hosts and /etc/resolv.conf outside Docker (Docker mounts /etc/hosts read-only during RUN)
    rmSync(join(rootfsDir, ".dockerenv"), { force: true })
    rmSync(join(rootfsDir, "etc/hosts"), { force: true })
    writeFileSync(join(rootfsDir, "etc/hosts"), "127.0.0.1 localhost deskfleet-ios\n::1 localhost\n", "utf8")
    rmSync(join(rootfsDir, "etc/resolv.conf"), { force: true })
    writeFileSync(join(rootfsDir, "etc/resolv.conf"), "nameserver 1.1.1.1\nnameserver 8.8.8.8\n", "utf8")
    for (const dir of ["dev", "proc", "sys", "tmp", "run"]) {
      mkdirSync(join(rootfsDir, dir), { recursive: true })
    }
    chmodSync(join(rootfsDir, "tmp"), 0o1777)

    // Build ext4 partition image in userspace (no root/loop mount required)
    const partImg = join(workDir, "part.ext4")
    execFileSync("truncate", ["-s", `${partitionMiB}M`, partImg], { stdio: "inherit" })
    execFileSync("mke2fs", ["-t", "ext4", "-d", rootfsDir, "-L", "deskfleet-root", "-F", partImg], {
      stdio: "inherit",
    })

    // Assemble 1 MiB MBR header + ext4 partition into deskfleet-riscv64.img
    const rawImagePath = join(options.outDir, "deskfleet-riscv64.img")
    const partSize = statSync(partImg).size
    const headerBytes = MBR_PARTITION_START_SECTOR * 512
    rmSync(rawImagePath, { force: true })
    writeFileSync(rawImagePath, Buffer.alloc(headerBytes, 0))
    await pipeline(createReadStream(partImg), createWriteStream(rawImagePath, { flags: "a" }))
    writeMbrPartitionTable(rawImagePath, partSize, MBR_PARTITION_START_SECTOR)

    // Compress disk image to deskfleet-riscv64.img.gz
    const gzImagePath = join(options.outDir, "deskfleet-riscv64.img.gz")
    rmSync(gzImagePath, { force: true })
    await pipeline(createReadStream(rawImagePath), createGzip({ level: 6 }), createWriteStream(gzImagePath))

    return { rawImagePath, gzImagePath }
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const repoRoot = resolve(import.meta.dirname, "..")
  const outDir = resolve(process.argv[2] || join(repoRoot, "dist/ios-guest-riscv64"))
  const pkg = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")) as { version?: string }
  const version = process.env.DESKFLEET_GUEST_VERSION || pkg.version || "0.0.0"

  const daemonBundleDir = join(outDir, "daemon-bundle")
  await buildRiscv64DaemonBundle(repoRoot, daemonBundleDir)
  const daemonTar = join(outDir, "deskfleet-linux-riscv64.tar.gz")
  execFileSync("tar", ["-czf", daemonTar, "-C", daemonBundleDir, "."], { stdio: "inherit" })

  const { rawImagePath, gzImagePath } = await buildRiscv64GuestDiskImage({
    daemonBundleDir,
    outDir,
    version,
  })
  rmSync(rawImagePath, { force: true })
  rmSync(daemonBundleDir, { recursive: true, force: true })

  const sums: string[] = []
  for (const file of [gzImagePath, daemonTar]) {
    const digest = await sha256File(file)
    const name = file.split(/[\\/]/).pop()!
    sums.push(`${digest}  ${name}`)
  }
  writeFileSync(join(outDir, "SHA256SUMS.txt"), sums.join("\n") + "\n", "utf8")
  console.log(`Built RISC-V 64 guest artifacts in ${outDir}:\n${sums.join("\n")}`)
}
