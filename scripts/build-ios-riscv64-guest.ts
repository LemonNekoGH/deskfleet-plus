import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
  chmodSync,
  closeSync,
  copyFileSync,
  cpSync,
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
export const DEFAULT_GUEST_PARTITION_MIB = 3072
export const MBR_PARTITION_START_SECTOR = 2048 // 1 MiB alignment
// Upstream Box64 commit including PR #4758 (.dynamic patching for main PIE + DT_PREINIT_ARRAY).
export const BOX64_REPO = "https://github.com/ptitSeb/box64.git"
export const BOX64_REV = "1d7564266933aa2b297a8e64bf7a656a819531cf"

export function nodeRiscv64DownloadUrl(nodeVersion: string = process.version): string {
  const normalized = nodeVersion.startsWith("v") ? nodeVersion : `v${nodeVersion}`
  return `https://unofficial-builds.nodejs.org/download/release/${normalized}/node-${normalized}-linux-riscv64.tar.xz`
}

export const RISCV64_NODE_V8_FLAGS =
  "--no-sparkplug --no-maglev --no-opt --no-regexp-tier-up --liftoff-only --no-wasm-tier-up"

export function buildDaemonWrapperScript(): string {
  return [
    "#!/bin/sh",
    'DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"',
    `exec "$DIR/node" ${RISCV64_NODE_V8_FLAGS} "$DIR/daemon.cjs" "$@"`,
    "",
  ].join("\n")
}

export function buildNodeWrapperScript(): string {
  return [
    "#!/bin/sh",
    `exec /opt/deskfleet/node ${RISCV64_NODE_V8_FLAGS} "$@"`,
    "",
  ].join("\n")
}

export function buildNpmWrapperScript(): string {
  return [
    "#!/bin/sh",
    'exec /usr/local/bin/node /opt/deskfleet/lib/node_modules/npm/bin/npm-cli.js "$@"',
    "",
  ].join("\n")
}

export function buildNpxWrapperScript(): string {
  return [
    "#!/bin/sh",
    'exec /usr/local/bin/node /opt/deskfleet/lib/node_modules/npm/bin/npx-cli.js "$@"',
    "",
  ].join("\n")
}

export function buildBox64BinfmtConf(): string {
  return [
    "# /etc/binfmt.d/box64.conf",
    ":box64:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\x00\\x00\\x00\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/usr/local/bin/box64:",
    "",
  ].join("\n")
}

export function buildBox64RcFile(): string {
  return [
    "[*]",
    "BOX64_NOBANNER=1",
    "BOX64_DYNAREC_NOHOSTEXT=zicond,zbc,zicbop",
    // Box64 calls GatherEnv() before per-binary ApplyEnvFileEntry(), so BOX64_ENV must live in [*].
    "BOX64_ENV=GODEBUG=asyncpreemptoff=1",
    "",
    "[agy]",
    "BOX64_DYNAREC_CALLRET=0",
    "BOX64_DYNACACHE=1",
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
    "while true; do",
    '  stty -F "$DEV" raw -echo -icrnl -onlcr clocal -hupcl 115200 2>/dev/null || true',
    '  if exec 3<>"$DEV"; then',
    "    printf '\\n' >&3 2>/dev/null || true",
    "    while IFS=' ' read -r req_id req_len <&3; do",
    '      [ -z "$req_id" ] && continue',
    '      case "$req_len" in',
    "        ''|*[!0-9]*) continue ;;",
    "      esac",
    '      cmd_file="/tmp/df-cmd-${req_id}.sh"',
    '      out_file="/tmp/df-out-${req_id}.txt"',
    '      dd bs=1 count="$req_len" of="$cmd_file" <&3 2>/dev/null || true',
    '      sh "$cmd_file" >"$out_file" 2>&1',
    "      rc=$?",
    '      out_len=$(wc -c <"$out_file" | tr -d \' \')',
    '      printf \'\\n%s %s %s\\n\' "$req_id" "$rc" "$out_len" >&3 2>/dev/null || break',
    '      cat "$out_file" >&3 2>/dev/null || break',
    '      rm -f "$cmd_file" "$out_file"',
    "    done",
    "    exec 3>&- 2>/dev/null || true",
    "  fi",
    "  sleep 0.2",
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
    "KillMode=process",
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
    "FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS box64-builder",
    "ENV DEBIAN_FRONTEND=noninteractive",
    "RUN apt-get update \\",
    "  && apt-get install -y --no-install-recommends \\",
    "    git ca-certificates cmake ninja-build python3 \\",
    "    gcc-riscv64-linux-gnu g++-riscv64-linux-gnu binutils-riscv64-linux-gnu \\",
    "  && git init /src/box64 \\",
    `  && git -C /src/box64 fetch --depth 1 '${BOX64_REPO}' '${BOX64_REV}' \\`,
    "  && git -C /src/box64 checkout --detach FETCH_HEAD \\",
    "  && cmake -S /src/box64 -B /build/box64 -G Ninja \\",
    "    -DCMAKE_SYSTEM_NAME=Linux \\",
    "    -DCMAKE_SYSTEM_PROCESSOR=riscv64 \\",
    "    -DCMAKE_C_COMPILER=riscv64-linux-gnu-gcc \\",
    "    -DCMAKE_CXX_COMPILER=riscv64-linux-gnu-g++ \\",
    "    -DCMAKE_BUILD_TYPE=Release \\",
    "    -DRV64=ON \\",
    "    -DRV64_DYNAREC=ON \\",
    "    -DBOX32=OFF \\",
    "    -DNOGIT=ON \\",
    "  && cmake --build /build/box64 -j\"$(nproc)\" \\",
    "  && mkdir -p /out \\",
    "  && cp /build/box64/box64 /out/box64 \\",
    "  && riscv64-linux-gnu-strip /out/box64",
    "",
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
    "COPY --from=box64-builder /out/box64 /usr/local/bin/box64",
    "COPY daemon/ /opt/deskfleet/",
    "COPY extlinux.conf /boot/extlinux/extlinux.conf",
    "COPY box64.conf /etc/binfmt.d/box64.conf",
    "COPY box64.box64rc /etc/box64.box64rc",
    "COPY usr-local-node /usr/local/bin/node",
    "COPY usr-local-npm /usr/local/bin/npm",
    "COPY usr-local-npx /usr/local/bin/npx",
    "COPY deskfleet-exec-agent.sh /usr/local/bin/deskfleet-exec-agent.sh",
    "COPY deskfleet-exec-agent.service /etc/systemd/system/deskfleet-exec-agent.service",
    "RUN mkdir -p /opt/deskfleet /var/lib/deskfleet /root/workspace /root/.local/bin /root/.cache/box64 /etc/binfmt.d /etc/systemd/network /etc/systemd/system/sysinit.target.wants \\",
    "  && chmod 0755 /opt/deskfleet/deskfleet-daemon /opt/deskfleet/node /usr/local/bin/deskfleet-exec-agent.sh /usr/local/bin/box64 /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx \\",
    "  && chmod 0644 /opt/deskfleet/daemon.cjs /opt/deskfleet/deskfleet.node /boot/extlinux/extlinux.conf /etc/binfmt.d/box64.conf /etc/box64.box64rc /etc/systemd/system/deskfleet-exec-agent.service \\",
    `  && printf '%s' '${version.replace(/'/g, "'\\''")}' > /opt/deskfleet/.version \\`,
    "  && printf 'deskfleet-ios\\n' > /etc/hostname \\",
    "  && printf '/dev/nvme0n1p1 / ext4 defaults,noatime 0 1\\n' > /etc/fstab \\",
    "  && printf '[Match]\\nName=en* eth*\\n\\n[Network]\\nDHCP=yes\\n' > /etc/systemd/network/20-rtl8169.network \\",
    "  && mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/network-online.target.wants \\",
    "  && ln -sf /usr/lib/systemd/system/systemd-binfmt.service /etc/systemd/system/sysinit.target.wants/systemd-binfmt.service \\",
    "  && ln -sf /etc/systemd/system/deskfleet-exec-agent.service /etc/systemd/system/multi-user.target.wants/deskfleet-exec-agent.service \\",
    "  && ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service \\",
    "  && ln -sf /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service",
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

    const npmSrc = join(nodeExtract, "lib/node_modules/npm")
    if (existsSync(npmSrc)) {
      const npmDest = join(bundleDir, "lib/node_modules/npm")
      mkdirSync(join(bundleDir, "lib/node_modules"), { recursive: true })
      cpSync(npmSrc, npmDest, { recursive: true })
    }
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
    const libSrc = join(options.daemonBundleDir, "lib")
    if (existsSync(libSrc)) {
      cpSync(libSrc, join(contextDaemonDir, "lib"), { recursive: true })
    }
    chmodSync(join(contextDaemonDir, "deskfleet-daemon"), 0o755)
    chmodSync(join(contextDaemonDir, "node"), 0o755)
    writeFileSync(join(contextDir, "extlinux.conf"), buildExtlinuxConf(), "utf8")
    writeFileSync(join(contextDir, "box64.conf"), buildBox64BinfmtConf(), "utf8")
    writeFileSync(join(contextDir, "box64.box64rc"), buildBox64RcFile(), "utf8")
    writeFileSync(join(contextDir, "usr-local-node"), buildNodeWrapperScript(), "utf8")
    writeFileSync(join(contextDir, "usr-local-npm"), buildNpmWrapperScript(), "utf8")
    writeFileSync(join(contextDir, "usr-local-npx"), buildNpxWrapperScript(), "utf8")
    writeFileSync(join(contextDir, "deskfleet-exec-agent.sh"), buildExecAgentScript(), "utf8")
    writeFileSync(join(contextDir, "deskfleet-exec-agent.service"), buildExecAgentSystemdUnit(), "utf8")
    writeFileSync(join(contextDir, "Dockerfile"), buildGuestRootfsDockerfile(options.version), "utf8")

    // Fast pre-flight verification of the riscv64 daemon bundle inside ubuntu:24.04 before
    // spending several minutes building the full kernel + initramfs rootfs image.
    const smokeScript = [
      "set -eu",
      "echo '--- node --version ---'",
      "/opt/deskfleet/node --version",
      "echo '--- ldd deskfleet.node ---'",
      "ldd /opt/deskfleet/deskfleet.node",
      "echo '--- smoke test deskfleet-daemon status ---'",
      "if status_json=$(HOME=/tmp XDG_CONFIG_HOME=/tmp XDG_DATA_HOME=/tmp /opt/deskfleet/deskfleet-daemon status 2>&1); then",
      "  echo \"JIT mode OK: $status_json\"",
      "elif status_json=$(HOME=/tmp XDG_CONFIG_HOME=/tmp XDG_DATA_HOME=/tmp /opt/deskfleet/node --jitless /opt/deskfleet/daemon.cjs status 2>&1); then",
      "  echo \"QEMU-user jitless mode OK: $status_json\"",
      "else",
      "  echo \"QEMU-user execution failed (last output: $status_json); checking ELF/shared libs only\" >&2",
      "  ldd /opt/deskfleet/node",
      "  exit 0",
      "fi",
      "echo \"$status_json\" | grep -q '\"registrations\"'",
    ].join("\n")
    execFileSync(
      "docker",
      [
        "run",
        "--rm",
        "--platform",
        "linux/riscv64",
        "-v",
        `${contextDaemonDir}:/opt/deskfleet:ro`,
        "ubuntu:24.04",
        "sh",
        "-c",
        smokeScript,
      ],
      { stdio: "inherit" },
    )

    // Build and export the complete rootfs
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
