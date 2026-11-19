import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import {
  buildAndroidViewerEnv,
  buildEmbeddedRootfsDockerfile,
  extractDebMember,
  findNdkRoot,
  MIN_ANDROID_API,
  MIN_NDK_MAJOR,
  patchCStringInPlace,
  verifyElfLoadAlignment,
} from "./build-android-viewer.ts"

function writeNdk(sdkDir: string, folder: string, revision: string): string {
  const dir = join(sdkDir, "ndk", folder)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, "source.properties"), `Pkg.Desc = Android NDK\nPkg.Revision = ${revision}\n`)
  return dir
}

test("findNdkRoot ignores runner NDKs older than r28 and prefers newest stable r28+", context => {
  const root = mkdtempSync(join(tmpdir(), "deskfleet-android-ndk-"))
  context.after(() => rmSync(root, { recursive: true, force: true }))
  const sdk = join(root, "sdk")
  const laterSdk = join(root, "later-sdk")
  const emptyHome = join(root, "empty-home")
  mkdirSync(emptyHome, { recursive: true })
  const r27 = writeNdk(sdk, "27.2.12479018", "27.2.12479018")
  writeNdk(sdk, "28.1.13356709", "28.1.13356709")
  const r29 = writeNdk(sdk, "29.0.14206865", "29.0.14206865")
  writeNdk(sdk, "30.0.14904198", "30.0.14904198-beta1")
  // A newer NDK under ANDROID_SDK_ROOT must not override ANDROID_HOME.
  writeNdk(laterSdk, "30.0.16248370", "30.0.16248370")

  assert.equal(MIN_ANDROID_API, 34)
  assert.equal(MIN_NDK_MAJOR, 28)
  assert.equal(
    findNdkRoot({ ANDROID_NDK_HOME: r27, ANDROID_HOME: sdk, ANDROID_SDK_ROOT: laterSdk }, emptyHome),
    r29,
  )
  assert.throws(
    () => findNdkRoot({ ANDROID_NDK_HOME: r27, ANDROID_HOME: join(root, "missing-sdk") }, emptyHome),
    /NDK r28 or newer/,
  )
})

test("buildAndroidViewerEnv enforces 16 KB page alignment, Android 14 API, and release debug symbols", () => {
  const releaseEnv = buildAndroidViewerEnv(
    { CARGO_PROFILE_RELEASE_DEBUG: "0", CARGO_PROFILE_RELEASE_STRIP: "symbols" },
    "/sdk/ndk/28.2.13676358",
    "/sdk/ndk/28.2.13676358/bin",
    "/sdk/ndk/28.2.13676358/bin/aarch64-linux-android34-clang",
    true,
  )
  assert.equal(releaseEnv.ANDROID_PLATFORM, "android-34")
  assert.match(releaseEnv.CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS ?? "", /max-page-size=16384/)
  assert.equal(releaseEnv.CARGO_PROFILE_RELEASE_DEBUG, "line-tables-only")
  assert.equal(releaseEnv.CARGO_PROFILE_RELEASE_STRIP, "none")

  const debugEnv = buildAndroidViewerEnv(
    { RUSTFLAGS: "-D warnings" },
    "/sdk/ndk/28.2.13676358",
    "/sdk/ndk/28.2.13676358/bin",
    "/sdk/ndk/28.2.13676358/bin/aarch64-linux-android34-clang",
    false,
  )
  assert.equal(
    debugEnv.CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS,
    "-D warnings -C link-arg=-Wl,-z,max-page-size=16384",
  )
})

test("verifyElfLoadAlignment accepts 16 KB segments and rejects 4 KB segments", () => {
  verifyElfLoadAlignment(
    [
      "  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align",
      "  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x012bdc 0x012bdc R   0x4000",
      "  LOAD           0x012bdc 0x0000000000016bdc 0x0000000000016bdc 0x0357f4 0x0357f4 R E 0x4000",
    ].join("\n"),
    "libdeskfleet_desktop_viewer.so",
  )
  assert.throws(
    () =>
      verifyElfLoadAlignment(
        "  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x0135b4 0x0135b4 R   0x1000\n",
        "libdeskfleet_desktop_viewer.so",
      ),
    /0x1000.*16 KB/,
  )
})

test("patchCStringInPlace replaces exact null-terminated strings without shifting length", () => {
  const input = Buffer.concat([
    Buffer.from("prefix\0"),
    Buffer.from("/data/data/com.termux/files/usr/lib\0"),
    Buffer.from("/data/data/com.termux/files/usr/libexec/proot/loader\0"),
  ])
  const patched = patchCStringInPlace(input, "/data/data/com.termux/files/usr/lib", "$ORIGIN")
  assert.equal(patched.length, input.length)
  assert.ok(patched.includes(Buffer.from("$ORIGIN\0")))
  // Longer paths sharing the prefix must remain untouched.
  assert.ok(patched.includes(Buffer.from("/data/data/com.termux/files/usr/libexec/proot/loader\0")))
  assert.throws(() => patchCStringInPlace(input, "short", "way-too-long"), /does not fit/)
  assert.throws(() => patchCStringInPlace(input, "missing", "x"), /was not found/)
})

test("extractDebMember extracts a member from an ar archive with even padding", () => {
  function arEntry(name: string, payload: Buffer): Buffer {
    const header = Buffer.alloc(60, 0x20)
    header.write(`${name}/`, 0, "ascii")
    header.write("0", 16, "ascii")
    header.write("0", 28, "ascii")
    header.write("0", 34, "ascii")
    header.write("100644", 40, "ascii")
    header.write(String(payload.length), 48, "ascii")
    header.write("`\n", 58, "ascii")
    return payload.length % 2 === 1 ? Buffer.concat([header, payload, Buffer.from("\n")]) : Buffer.concat([header, payload])
  }
  const deb = Buffer.concat([
    Buffer.from("!<arch>\n"),
    arEntry("debian-binary", Buffer.from("2.0\n")),
    arEntry("odd", Buffer.from("abc")),
    arEntry("data.tar.xz", Buffer.from("xz-bytes")),
  ])
  assert.deepEqual(extractDebMember(deb, "data.tar.xz"), Buffer.from("xz-bytes"))
  assert.deepEqual(extractDebMember(deb, "odd"), Buffer.from("abc"))
  assert.throws(() => extractDebMember(deb, "missing"), /missing/)
})

test("buildEmbeddedRootfsDockerfile installs deps, daemon, scrcpy, and converts hardlinks", () => {
  const dockerfile = buildEmbeddedRootfsDockerfile()
  assert.match(dockerfile, /FROM --platform=linux\/arm64 ubuntu:24\.04/)
  assert.match(dockerfile, /\bca-certificates\b/)
  assert.match(dockerfile, /\bgit\b/)
  assert.match(dockerfile, /\bcurl\b/)
  assert.match(dockerfile, /\badb\b/)
  assert.match(dockerfile, /deskfleet-daemon/)
  assert.match(dockerfile, /scrcpy-server\.jar/)
  assert.match(dockerfile, /rm -f \/opt\/deskfleet\/deskfleet-server/)
  assert.match(dockerfile, /ln -rsf/)
})
