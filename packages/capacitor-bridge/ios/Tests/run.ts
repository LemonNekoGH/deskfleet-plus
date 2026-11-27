import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"

// Test production Foundation helpers without Capacitor, UIKit or viewer builds.
const workspace = mkdtempSync(join(tmpdir(), "deskfleet-ios-files-tests-"))
try {
  mkdirSync(join(workspace, "Sources", "DeskFleetLocalFiles"), { recursive: true })
  mkdirSync(join(workspace, "Tests", "DeskFleetLocalFilesTests"), { recursive: true })
  copyFileSync(new URL("../Sources/DeskFleetBridge/LocalFilesEndpoint.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "LocalFilesEndpoint.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/FirebaseTelemetryBridge.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "FirebaseTelemetryBridge.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/RemoteDesktopModifiers.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "RemoteDesktopModifiers.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/RemoteDesktopInputState.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "RemoteDesktopInputState.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/RemoteDesktopControlState.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "RemoteDesktopControlState.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/RvvmDaemonCommands.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "RvvmDaemonCommands.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/RvvmJitRouting.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "RvvmJitRouting.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/RvvmLocalDaemonLifecycle.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "RvvmLocalDaemonLifecycle.swift"))
  copyFileSync(new URL("../Sources/DeskFleetBridge/IosScreenShareShared.swift", import.meta.url), join(workspace, "Sources", "DeskFleetLocalFiles", "IosScreenShareShared.swift"))
  copyFileSync(new URL("./LocalFilesEndpointTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "LocalFilesEndpointTests.swift"))
  copyFileSync(new URL("./RemoteDesktopModifiersTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "RemoteDesktopModifiersTests.swift"))
  copyFileSync(new URL("./RemoteDesktopInputStateTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "RemoteDesktopInputStateTests.swift"))
  copyFileSync(new URL("./RemoteDesktopControlStateTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "RemoteDesktopControlStateTests.swift"))
  copyFileSync(new URL("./RvvmDaemonCommandsTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "RvvmDaemonCommandsTests.swift"))
  copyFileSync(new URL("./RvvmJitRoutingTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "RvvmJitRoutingTests.swift"))
  copyFileSync(new URL("./RvvmLocalDaemonLifecycleTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "RvvmLocalDaemonLifecycleTests.swift"))
  copyFileSync(new URL("./IosScreenShareTests.swift", import.meta.url), join(workspace, "Tests", "DeskFleetLocalFilesTests", "IosScreenShareTests.swift"))
  writeFileSync(join(workspace, "Package.swift"), `// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DeskFleetLocalFiles", platforms: [.macOS(.v13)], targets: [
  .target(name: "DeskFleetLocalFiles"),
  .testTarget(name: "DeskFleetLocalFilesTests", dependencies: ["DeskFleetLocalFiles"])
])
`)
  const result = spawnSync("swift", ["test", "--disable-sandbox", "--package-path", workspace, "--cache-path", join(workspace, "cache"), "--config-path", join(workspace, "config"), "--security-path", join(workspace, "security"), ...process.argv.slice(2)], {
    stdio: "inherit",
    env: { ...process.env, CLANG_MODULE_CACHE_PATH: join(workspace, "module-cache") },
  })
  if (result.error) throw result.error
  process.exitCode = result.status ?? 1
} finally {
  rmSync(workspace, { recursive: true, force: true })
}
