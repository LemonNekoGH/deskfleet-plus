import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { basename, join, resolve } from "node:path"

export const MIN_ANDROID_API = 34
export const MIN_NDK_MAJOR = 28
const PAGE_SIZE_16KB = 0x4000

export interface TermuxPackageSpec {
  readonly name: string
  readonly url: string
  readonly sha256: string
}

export const TERMUX_PROOT_PACKAGES: readonly TermuxPackageSpec[] = [
  {
    name: "proot",
    url: "https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.102_aarch64.deb",
    sha256: "10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030",
  },
  {
    name: "libtalloc",
    url: "https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_2.5.0_aarch64.deb",
    sha256: "556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7",
  },
  {
    name: "libandroid-shmem",
    url: "https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb",
    sha256: "0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6",
  },
]

export interface NdkRevision {
  path: string
  revision: string
  prerelease: boolean
  numbers: [number, number, number]
}

export function parseNdkRevision(ndkPath: string): NdkRevision | null {
  if (!existsSync(ndkPath)) return null
  const sourceProps = join(ndkPath, "source.properties")
  let revision = basename(ndkPath)
  if (existsSync(sourceProps)) {
    const match = readFileSync(sourceProps, "utf8").match(/^\s*Pkg\.Revision\s*=\s*(.+?)\s*$/mu)
    if (match?.[1]) revision = match[1]
  }
  const [base, suffix] = revision.split("-", 2)
  const parts = (base ?? "").split(".")
  if (parts.length < 1 || !parts.every(part => /^\d+$/u.test(part))) return null
  const major = Number(parts[0])
  const minor = Number(parts[1] ?? 0)
  const build = Number(parts[2] ?? 0)
  if (major < MIN_NDK_MAJOR) return null
  return { path: ndkPath, revision, prerelease: Boolean(suffix), numbers: [major, minor, build] }
}

function compareNdkRevisions(a: NdkRevision, b: NdkRevision): number {
  if (a.prerelease !== b.prerelease) return a.prerelease ? 1 : -1
  for (let i = 0; i < 3; i++) {
    if (a.numbers[i] !== b.numbers[i]) return b.numbers[i]! - a.numbers[i]!
  }
  return 0
}

export function findNdkRoot(env: NodeJS.ProcessEnv = process.env, home: string = homedir()): string {
  for (const key of ["ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "NDK_HOME", "ANDROID_NDK_LATEST_HOME"]) {
    const candidate = env[key]
    if (candidate && parseNdkRevision(candidate)) return candidate
  }
  // When ANDROID_HOME / ANDROID_SDK_ROOT are set, search only those roots.
  // Merging in later defaults (for example /usr/local/lib/android/sdk on
  // GitHub-hosted runners) can override an explicit SDK with a newer NDK.
  const explicitSdks = [env.ANDROID_HOME, env.ANDROID_SDK_ROOT].filter((v): v is string => Boolean(v))
  const sdks = [
    ...new Set(
      explicitSdks.length > 0
        ? explicitSdks
        : [join(home, "Library/Android/sdk"), join(home, "Android/Sdk"), "/usr/local/lib/android/sdk"],
    ),
  ]

  for (const sdk of sdks) {
    const ndkDir = join(sdk, "ndk")
    if (!existsSync(ndkDir)) continue
    const installed: NdkRevision[] = []
    for (const entry of readdirSync(ndkDir)) {
      if (entry.startsWith(".")) continue
      const parsed = parseNdkRevision(join(ndkDir, entry))
      if (parsed) installed.push(parsed)
    }
    installed.sort(compareNdkRevisions)
    if (installed[0]) return installed[0].path
  }
  throw new Error(`Could not locate Android NDK r${MIN_NDK_MAJOR} or newer. Install NDK ${MIN_NDK_MAJOR}+ under Android SDK or set ANDROID_NDK_HOME.`)
}

export function buildAndroidViewerEnv(
  baseEnv: NodeJS.ProcessEnv,
  ndkRoot: string,
  binDir: string,
  clang: string,
  release: boolean,
): NodeJS.ProcessEnv {
  const existingRustflags = baseEnv.CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS ?? baseEnv.RUSTFLAGS ?? ""
  const pageSizeFlag = `-C link-arg=-Wl,-z,max-page-size=${PAGE_SIZE_16KB}`
  const rustflags = existingRustflags ? `${existingRustflags} ${pageSizeFlag}` : pageSizeFlag
  const exe = process.platform === "win32" ? ".exe" : ""
  return {
    ...baseEnv,
    ANDROID_NDK_HOME: ndkRoot,
    ANDROID_NDK_ROOT: ndkRoot,
    CC_aarch64_linux_android: clang,
    CXX_aarch64_linux_android: `${clang}++`,
    AR_aarch64_linux_android: join(binDir, `llvm-ar${exe}`),
    CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER: clang,
    CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS: rustflags,
    CMAKE_TOOLCHAIN_FILE_aarch64_linux_android: join(ndkRoot, "build/cmake/android.toolchain.cmake"),
    CMAKE_ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES: "ON",
    ANDROID_ABI: "arm64-v8a",
    ANDROID_PLATFORM: `android-${MIN_ANDROID_API}`,
    ...(release
      ? {
          // Retain DWARF line tables and ELF symbols in the staged .so so AGP
          // packages Play Console debug symbols while stripping the shipped APK.
          CARGO_PROFILE_RELEASE_DEBUG: "line-tables-only",
          CARGO_PROFILE_RELEASE_STRIP: "none",
        }
      : {}),
  }
}

export function verifyElfLoadAlignment(readelfOutput: string, soPath: string): void {
  const alignments = [...readelfOutput.matchAll(/^\s*LOAD\s+.+\s+(0x[0-9a-fA-F]+)\s*$/gmu)]
    .map(match => Number.parseInt(match[1]!, 16))
  if (alignments.length === 0) {
    throw new Error(`No ELF LOAD segments found in ${soPath}`)
  }
  const unaligned = alignments.find(align => align < PAGE_SIZE_16KB)
  if (unaligned !== undefined) {
    throw new Error(`${soPath} has LOAD segment alignment 0x${unaligned.toString(16)}; Google Play requires at least 0x${PAGE_SIZE_16KB.toString(16)} (16 KB)`)
  }
}

/** Extract an entry from an ar (.deb) archive without shelling out to platform-specific ar/tar tools. */
export function extractDebMember(debBuffer: Buffer, memberName: string): Buffer {
  const magic = "!<arch>\n"
  if (debBuffer.subarray(0, magic.length).toString("ascii") !== magic) {
    throw new Error("Invalid deb archive: missing ar magic header")
  }
  let offset = magic.length
  while (offset + 60 <= debBuffer.length) {
    const header = debBuffer.subarray(offset, offset + 60)
    if (header.subarray(58, 60).toString("ascii") !== "`\n") {
      throw new Error(`Invalid ar member header at offset ${offset}`)
    }
    const rawName = header.subarray(0, 16).toString("ascii").trim()
    const name = rawName.endsWith("/") ? rawName.slice(0, -1) : rawName
    const size = Number.parseInt(header.subarray(48, 58).toString("ascii").trim(), 10)
    if (!Number.isFinite(size) || size < 0) {
      throw new Error(`Invalid ar member size for ${name}`)
    }
    const dataStart = offset + 60
    const dataEnd = dataStart + size
    if (dataEnd > debBuffer.length) {
      throw new Error(`Truncated ar member ${name}`)
    }
    if (name === memberName) {
      return Buffer.from(debBuffer.subarray(dataStart, dataEnd))
    }
    offset = dataEnd + (size % 2)
  }
  throw new Error(`Deb archive is missing ${memberName}`)
}

/** Replace a null-terminated ELF string in place and zero-pad the remainder so offsets never shift. */
export function patchCStringInPlace(buffer: Buffer, from: string, to: string): Buffer {
  const needle = Buffer.from(`${from}\0`, "utf8")
  const replacement = Buffer.from(to, "utf8")
  if (replacement.length >= needle.length) {
    throw new Error(`Replacement "${to}" does not fit in "${from}"`)
  }
  const patched = Buffer.from(buffer)
  let count = 0
  let index = 0
  while ((index = patched.indexOf(needle, index)) !== -1) {
    replacement.copy(patched, index)
    patched.fill(0, index + replacement.length, index + needle.length)
    count += 1
    index += needle.length
  }
  if (count === 0) {
    throw new Error(`Expected ELF string "${from}" was not found`)
  }
  return patched
}

export async function stageTermuxProotBinaries(
  outDir: string,
  readelfBin: string,
  packages: readonly TermuxPackageSpec[] = TERMUX_PROOT_PACKAGES,
): Promise<string[]> {
  mkdirSync(outDir, { recursive: true })
  const tempRoot = mkdtempSync(join(tmpdir(), "deskfleet-proot-"))
  try {
    const extractedDirs = new Map<string, string>()
    for (const pkg of packages) {
      const response = await fetch(pkg.url)
      if (!response.ok) {
        throw new Error(`Failed to download ${pkg.url}: HTTP ${response.status}`)
      }
      const debBuffer = Buffer.from(await response.arrayBuffer())
      const digest = createHash("sha256").update(debBuffer).digest("hex")
      if (digest !== pkg.sha256) {
        throw new Error(`SHA-256 mismatch for ${pkg.name}: expected ${pkg.sha256}, got ${digest}`)
      }
      const dataTarXz = extractDebMember(debBuffer, "data.tar.xz")
      const archivePath = join(tempRoot, `${pkg.name}-data.tar.xz`)
      const extractDir = join(tempRoot, pkg.name)
      mkdirSync(extractDir, { recursive: true })
      writeFileSync(archivePath, dataTarXz)
      execFileSync("tar", ["-xf", archivePath, "-C", extractDir], { stdio: "inherit" })
      extractedDirs.set(pkg.name, extractDir)
    }

    const termuxPrefix = "data/data/com.termux/files/usr"
    const prootRoot = extractedDirs.get("proot")!
    const tallocRoot = extractedDirs.get("libtalloc")!
    const shmemRoot = extractedDirs.get("libandroid-shmem")!

    let prootBin: Buffer = readFileSync(join(prootRoot, termuxPrefix, "bin/proot"))
    prootBin = patchCStringInPlace(prootBin, "libtalloc.so.2", "libtalloc.so")
    prootBin = patchCStringInPlace(prootBin, "/data/data/com.termux/files/usr/lib", "$ORIGIN")

    const loaderBin = readFileSync(join(prootRoot, termuxPrefix, "libexec/proot/loader"))

    let tallocBin: Buffer = readFileSync(join(tallocRoot, termuxPrefix, "lib/libtalloc.so.2.5.0"))
    tallocBin = patchCStringInPlace(tallocBin, "libtalloc.so.2", "libtalloc.so")
    tallocBin = patchCStringInPlace(tallocBin, "/data/data/com.termux/files/usr/lib", "$ORIGIN")

    let shmemBin: Buffer = readFileSync(join(shmemRoot, termuxPrefix, "lib/libandroid-shmem.so"))
    shmemBin = patchCStringInPlace(shmemBin, "/data/data/com.termux/files/usr/lib", "$ORIGIN")
    shmemBin = patchCStringInPlace(shmemBin, "/data/data/com.termux/files/usr/tmp/ashv_key_%d", "./ashv_key_%d")

    const staged: string[] = []
    const files: readonly [string, Buffer, number][] = [
      ["libproot.so", prootBin, 0o755],
      ["libproot_loader.so", loaderBin, 0o755],
      ["libtalloc.so", tallocBin, 0o644],
      ["libandroid-shmem.so", shmemBin, 0o644],
    ]
    for (const [filename, content, mode] of files) {
      const targetPath = join(outDir, filename)
      writeFileSync(targetPath, content)
      chmodSync(targetPath, mode)
      const readelfOutput = execFileSync(readelfBin, ["-l", targetPath], { encoding: "utf8" })
      verifyElfLoadAlignment(readelfOutput, targetPath)
      staged.push(targetPath)
    }
    return staged
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  if (process.env.CAPACITOR_PLATFORM_NAME && process.env.CAPACITOR_PLATFORM_NAME !== "android") {
    process.exit(0)
  }

  const repoRoot = resolve(import.meta.dirname, "..")
  const release = process.argv.includes("--release") || process.env.DESKFLEET_ANDROID_RELEASE === "1"
  const ndkRoot = findNdkRoot()
  const prebuiltDir = join(ndkRoot, "toolchains/llvm/prebuilt")
  const host = readdirSync(prebuiltDir).find(n => !n.startsWith("."))
  if (!host) throw new Error(`No LLVM prebuilt toolchain found under ${prebuiltDir}`)
  const binDir = join(prebuiltDir, host, "bin")
  const cmdExt = process.platform === "win32" ? ".cmd" : ""
  const exeExt = process.platform === "win32" ? ".exe" : ""
  const clang = join(binDir, `aarch64-linux-android${MIN_ANDROID_API}-clang${cmdExt}`)
  if (!existsSync(clang)) {
    throw new Error(`Missing Android API ${MIN_ANDROID_API} clang wrapper at ${clang}`)
  }

  execFileSync(
    "cargo",
    ["build", "-p", "deskfleet-desktop-viewer", "--lib", "--target", "aarch64-linux-android", "--locked", ...(release ? ["--release"] : [])],
    {
      cwd: repoRoot,
      stdio: "inherit",
      env: buildAndroidViewerEnv(process.env, ndkRoot, binDir, clang, release),
    },
  )

  const readelfBin = join(binDir, `llvm-readelf${exeExt}`)
  const builtSo = join(repoRoot, "target/aarch64-linux-android", release ? "release" : "debug", "libdeskfleet_desktop_viewer.so")
  const readelfOutput = execFileSync(readelfBin, ["-l", builtSo], { encoding: "utf8" })
  verifyElfLoadAlignment(readelfOutput, builtSo)

  const outDir = join(repoRoot, "packages/capacitor-bridge/android/src/main/jniLibs/arm64-v8a")
  mkdirSync(outDir, { recursive: true })
  const targetSo = join(outDir, "libdeskfleet_desktop_viewer.so")
  copyFileSync(builtSo, targetSo)
  const prootFiles = await stageTermuxProotBinaries(outDir, readelfBin)
  console.log(`Staged ${targetSo} and ${prootFiles.length} proot binaries (NDK ${basename(ndkRoot)}, API ${MIN_ANDROID_API}, 16 KB aligned)`)

  const assetsDir = join(repoRoot, "packages/capacitor-bridge/android/src/main/assets")
  mkdirSync(assetsDir, { recursive: true })
  // Embedded daemon and scrcpy assets are generated by Gradle when assembling an APK/AAB,
  // not during Capacitor sync. Clean up legacy staged copies to avoid duplicate asset merges.
  for (const staleAsset of [
    "ubuntu-rootfs.tar.gz",
    "debian-rootfs.tar.gz",
    "deskfleet-daemon-linux-arm64.tar.gz",
    "deskfleet-daemon-linux-arm64.tgz",
    "scrcpy-server.jar",
  ]) {
    rmSync(join(assetsDir, staleAsset), { force: true })
  }
  const noticesSource = join(repoRoot, "THIRD_PARTY_NOTICES.md")
  if (existsSync(noticesSource)) {
    copyFileSync(noticesSource, join(assetsDir, "THIRD_PARTY_NOTICES.md"))
  }
}
