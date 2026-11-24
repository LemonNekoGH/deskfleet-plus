import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import test from "node:test"
import {
  ALL_IOS_VIEWER_TARGETS,
  buildStaticFrameworkBundle,
  buildStikJitInfoPlist,
  buildStikJitXcframeworkPlist,
  downloadCachedArtifact,
  FORBIDDEN_STAGED_ARTIFACTS,
  iosViewerTargets,
  prepareLibrvvmHeaders,
  purgeGplRvvmSources,
  RVVM_EXCLUDED_GPL_SOURCES,
  RVVM_FW_JUMP_SPEC,
  RVVM_FW_PAYLOAD_SPEC,
  RVVM_SOURCE_SPEC,
  stageRvvmGuestFirmware,
  stageStikJitFramework,
  STIKJIT_SPEC,
  type BinaryArtifactSpec,
} from "./build-ios-viewer.ts"

const repoRoot = resolve(import.meta.dirname, "..")

function createStoredZip(files: { name: string; content: Buffer; mode?: number }[]): Buffer {
  const localChunks: Buffer[] = []
  const centralChunks: Buffer[] = []
  let offset = 0

  for (const file of files) {
    const nameBuf = Buffer.from(file.name, "utf8")
    const data = file.content
    const local = Buffer.alloc(30 + nameBuf.length)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt16LE(0, 6)
    local.writeUInt16LE(0, 8)
    local.writeUInt32LE(0, 14)
    local.writeUInt32LE(data.length, 18)
    local.writeUInt32LE(data.length, 22)
    local.writeUInt16LE(nameBuf.length, 26)
    local.writeUInt16LE(0, 28)
    nameBuf.copy(local, 30)

    localChunks.push(local, data)

    const central = Buffer.alloc(46 + nameBuf.length)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(0x0314, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0, 8)
    central.writeUInt16LE(0, 10)
    central.writeUInt32LE(0, 16)
    central.writeUInt32LE(data.length, 20)
    central.writeUInt32LE(data.length, 24)
    central.writeUInt16LE(nameBuf.length, 28)
    central.writeUInt16LE(0, 30)
    central.writeUInt16LE(0, 32)
    central.writeUInt32LE(((file.mode ?? 0o644) & 0o777) << 16, 38)
    central.writeUInt32LE(offset, 42)
    nameBuf.copy(central, 46)
    centralChunks.push(central)

    offset += local.length + data.length
  }

  const centralDir = Buffer.concat(centralChunks)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054b50, 0)
  eocd.writeUInt16LE(files.length, 8)
  eocd.writeUInt16LE(files.length, 10)
  eocd.writeUInt32LE(centralDir.length, 12)
  eocd.writeUInt32LE(offset, 16)

  return Buffer.concat([...localChunks, centralDir, eocd])
}

test("downloadCachedArtifact verifies SHA-256, reuses valid cache, and rejects mismatches", async () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-rvvm-cache-test-"))
  try {
    const payload = Buffer.from("verified-rvvm-artifact")
    const digest = createHash("sha256").update(payload).digest("hex")
    const spec: BinaryArtifactSpec = {
      name: "test-artifact",
      version: "1.0.0",
      filename: "artifact.bin",
      url: "https://example.invalid/artifact.bin",
      sha256: digest,
    }

    let fetchCount = 0
    const fetcher = (async () => {
      fetchCount += 1
      return new Response(payload, { status: 200 })
    }) as typeof fetch

    const first = await downloadCachedArtifact(spec, workDir, fetcher)
    assert.equal(fetchCount, 1)
    assert.deepEqual(readFileSync(first), payload)

    const second = await downloadCachedArtifact(spec, workDir, fetcher)
    assert.equal(second, first)
    assert.equal(fetchCount, 1)

    writeFileSync(first, Buffer.from("corrupted"))
    await downloadCachedArtifact(spec, workDir, fetcher)
    assert.equal(fetchCount, 2)

    const badSpec: BinaryArtifactSpec = { ...spec, filename: "bad.bin", sha256: "0".repeat(64) }
    await assert.rejects(() => downloadCachedArtifact(badSpec, workDir, fetcher), /SHA-256 mismatch/)
    assert.equal(existsSync(join(workDir, "bad.bin")), false)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})

test("stageStikJitFramework extracts StikJIT.xcframework and synthesizes Info.plist", () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-stikjit-test-"))
  try {
    const zipPath = join(workDir, "StikJIT.xcframework.zip")
    const zipBytes = createStoredZip([
      { name: "StikJIT.xcframework/Info.plist", content: Buffer.from("<plist/>") },
      { name: "StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT", content: Buffer.from("bin"), mode: 0o755 },
      { name: "StikJIT.xcframework/ios-arm64/StikJIT.framework/universal.js", content: Buffer.from("// js") },
    ])
    writeFileSync(zipPath, zipBytes)

    const frameworksDir = join(workDir, "Frameworks")
    const staged = stageStikJitFramework(zipPath, frameworksDir, STIKJIT_SPEC.version, false)
    const synthesizedPlist = join(staged, "ios-arm64/StikJIT.framework/Info.plist")
    assert.equal(existsSync(synthesizedPlist), true)
    assert.equal(readFileSync(synthesizedPlist, "utf8"), buildStikJitInfoPlist(STIKJIT_SPEC.version))
    assert.match(readFileSync(synthesizedPlist, "utf8"), /<string>17\.4<\/string>/)

    const dualPlist = buildStikJitXcframeworkPlist(true)
    assert.match(dualPlist, /ios-arm64-simulator/)
    assert.match(dualPlist, /<key>SupportedPlatformVariant<\/key>\s*<string>simulator<\/string>/)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})

test("buildStaticFrameworkBundle produces a framework module that avoids include/module.modulemap collisions", () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-static-fw-test-"))
  try {
    const libPath = join(workDir, "libdemo.a")
    const hdrPath = join(workDir, "demo.h")
    writeFileSync(libPath, "archive-bytes")
    writeFileSync(hdrPath, "void demo(void);\n")

    const fw = buildStaticFrameworkBundle({
      outputDir: join(workDir, "out"),
      frameworkName: "IshPlusRPPairing",
      bundleId: "moe.remon.deskfleet.plus.IshPlusRPPairing",
      staticLibPath: libPath,
      headerSourcePath: hdrPath,
      headerFileName: "ishplus_rppairing.h",
      platform: "iPhoneOS",
    })
    assert.equal(existsSync(join(fw, "IshPlusRPPairing")), true)
    assert.equal(existsSync(join(fw, "Headers/ishplus_rppairing.h")), true)
    assert.equal(existsSync(join(fw, "Info.plist")), true)
    assert.match(readFileSync(join(fw, "Modules/module.modulemap"), "utf8"), /framework module IshPlusRPPairing/)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})

test("purgeGplRvvmSources deletes upstream GPL CLI entry points while preserving MPL library sources", () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-rvvm-gpl-test-"))
  try {
    mkdirSync(join(workDir, "src/core"), { recursive: true })
    writeFileSync(join(workDir, "src/main.c"), "// GPL-3.0")
    writeFileSync(join(workDir, "src/rvvm_user_main.c"), "// GPL-3.0")
    writeFileSync(join(workDir, "src/core/rvvm.c"), "// MPL-2.0")

    const removed = purgeGplRvvmSources(workDir)
    assert.deepEqual(removed, [...RVVM_EXCLUDED_GPL_SOURCES])
    assert.equal(existsSync(join(workDir, "src/main.c")), false)
    assert.equal(existsSync(join(workDir, "src/rvvm_user_main.c")), false)
    assert.equal(existsSync(join(workDir, "src/core/rvvm.c")), true)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})

test("prepareLibrvvmHeaders stages public MPL-2.0 headers and modulemap", () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-rvvm-hdr-test-"))
  try {
    mkdirSync(join(workDir, "src/include/rvvm"), { recursive: true })
    mkdirSync(join(workDir, "src/src/util"), { recursive: true })
    mkdirSync(join(workDir, "src/src/devices"), { recursive: true })
    writeFileSync(join(workDir, "src/include/rvvm/rvvm.h"), "// rvvm")
    writeFileSync(join(workDir, "src/include/rvvm/rvvm_board.h"), "// board")
    writeFileSync(join(workDir, "src/src/util/rvvmlib.h"), "#include <rvvm/rvvm.h>\n")
    writeFileSync(join(workDir, "src/src/devices/chardev.h"), "// chardev")
    writeFileSync(join(workDir, "src/src/devices/ns16550a.h"), "// uart")
    writeFileSync(join(workDir, "src/src/devices/rtl8169.h"), "// nic")
    writeFileSync(join(workDir, "src/src/devices/tap_api.h"), "// tap")

    const headersDir = prepareLibrvvmHeaders(join(workDir, "src"), join(workDir, "out-headers"))
    assert.equal(existsSync(join(headersDir, "rvvm/rvvm.h")), true)
    assert.equal(existsSync(join(headersDir, "rvvm/rvvm_board.h")), true)
    assert.equal(existsSync(join(headersDir, "ns16550a.h")), true)
    assert.equal(existsSync(join(headersDir, "rtl8169.h")), true)
    assert.equal(existsSync(join(headersDir, "rvvmlib.h")), true)
    const modulemap = readFileSync(join(headersDir, "module.modulemap"), "utf8")
    assert.match(modulemap, /module Librvvm/)
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})

test("stageRvvmGuestFirmware stages OpenSBI firmware and removes legacy GPL artifacts", () => {
  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-rvvm-fw-test-"))
  try {
    const fwPayloadSrc = join(workDir, "fw_payload.bin")
    const fwJumpSrc = join(workDir, "fw_jump.bin")
    writeFileSync(fwPayloadSrc, Buffer.from("payload-bytes"))
    writeFileSync(fwJumpSrc, Buffer.from("jump-bytes"))

    const frameworksDir = join(workDir, "Frameworks")
    mkdirSync(join(frameworksDir, "Guest"), { recursive: true })
    writeFileSync(join(frameworksDir, "libqemu-aarch64-softmmu.dylib"), "stale-gpl")
    writeFileSync(join(frameworksDir, "Guest/vmlinuz"), "stale-ishplus")

    const staged = stageRvvmGuestFirmware(
      [
        { sourcePath: fwPayloadSrc, filename: RVVM_FW_PAYLOAD_SPEC.filename },
        { sourcePath: fwJumpSrc, filename: RVVM_FW_JUMP_SPEC.filename },
      ],
      frameworksDir,
    )
    assert.equal(staged.length, 2)
    assert.deepEqual(readFileSync(join(frameworksDir, "Guest/fw_payload.bin")), Buffer.from("payload-bytes"))
    assert.deepEqual(readFileSync(join(frameworksDir, "Guest/fw_jump.bin")), Buffer.from("jump-bytes"))
    for (const forbidden of FORBIDDEN_STAGED_ARTIFACTS) {
      assert.equal(existsSync(join(frameworksDir, forbidden)), false, `Expected ${forbidden} to be purged`)
    }
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
})

test("pinned iOS librvvm artifacts, patch, Xcode wiring, and notices exclude GPL QEMU/iSH+", () => {
  assert.match(RVVM_SOURCE_SPEC.sha256, /^[0-9a-f]{64}$/)
  assert.match(RVVM_FW_PAYLOAD_SPEC.sha256, /^[0-9a-f]{64}$/)
  assert.match(RVVM_FW_JUMP_SPEC.sha256, /^[0-9a-f]{64}$/)
  assert.match(STIKJIT_SPEC.sha256, /^[0-9a-f]{64}$/)

  const patchPath = join(repoRoot, "packages/capacitor-bridge/ios/rvvm/ios-jit.patch")
  assert.equal(existsSync(patchPath), true)
  const patchText = readFileSync(patchPath, "utf8")
  assert.match(patchText, /rvvm_set_ram_allocator/)
  assert.match(patchText, /rvvm_ios_jit_detach/)
  assert.match(patchText, /vma_ios_jit26_prepare_region/)

  const packageSwift = readFileSync(join(repoRoot, "packages/capacitor-bridge/Package.swift"), "utf8")
  assert.match(packageSwift, /Librvvm\.xcframework/)
  assert.match(packageSwift, /name: "RvvmRuntime"/)
  assert.doesNotMatch(packageSwift, /IshPlusRuntime|libqemu/i)

  const pbxproj = readFileSync(join(repoRoot, "apps/web/ios/App/App.xcodeproj/project.pbxproj"), "utf8")
  assert.match(pbxproj, /DeskFleetJITHelper/)
  assert.match(pbxproj, /moe\.remon\.deskfleet\.plus\.jit-helper/)
  assert.match(pbxproj, /StikJIT\.xcframework.*platformFilter = ios;/)
  assert.match(pbxproj, /fw_payload\.bin fw_jump\.bin/)
  assert.doesNotMatch(pbxproj, /libqemu|iSHJITHelper/i)
  const provMatches = pbxproj.match(/PROVISIONING_PROFILE_SPECIFIER/g) ?? []
  assert.equal(provMatches.length, 2)

  const notices = readFileSync(join(repoRoot, "THIRD_PARTY_NOTICES.md"), "utf8")
  assert.match(notices, /MPL-2\.0/)
  assert.match(notices, /librvvm/i)
  assert.match(notices, /StikJIT/)
  assert.match(notices, /OpenSBI/)
})

test("iosViewerTargets defaults to both device and simulator slices", () => {
  assert.deepEqual(iosViewerTargets({}, []), ALL_IOS_VIEWER_TARGETS)
  assert.deepEqual(iosViewerTargets({ DESKFLEET_IOS_TARGETS: "   " }, []), ALL_IOS_VIEWER_TARGETS)
})

test("iosViewerTargets selects single slices from env or CLI flags and deduplicates", () => {
  assert.deepEqual(
    iosViewerTargets({ DESKFLEET_IOS_TARGETS: "aarch64-apple-ios" }, []),
    ["aarch64-apple-ios"],
  )
  assert.deepEqual(
    iosViewerTargets({ DESKFLEET_IOS_TARGETS: "aarch64-apple-ios-sim, aarch64-apple-ios-sim" }, []),
    ["aarch64-apple-ios-sim"],
  )
  assert.deepEqual(
    iosViewerTargets({ DESKFLEET_IOS_TARGETS: "aarch64-apple-ios" }, ["--target", "aarch64-apple-ios-sim"]),
    ["aarch64-apple-ios-sim"],
  )
  assert.deepEqual(
    iosViewerTargets({}, ["--target=aarch64-apple-ios,aarch64-apple-ios-sim"]),
    ALL_IOS_VIEWER_TARGETS,
  )
})

test("iosViewerTargets rejects unsupported or empty targets", () => {
  assert.throws(() => iosViewerTargets({ DESKFLEET_IOS_TARGETS: "x86_64-apple-ios" }, []), /Unsupported iOS viewer target/)
  assert.throws(() => iosViewerTargets({ DESKFLEET_IOS_TARGETS: "," }, []), /Select at least one/)
  assert.throws(() => iosViewerTargets({}, ["--target"]), /requires an iOS Rust target triple/)
})
