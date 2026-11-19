import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
  chmodSync,
  copyFileSync,
  createReadStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { inflateRawSync } from "node:zlib"

export interface BinaryArtifactSpec {
  readonly name: string
  readonly version: string
  readonly filename: string
  readonly url: string
  readonly sha256: string
}

/**
 * StikJIT v1.9.0 (MPL-2.0) used by DeskFleetJITHelper.appex for on-device Pure JIT.
 */
export const STIKJIT_SPEC: BinaryArtifactSpec = {
  name: "StikJIT",
  version: "1.9.0",
  filename: "StikJIT-1.9.0.xcframework.zip",
  url: "https://github.com/StikDebug/StikJIT/releases/download/1.9.0/StikJIT.xcframework.zip",
  sha256: "806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060",
}

/**
 * LekKit/RVVM pinned source archive. Only the MPL-2.0 librvvm static library is built;
 * GPL-3.0 CLI entry points (src/main.c, src/rvvm_user_main.c) are deleted prior to build.
 */
export const RVVM_SOURCE_SPEC: BinaryArtifactSpec = {
  name: "librvvm source",
  version: "0.7-abb3ace2",
  filename: "RVVM-abb3ace2cd5a8ed7be00394212551abd630745e1.tar.gz",
  url: "https://github.com/LekKit/RVVM/archive/abb3ace2cd5a8ed7be00394212551abd630745e1.tar.gz",
  sha256: "edcfecc27461ee1caf5058802939cdabc8d50e4d45438532631b67098509bbd4",
}

/**
 * OpenSBI + U-Boot RISC-V guest firmware (mere-aggregation guest binary loaded inside VM).
 */
export const RVVM_FW_PAYLOAD_SPEC: BinaryArtifactSpec = {
  name: "RVVM fw_payload.bin",
  version: "v0.5",
  filename: "fw_payload.bin",
  url: "https://github.com/LekKit/RVVM/releases/download/v0.5/fw_payload.bin",
  sha256: "5b7e6bd7afb302f61f643571a032bcaac9b9432cabd72c64419a02f971fa11f7",
}

/**
 * OpenSBI jump RISC-V guest firmware (BSD-2-Clause, loaded when booting a direct Linux Image).
 */
export const RVVM_FW_JUMP_SPEC: BinaryArtifactSpec = {
  name: "RVVM fw_jump.bin",
  version: "v0.5",
  filename: "fw_jump.bin",
  url: "https://github.com/LekKit/RVVM/releases/download/v0.5/fw_jump.bin",
  sha256: "bcf41493ee53e040555b0384b573fcb45f87d57d9df2715d6846a178abd9e0d7",
}

/**
 * GPL-licensed CLI entry points in the upstream RVVM archive that must be removed
 * before compiling the MPL-2.0 librvvm static library.
 */
export const RVVM_EXCLUDED_GPL_SOURCES: readonly string[] = [
  "src/main.c",
  "src/rvvm_user_main.c",
]

/**
 * Legacy GPL QEMU/iSH+ artifacts that must never be present in staged iOS frameworks.
 */
export const FORBIDDEN_STAGED_ARTIFACTS: readonly string[] = [
  "libqemu-aarch64-softmmu.dylib",
  "libqemu-aarch64-softmmu-tci.dylib",
  "Guest/vmlinuz",
  "Guest/initramfs",
  "Guest/modloop",
  "Guest/support.img",
  "Guest/4k",
  "MoltenVK.framework",
]

interface ZipCentralEntry {
  readonly name: string
  readonly compressionMethod: number
  readonly compressedSize: number
  readonly uncompressedSize: number
  readonly localHeaderOffset: number
  readonly unixMode: number
}

function parseZipCentralDirectory(zipBuffer: Buffer): ZipCentralEntry[] {
  const eocdSignature = 0x06054b50
  const maxSearch = Math.min(zipBuffer.length, 65_557)
  let eocdOffset = -1
  for (let offset = zipBuffer.length - 22; offset >= zipBuffer.length - maxSearch; offset--) {
    if (zipBuffer.readUInt32LE(offset) === eocdSignature) {
      eocdOffset = offset
      break
    }
  }
  if (eocdOffset < 0) {
    throw new Error("Invalid zip archive: missing End of Central Directory record")
  }
  const entryCount = zipBuffer.readUInt16LE(eocdOffset + 10)
  const centralDirOffset = zipBuffer.readUInt32LE(eocdOffset + 16)
  const entries: ZipCentralEntry[] = []
  let offset = centralDirOffset
  for (let i = 0; i < entryCount; i++) {
    if (offset + 46 > zipBuffer.length || zipBuffer.readUInt32LE(offset) !== 0x02014b50) {
      throw new Error(`Invalid zip central directory entry at offset ${offset}`)
    }
    const compressionMethod = zipBuffer.readUInt16LE(offset + 10)
    const compressedSize = zipBuffer.readUInt32LE(offset + 20)
    const uncompressedSize = zipBuffer.readUInt32LE(offset + 24)
    const nameLen = zipBuffer.readUInt16LE(offset + 28)
    const extraLen = zipBuffer.readUInt16LE(offset + 30)
    const commentLen = zipBuffer.readUInt16LE(offset + 32)
    const externalAttributes = zipBuffer.readUInt32LE(offset + 38)
    const localHeaderOffset = zipBuffer.readUInt32LE(offset + 42)
    const name = zipBuffer.subarray(offset + 46, offset + 46 + nameLen).toString("utf8")
    entries.push({
      name,
      compressionMethod,
      compressedSize,
      uncompressedSize,
      localHeaderOffset,
      unixMode: (externalAttributes >>> 16) & 0o777,
    })
    offset += 46 + nameLen + extraLen + commentLen
  }
  return entries
}

function readZipEntryData(zipBuffer: Buffer, entry: ZipCentralEntry): Buffer {
  const lh = entry.localHeaderOffset
  if (lh + 30 > zipBuffer.length || zipBuffer.readUInt32LE(lh) !== 0x04034b50) {
    throw new Error(`Invalid zip local file header for ${entry.name}`)
  }
  const nameLen = zipBuffer.readUInt16LE(lh + 26)
  const extraLen = zipBuffer.readUInt16LE(lh + 28)
  const dataStart = lh + 30 + nameLen + extraLen
  const compressed = zipBuffer.subarray(dataStart, dataStart + entry.compressedSize)
  if (entry.compressionMethod === 0) {
    return Buffer.from(compressed)
  }
  if (entry.compressionMethod === 8) {
    return inflateRawSync(compressed)
  }
  throw new Error(`Unsupported zip compression method ${entry.compressionMethod} for ${entry.name}`)
}

export async function sha256File(filePath: string): Promise<string> {
  return new Promise((resolveHash, rejectHash) => {
    const hash = createHash("sha256")
    const stream = createReadStream(filePath)
    stream.on("data", chunk => hash.update(chunk))
    stream.on("error", rejectHash)
    stream.on("end", () => resolveHash(hash.digest("hex")))
  })
}

export async function downloadCachedArtifact(
  spec: BinaryArtifactSpec,
  cacheDir: string,
  fetcher: typeof fetch = fetch,
): Promise<string> {
  mkdirSync(cacheDir, { recursive: true })
  const cachedPath = join(cacheDir, spec.filename)
  if (existsSync(cachedPath)) {
    const digest = await sha256File(cachedPath)
    if (digest === spec.sha256) {
      return cachedPath
    }
    rmSync(cachedPath, { force: true })
  }

  const partPath = `${cachedPath}.part`
  rmSync(partPath, { force: true })
  try {
    const response = await fetcher(spec.url)
    if (!response.ok) {
      throw new Error(`Failed to download ${spec.name} (${spec.url}): HTTP ${response.status}`)
    }
    const payload = Buffer.from(await response.arrayBuffer())
    const digest = createHash("sha256").update(payload).digest("hex")
    if (digest !== spec.sha256) {
      throw new Error(`SHA-256 mismatch for ${spec.name}: expected ${spec.sha256}, got ${digest}`)
    }
    writeFileSync(partPath, payload)
    renameSync(partPath, cachedPath)
    return cachedPath
  } catch (error) {
    rmSync(partPath, { force: true })
    throw error
  }
}

export function buildStikJitInfoPlist(version: string = STIKJIT_SPEC.version): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>StikJIT</string>
\t<key>CFBundleIdentifier</key>
\t<string>com.stikdebug.StikJIT</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>StikJIT</string>
\t<key>CFBundlePackageType</key>
\t<string>FMWK</string>
\t<key>CFBundleShortVersionString</key>
\t<string>${version}</string>
\t<key>CFBundleVersion</key>
\t<string>${version}</string>
\t<key>CFBundleSupportedPlatforms</key>
\t<array><string>iPhoneOS</string></array>
\t<key>MinimumOSVersion</key>
\t<string>17.4</string>
</dict>
</plist>
`
}

export function stageStikJitFramework(
  zipPath: string,
  frameworksDir: string,
  version: string = STIKJIT_SPEC.version,
): string {
  mkdirSync(frameworksDir, { recursive: true })
  const destDir = join(frameworksDir, "StikJIT.xcframework")
  rmSync(destDir, { recursive: true, force: true })

  const zipBuffer = readFileSync(zipPath)
  const entries = parseZipCentralDirectory(zipBuffer)
  let extractedCount = 0
  for (const entry of entries) {
    if (!entry.name.startsWith("StikJIT.xcframework/")) continue
    if (entry.name.includes("..")) {
      throw new Error(`Unsafe zip entry path: ${entry.name}`)
    }
    const targetPath = join(frameworksDir, entry.name)
    if (entry.name.endsWith("/")) {
      mkdirSync(targetPath, { recursive: true })
      continue
    }
    mkdirSync(dirname(targetPath), { recursive: true })
    writeFileSync(targetPath, readZipEntryData(zipBuffer, entry))
    if (entry.unixMode) {
      chmodSync(targetPath, entry.unixMode)
    }
    extractedCount += 1
  }
  if (extractedCount === 0) {
    throw new Error(`StikJIT archive ${zipPath} did not contain StikJIT.xcframework/`)
  }

  const infoPlist = join(destDir, "ios-arm64/StikJIT.framework/Info.plist")
  if (!existsSync(infoPlist)) {
    mkdirSync(dirname(infoPlist), { recursive: true })
    writeFileSync(infoPlist, buildStikJitInfoPlist(version), "utf8")
  }
  return destDir
}

/**
 * Deletes GPL-3.0 CLI entry points from an extracted RVVM source tree so only
 * the MPL-2.0 librvvm library sources remain before CMake configuration.
 */
export function purgeGplRvvmSources(rvvmSourceDir: string): string[] {
  const removed: string[] = []
  for (const rel of RVVM_EXCLUDED_GPL_SOURCES) {
    const target = join(rvvmSourceDir, rel)
    if (existsSync(target)) {
      rmSync(target, { force: true })
      removed.push(rel)
    }
  }
  for (const rel of RVVM_EXCLUDED_GPL_SOURCES) {
    if (existsSync(join(rvvmSourceDir, rel))) {
      throw new Error(`Failed to remove GPL source ${rel} from RVVM tree`)
    }
  }
  return removed
}

/**
 * Stages public MPL-2.0 headers and modulemap for Librvvm.xcframework.
 */
export function prepareLibrvvmHeaders(rvvmSourceDir: string, headersDir: string): string {
  rmSync(headersDir, { recursive: true, force: true })
  const rvvmPublicDir = join(headersDir, "rvvm")
  mkdirSync(rvvmPublicDir, { recursive: true })

  const srcIncludeDir = join(rvvmSourceDir, "include/rvvm")
  for (const file of readdirSync(srcIncludeDir)) {
    if (!file.endsWith(".h")) continue
    copyFileSync(join(srcIncludeDir, file), join(rvvmPublicDir, file))
  }

  const extraMplHeaders: readonly [string, string][] = [
    ["src/util/rvvmlib.h", "rvvmlib.h"],
    ["src/devices/chardev.h", "chardev.h"],
    ["src/devices/ns16550a.h", "ns16550a.h"],
    ["src/devices/rtl8169.h", "rtl8169.h"],
    ["src/devices/tap_api.h", "tap_api.h"],
  ]
  for (const [srcRel, dstRel] of extraMplHeaders) {
    const srcPath = join(rvvmSourceDir, srcRel)
    if (!existsSync(srcPath)) {
      throw new Error(`Missing required MPL-2.0 librvvm header: ${srcRel}`)
    }
    copyFileSync(srcPath, join(headersDir, dstRel))
  }

  writeFileSync(
    join(headersDir, "module.modulemap"),
    `module Librvvm {
    header "rvvm/rvvm.h"
    header "rvvm/rvvm_board.h"
    header "ns16550a.h"
    header "rtl8169.h"
    export *
}
`,
    "utf8",
  )
  return headersDir
}

export function buildLibrvvmXcframework(
  repoRoot: string,
  rvvmTarballPath: string,
  frameworksDir: string,
): string {
  const patchPath = join(repoRoot, "packages/capacitor-bridge/ios/rvvm/ios-jit.patch")
  if (!existsSync(patchPath)) {
    throw new Error(`Missing librvvm iOS patch: ${patchPath}`)
  }

  const workDir = mkdtempSync(join(tmpdir(), "deskfleet-librvvm-"))
  try {
    const srcRoot = join(workDir, "src")
    mkdirSync(srcRoot, { recursive: true })
    execFileSync("tar", ["-xzf", rvvmTarballPath, "-C", srcRoot, "--strip-components=1"], {
      cwd: repoRoot,
      stdio: "inherit",
    })

    // Remove GPL-3.0 CLI entry points before configuring or building anything.
    purgeGplRvvmSources(srcRoot)

    execFileSync("patch", ["-p1", "-i", patchPath], {
      cwd: srcRoot,
      stdio: "inherit",
    })

    const commonCmakeArgs = [
      "-DBUILD_STATIC_LIBS=ON",
      "-DBUILD_SHARED_LIBS=OFF",
      "-DBUILD_LIBRETRO=OFF",
      "-DUSE_GUI=OFF",
      "-DUSE_SDL=OFF",
      "-DUSE_VFIO=OFF",
      "-DUSE_TAP_LINUX=OFF",
      "-DUSE_ISOLATION=OFF",
      "-DUSE_RV32=OFF",
      "-DUSE_RV64=ON",
      "-DUSE_JIT=ON",
      "-DUSE_NET=ON",
      "-DUSE_FDT=ON",
      "-DUSE_GDBSTUB=OFF",
      "-DUSE_JNI=OFF",
      "-DCMAKE_BUILD_TYPE=Release",
      "-DCMAKE_SYSTEM_NAME=iOS",
      "-DCMAKE_OSX_ARCHITECTURES=arm64",
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0",
      "-DCMAKE_SYSTEM_PROCESSOR=aarch64",
    ]

    const slices = [
      { name: "iphoneos", sysroot: "iphoneos" },
      { name: "iphonesimulator", sysroot: "iphonesimulator" },
    ] as const

    const builtLibs: string[] = []
    for (const slice of slices) {
      const buildDir = join(workDir, `build-${slice.name}`)
      execFileSync(
        "cmake",
        [
          "-S",
          srcRoot,
          "-B",
          buildDir,
          ...commonCmakeArgs,
          `-DCMAKE_OSX_SYSROOT=${slice.sysroot}`,
          "-DCMAKE_C_FLAGS=-DRVVM_STATIC=1",
        ],
        { cwd: repoRoot, stdio: "inherit" },
      )
      execFileSync("cmake", ["--build", buildDir, "--target", "rvvm_static", "--parallel"], {
        cwd: repoRoot,
        stdio: "inherit",
      })
      const libPath = join(buildDir, "librvvm_static.a")
      if (!existsSync(libPath)) {
        throw new Error(`Expected built static library at ${libPath}`)
      }
      builtLibs.push(libPath)
    }

    const headersDir = prepareLibrvvmHeaders(srcRoot, join(workDir, "headers"))
    const xcframeworkDir = join(frameworksDir, "Librvvm.xcframework")
    mkdirSync(frameworksDir, { recursive: true })
    rmSync(xcframeworkDir, { recursive: true, force: true })

    const args = ["-create-xcframework"]
    for (const lib of builtLibs) {
      args.push("-library", lib, "-headers", headersDir)
    }
    args.push("-output", xcframeworkDir)

    execFileSync("xcodebuild", args, { cwd: repoRoot, stdio: "inherit" })
    return xcframeworkDir
  } finally {
    rmSync(workDir, { recursive: true, force: true })
  }
}

export function stageRvvmGuestFirmware(
  firmwareFiles: readonly { readonly sourcePath: string; readonly filename: string }[],
  frameworksDir: string,
): string[] {
  mkdirSync(frameworksDir, { recursive: true })
  for (const forbidden of FORBIDDEN_STAGED_ARTIFACTS) {
    rmSync(join(frameworksDir, forbidden), { recursive: true, force: true })
  }
  const guestDir = join(frameworksDir, "Guest")
  mkdirSync(guestDir, { recursive: true })
  const staged: string[] = []
  for (const item of firmwareFiles) {
    const targetPath = join(guestDir, item.filename)
    copyFileSync(item.sourcePath, targetPath)
    chmodSync(targetPath, 0o644)
    staged.push(targetPath)
  }
  return staged
}

export function buildRppairingXcframework(repoRoot: string, frameworksDir: string): string {
  const rppairingDir = join(repoRoot, "packages/capacitor-bridge/ios/rppairing")
  const rppairingTargetDir = join(repoRoot, "target/rppairing")
  const xcframeworkDir = join(frameworksDir, "IshPlusRPPairing.xcframework")
  mkdirSync(frameworksDir, { recursive: true })
  rmSync(xcframeworkDir, { recursive: true, force: true })

  execFileSync(
    "cargo",
    [
      "build",
      "--manifest-path",
      join(rppairingDir, "Cargo.toml"),
      "--target",
      "aarch64-apple-ios",
      "--release",
      "--locked",
      "--target-dir",
      rppairingTargetDir,
    ],
    {
      cwd: repoRoot,
      stdio: "inherit",
      env: {
        ...process.env,
        IPHONEOS_DEPLOYMENT_TARGET: "16.0",
      },
    },
  )

  const deviceLib = join(rppairingTargetDir, "aarch64-apple-ios/release/libishplus_rppairing.a")
  const simTemp = mkdtempSync(join(tmpdir(), "deskfleet-rppairing-sim-"))
  try {
    const simObj = join(simTemp, "simulator.o")
    const simLib = join(simTemp, "libishplus_rppairing.a")
    const headersDir = join(simTemp, "headers")
    mkdirSync(headersDir, { recursive: true })
    copyFileSync(join(rppairingDir, "include/ishplus_rppairing.h"), join(headersDir, "ishplus_rppairing.h"))
    writeFileSync(
      join(headersDir, "module.modulemap"),
      `module IshPlusRPPairing {
    header "ishplus_rppairing.h"
    export *
}
`,
      "utf8",
    )

    execFileSync(
      "xcrun",
      [
        "--sdk",
        "iphonesimulator",
        "clang",
        "-c",
        "-target",
        "arm64-apple-ios16.0-simulator",
        join(rppairingDir, "simulator.c"),
        "-o",
        simObj,
      ],
      { cwd: repoRoot, stdio: "inherit" },
    )
    execFileSync("ar", ["rcs", simLib, simObj], { cwd: repoRoot, stdio: "inherit" })

    execFileSync(
      "xcodebuild",
      [
        "-create-xcframework",
        "-library",
        deviceLib,
        "-headers",
        headersDir,
        "-library",
        simLib,
        "-headers",
        headersDir,
        "-output",
        xcframeworkDir,
      ],
      { cwd: repoRoot, stdio: "inherit" },
    )
    return xcframeworkDir
  } finally {
    rmSync(simTemp, { recursive: true, force: true })
  }
}

export function buildViewerXcframework(repoRoot: string, frameworksDir: string, release: boolean): string {
  const profile = release ? "release" : "debug"
  const targets = ["aarch64-apple-ios", "aarch64-apple-ios-sim"] as const

  const installed = execFileSync("rustup", ["target", "list", "--installed"], {
    cwd: repoRoot,
    encoding: "utf8",
  })
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)

  const missing = targets.filter(target => !installed.includes(target))
  if (missing.length > 0) {
    execFileSync("rustup", ["target", "add", ...missing], {
      cwd: repoRoot,
      stdio: "inherit",
    })
  }

  for (const target of targets) {
    execFileSync(
      "cargo",
      [
        "build",
        "-p",
        "deskfleet-desktop-viewer",
        "--lib",
        "--target",
        target,
        "--locked",
        ...(release ? ["--release"] : []),
      ],
      {
        cwd: repoRoot,
        stdio: "inherit",
        env: {
          ...process.env,
          IPHONEOS_DEPLOYMENT_TARGET: "16.0",
          ...(release
            ? {
                CARGO_PROFILE_RELEASE_DEBUG: "line-tables-only",
                CARGO_PROFILE_RELEASE_STRIP: "none",
              }
            : {}),
        },
      },
    )
  }

  const xcframeworkDir = join(frameworksDir, "DeskfleetDesktopViewerFFI.xcframework")
  mkdirSync(frameworksDir, { recursive: true })
  rmSync(xcframeworkDir, { recursive: true, force: true })

  const libraries = targets.flatMap(target => [
    "-library",
    join(repoRoot, "target", target, profile, "libdeskfleet_desktop_viewer.a"),
  ])

  execFileSync("xcodebuild", ["-create-xcframework", ...libraries, "-output", xcframeworkDir], {
    cwd: repoRoot,
    stdio: "inherit",
  })

  return xcframeworkDir
}

if (import.meta.main) {
  if (process.env.CAPACITOR_PLATFORM_NAME && process.env.CAPACITOR_PLATFORM_NAME !== "ios") {
    process.exit(0)
  }

  const repoRoot = resolve(import.meta.dirname, "..")
  const release = process.argv.includes("--release") || process.env.DESKFLEET_IOS_RELEASE === "1"
  const frameworksDir = join(repoRoot, "packages/capacitor-bridge/ios/Frameworks")
  const cacheDir = process.env.DESKFLEET_IOS_CACHE_DIR || join(repoRoot, "target/ios-rvvm-cache")

  const viewerXcframework = buildViewerXcframework(repoRoot, frameworksDir, release)
  console.log(`Staged ${viewerXcframework}`)

  const rppairingXcframework = buildRppairingXcframework(repoRoot, frameworksDir)
  console.log(`Staged ${rppairingXcframework}`)

  const rvvmTarball = await downloadCachedArtifact(RVVM_SOURCE_SPEC, cacheDir)
  const librvvmXcframework = buildLibrvvmXcframework(repoRoot, rvvmTarball, frameworksDir)
  console.log(`Staged ${librvvmXcframework}`)

  const stikJitZip = await downloadCachedArtifact(STIKJIT_SPEC, cacheDir)
  const stikJitXcframework = stageStikJitFramework(stikJitZip, frameworksDir)
  console.log(`Staged ${stikJitXcframework}`)

  const fwPayload = await downloadCachedArtifact(RVVM_FW_PAYLOAD_SPEC, cacheDir)
  const fwJump = await downloadCachedArtifact(RVVM_FW_JUMP_SPEC, cacheDir)
  const stagedFirmware = stageRvvmGuestFirmware(
    [
      { sourcePath: fwPayload, filename: RVVM_FW_PAYLOAD_SPEC.filename },
      { sourcePath: fwJump, filename: RVVM_FW_JUMP_SPEC.filename },
    ],
    frameworksDir,
  )
  console.log(`Staged ${stagedFirmware.length} RISC-V guest firmware images into ${frameworksDir}/Guest`)
}
