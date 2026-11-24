import assert from "node:assert/strict"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import {
  BOX64_REPO,
  BOX64_REV,
  buildBox64BinfmtConf,
  buildBox64RcFile,
  buildDaemonWrapperScript,
  buildExecAgentScript,
  buildExecAgentSystemdUnit,
  buildExtlinuxConf,
  buildGuestRootfsDockerfile,
  buildNodeWrapperScript,
  buildNpmWrapperScript,
  buildNpxWrapperScript,
  DEFAULT_GUEST_PARTITION_MIB,
  MBR_PARTITION_START_SECTOR,
  nodeRiscv64DownloadUrl,
  writeMbrPartitionTable,
} from "./build-ios-riscv64-guest.ts"

test("nodeRiscv64DownloadUrl targets unofficial-builds linux-riscv64 archive", () => {
  assert.equal(
    nodeRiscv64DownloadUrl("24.22.1"),
    "https://unofficial-builds.nodejs.org/download/release/v24.22.1/node-v24.22.1-linux-riscv64.tar.xz",
  )
  assert.equal(
    nodeRiscv64DownloadUrl("v24.22.1"),
    "https://unofficial-builds.nodejs.org/download/release/v24.22.1/node-v24.22.1-linux-riscv64.tar.xz",
  )
})

test("buildExtlinuxConf and guest rootfs Dockerfile bake nvme, r8169, exec agent, and daemon", () => {
  const extlinux = buildExtlinuxConf()
  assert.match(extlinux, /LINUX \/boot\/vmlinuz/)
  assert.match(extlinux, /INITRD \/boot\/initrd\.img/)
  assert.match(extlinux, /root=\/dev\/nvme0n1p1/)
  assert.equal(DEFAULT_GUEST_PARTITION_MIB, 3072)

  assert.equal(BOX64_REPO, "https://github.com/ptitSeb/box64.git")
  assert.equal(BOX64_REV, "1d7564266933aa2b297a8e64bf7a656a819531cf")
  const dockerfile = buildGuestRootfsDockerfile("0.18.2")
  assert.match(dockerfile, /AS box64-builder/)
  assert.ok(dockerfile.includes(BOX64_REPO))
  assert.ok(dockerfile.includes(BOX64_REV))
  assert.match(dockerfile, /COPY --from=box64-builder \/out\/box64 \/usr\/local\/bin\/box64/)
  assert.match(dockerfile, /FROM --platform=linux\/riscv64 ubuntu:24\.04/)
  assert.match(dockerfile, /nvme\\nnvme_core\\nr8169\\next4/)
  assert.match(dockerfile, /COPY daemon\/ \/opt\/deskfleet\//)
  assert.match(dockerfile, /\/etc\/binfmt\.d\/box64\.conf/)
  assert.match(dockerfile, /\/etc\/box64\.box64rc/)
  assert.match(dockerfile, /\/usr\/local\/bin\/node/)
  assert.match(dockerfile, /\/usr\/local\/bin\/npm/)
  assert.match(dockerfile, /\/usr\/local\/bin\/npx/)
  assert.match(dockerfile, /systemd-binfmt\.service/)
  assert.match(dockerfile, /deskfleet-exec-agent\.service/)
  assert.match(dockerfile, /20-rtl8169\.network/)

  const wrapper = buildDaemonWrapperScript()
  assert.doesNotMatch(wrapper, /--jitless/)
  assert.match(wrapper, /exec "\$DIR\/node" --no-sparkplug --no-maglev --no-opt --no-regexp-tier-up --liftoff-only --no-wasm-tier-up "\$DIR\/daemon\.cjs" "\$@"/)
  assert.match(buildNodeWrapperScript(), /exec \/opt\/deskfleet\/node --no-sparkplug --no-maglev --no-opt --no-regexp-tier-up --liftoff-only --no-wasm-tier-up "\$@"/)
  assert.match(buildNpmWrapperScript(), /npm-cli\.js "\$@"/)
  assert.match(buildNpxWrapperScript(), /npx-cli\.js "\$@"/)

  const binfmt = buildBox64BinfmtConf()
  assert.match(binfmt, /^# \/etc\/binfmt\.d\/box64\.conf\n:box64:M::\\x7fELF/m)
  assert.match(binfmt, /:\/usr\/local\/bin\/box64:\n$/)
  assert.doesNotMatch(binfmt, /:POC/)

  const rcfile = buildBox64RcFile()
  assert.match(rcfile, /\[\*\]/)
  assert.match(rcfile, /BOX64_DYNAREC_NOHOSTEXT=zicond,zbc,zicbop/)
  assert.match(rcfile, /\[agy\]/)
  assert.match(rcfile, /BOX64_DYNAREC_CALLRET=0/)
  assert.match(rcfile, /BOX64_DYNACACHE=1/)
  assert.match(rcfile, /BOX64_ENV=GODEBUG=asyncpreemptoff=1/)
  assert.ok(rcfile.indexOf("BOX64_ENV=GODEBUG=asyncpreemptoff=1") < rcfile.indexOf("[agy]"))

  const execScript = buildExecAgentScript()
  assert.match(execScript, /DEV="\/dev\/ttyS1"/)
  assert.match(execScript, /clocal -hupcl/)
  assert.match(execScript, /while true; do/)
  assert.doesNotMatch(execScript, /set -e/)
  assert.match(execScript, /printf '\\n%s %s %s\\n'/)
  const execUnit = buildExecAgentSystemdUnit()
  assert.match(execUnit, /ExecStart=\/usr\/local\/bin\/deskfleet-exec-agent\.sh/)
  assert.match(execUnit, /KillMode=process/)
})

test("writeMbrPartitionTable writes a bootable Linux ext4 partition entry at LBA 2048", () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-mbr-test-"))
  try {
    const imgPath = join(workDir, "disk.img")
    const partBytes = 64 * 1024 * 1024
    writeFileSync(imgPath, Buffer.alloc(1024, 0))
    writeMbrPartitionTable(imgPath, partBytes, MBR_PARTITION_START_SECTOR)

    const mbr = readFileSync(imgPath).subarray(0, 512)
    assert.equal(mbr[446], 0x80) // bootable flag
    assert.equal(mbr[450], 0x83) // Linux ext4 type
    assert.equal(mbr.readUInt32LE(454), MBR_PARTITION_START_SECTOR)
    assert.equal(mbr.readUInt32LE(458), partBytes / 512)
    assert.equal(mbr[510], 0x55)
    assert.equal(mbr[511], 0xaa)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})
