import assert from "node:assert/strict"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import {
  buildDaemonWrapperScript,
  buildExecAgentScript,
  buildExecAgentSystemdUnit,
  buildExtlinuxConf,
  buildGuestRootfsDockerfile,
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

  const dockerfile = buildGuestRootfsDockerfile("0.18.2")
  assert.match(dockerfile, /FROM --platform=linux\/riscv64 ubuntu:24\.04/)
  assert.match(dockerfile, /nvme\\nnvme_core\\nr8169\\next4/)
  assert.match(dockerfile, /COPY daemon\/ \/opt\/deskfleet\//)
  assert.match(dockerfile, /\/opt\/deskfleet\/deskfleet-daemon status/)
  assert.match(dockerfile, /deskfleet-exec-agent\.service/)
  assert.match(dockerfile, /20-rtl8169\.network/)

  assert.match(buildDaemonWrapperScript(), /exec "\$DIR\/node" "\$DIR\/daemon\.cjs" "\$@"/)
  assert.match(buildExecAgentScript(), /DEV="\/dev\/ttyS1"/)
  assert.match(buildExecAgentSystemdUnit(), /ExecStart=\/usr\/local\/bin\/deskfleet-exec-agent\.sh/)
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
