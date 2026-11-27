# DeskFleet Plus Architecture & Fork Guide

`LemonNekoGH/deskfleet-plus` (**DeskFleet Plus**, application/bundle ID `moe.remon.deskfleet.plus`,
App Group `group.moe.remon.deskfleet.plus`) is an unofficial, mobile-focused fork of
[`yet-another-ai/deskfleet`](https://github.com/yet-another-ai/deskfleet) (`ai.yetanother.deskfleet`).

Its single architectural goal is to let **Android and iOS devices run a full Linux `deskfleet-daemon`
inside the mobile app sandbox**, turning phones and tablets into self-contained DeskFleet machines
without root access, external Termux setup, or a separate desktop host.

## Boundary with Upstream

- **Stay aligned with upstream**: `apps/server`, `apps/desktop`, `crates/*`, `packages/protocol`,
  and core `apps/daemon` behavior should track `upstream/main` without diverging.
- **Fork-owned surface**:
  - **Android embedded runtime**: Unprivileged `proot` + Debian 13 (`trixie`) `arm64` sandbox
    (`ProotDaemonManager.kt`), foreground wake-lock supervisor (`LocalDaemonService.kt`),
    bundled `deskfleet-daemon` (fetched from upstream `linux-arm64` releases at Gradle build time)
    and `scrcpy-server.jar` (`packages/capacitor-bridge/android/build.gradle.kts`,
    `scripts/build-android-viewer.ts`).
  - **Android Wireless ADB**: mDNS pairing discovery, notification pairing-code input, TLS
    reconnection, optional `tcpip 5555` keep-alive, and daemon capability refresh
    (`WirelessAdbManager.kt`, `WirelessAdbController.kt`, `packages/client/src/wireless-adb.ts`,
    `packages/components/src/components/settings/AndroidWirelessAdbSettings.vue`).
  - **iOS embedded runtime**: Pure-JIT `librvvm` RISC-V 64 Linux guest with iOS W^X RVJIT,
    RAM-donor hooks, and host-loopback TCP routing (`192.168.0.254` → host `127.0.0.1`)
    (`packages/capacitor-bridge/ios/rvvm/ios-jit.patch`, `RvvmHostBridge.c`,
    `RvvmDaemonManager.swift`, `RvvmDaemonCommands.swift`), UART1 framed command channel,
    host DNS/proxy/clock sync, `DeskFleetJITHelper.appex` (`StikJIT.xcframework` + `xpc_shmem`
    RAM donation via `RvvmRamDonor.m` / `HelperPrincipal.m`), iOS 27+ on-device RemotePairing
    and CoreDevice screen/HID/pasteboard streaming (`packages/capacitor-bridge/ios/rppairing/`,
    `RvvmOnDevicePairing.swift`), ReplayKit VideoToolbox fallback inside `BroadcastUpload.appex`
    (coexisting with `OutlineAudioSharedStore`), iOS host screen bridge and hardware VideoToolbox
    transcoding (`IosScreenShareShared.swift`, `IosScreenBridgeServer.swift`,
    `IosCoreDeviceSessionManager.swift`, `IosCoreDeviceVideoPipeline.swift`), guest native backend
    (`crates/native/src/ios_screen.rs`), silent-audio background keep-alive
    (`RvvmBackgroundKeepAlive.swift`), and pre-baked Ubuntu 24.04 `riscv64` guest images
    (`scripts/build-ios-riscv64-guest.ts`).
  - **`linux/riscv64` + Box64 agent compatibility**: `packages/agents/antigravity/src/index.ts`
    (Box64 check, `install.sh` arch patch, `GODEBUG=asyncpreemptoff=1`, `linux_amd64` manifest,
    relaxed timeouts) and `packages/agents/core/src/acp.ts` (90 s ACP init timeout on `riscv64`).
  - **Shared mobile bridge & UI**: `packages/capacitor-bridge/src/local-daemon.ts` attaches
    `central.localEnrollment`, `central.enrollLocal`, `central.onLocalEnrollmentOutput`, and
    CLI-backed `localDaemonSettings` (`deskfleet-daemon settings get/set`) so mobile clients
    show live enrollment logs in `AddMachineDialog.vue` and expose `RemoteAgentSettings` and
    `WorktreeSettings` in Settings when a local daemon is active.
  - **Mobile defaults & identity**: Separate package/bundle ID (`moe.remon.deskfleet.plus`) so
    DeskFleet Plus installs alongside the official app; native mobile builds default to
    `https://deskfleet.yetanother.ai` when `VITE_DESKFLEET_SERVER_URL` is unset.

## Mobile-Only CI & Release Scope

Unlike upstream, this fork does not build or publish desktop installers, Linux distribution
packages, Nix bundles, AUR recipes, container images, Google Play uploads, or TestFlight uploads:

- `.github/workflows/ci.yml`: Runs `changes` → `test` (`preflight`, `android`, `ios`) and
  `build` (`android`, `ios`) → `gate` → `prune_caches`.
- `.github/workflows/test.yml`: Keeps `preflight` (`mise run ci:preflight`), `android`
  (`mise run android:test`), and `ios` (`mise run ios:test`).
- `.github/workflows/build.yml`: Keeps only `android` (`Build (android-arm64)`) and `ios`
  (`Build (ios-arm64)`).
- `.github/workflows/publish.yml`: Validates `v*` tags against package versions and verifies
  via `scripts/check-upstream-release.ts --require-tag` that upstream's matching release
  already contains `deskfleet-linux-arm64.tar.gz`, runs mobile `test` and `build`, invokes
  `ios-guest-riscv64.yml` on formal stable tags (`prerelease != 'true'`) to refresh the live
  `ios-guest-riscv64` guest image, and creates/updates a draft GitHub Release with
  `deskfleet-<version>-android-arm64.apk` and `deskfleet-<version>-ios-arm64.ipa` (unsigned
  sideloadable IPA by default when Apple signing secrets are absent, or signed IPA when
  configured).
- `.github/workflows/ios-guest-riscv64.yml`: Builds and publishes the pre-baked Ubuntu 24.04
  `riscv64` guest image (`deskfleet-riscv64.img.gz`) to the `ios-guest-riscv64` release tag
  (triggered on guest builder edits, manual dispatch, or `workflow_call` from `publish.yml`).

## Upstream-Aligned Release Cadence

DeskFleet Plus follows upstream's formal release schedule: whenever `yet-another-ai/deskfleet`
publishes a new stable release `vX.Y.Z`, DeskFleet Plus syncs up to `vX.Y.Z` and cuts a matching
stable release `vX.Y.Z`.

### Detecting and cutting a synced release

1. **Check upstream readiness** (suitable for scheduled Agent tasks or manual checks):
   ```sh
   node scripts/check-upstream-release.ts --check-latest
   ```
   Proceed with a synced release only when `readyToRelease` is `true` (upstream published a
   newer stable tag `vX.Y.Z` **and** `deskfleet-linux-arm64.tar.gz` is attached, which Android
   Gradle packaging downloads at build time).
2. **Merge the upstream release tag** into `main` (e.g., `git fetch upstream --tags && git merge vX.Y.Z`),
   following the merge exclusions below so `package.json`, `apps/desktop/package.json`,
   `apps/web/package.json`, and `Cargo.toml` advance cleanly to `X.Y.Z`.
3. **Run post-merge verification** (see below) and push `main` plus the matching tag `vX.Y.Z`.
4. **`publish.yml` takes over**:
   - Validates `vX.Y.Z` against workspace manifests and verifies upstream's `deskfleet-linux-arm64.tar.gz`.
   - Runs `test.yml` (`preflight`, `android`, `ios`) and `build.yml` (`android`, `ios`).
   - Refreshes the `ios-guest-riscv64` release image via `ios-guest-riscv64.yml` (skipped for prereleases).
   - Creates a **Draft GitHub Release** (`DeskFleet Plus vX.Y.Z`) for review before publishing.
5. **Write the Release Changelog before publishing** (whether edited manually or by an Agent with `gh release edit vX.Y.Z`):
   Structure the GitHub Release body using two top-level headings to separate fork changes from upstream changes:
   ```markdown
   # DeskFleet Plus

   - <DeskFleet Plus mobile changes since the previous fork release>

   # Upstream

   - <Upstream DeskFleet changes included in vX.Y.Z, with link to https://github.com/yet-another-ai/deskfleet/releases/tag/vX.Y.Z>
   ```

## Upstream Merge Policy & Conflict Playbook

Always **merge** `upstream/main` (`git merge upstream/main`) rather than rebasing published fork
history. Use the four buckets below to decide what to drop, keep, or accept from upstream:

### 1. Never restore (always keep deleted)

If `git merge upstream/main` resurrects these files or triggers modify/delete conflicts, keep them
deleted (`git rm`):

- `.github/workflows/nix.yml`
- `.github/workflows/nix-server.yml`
- `.github/workflows/aur.yml`
- `.github/workflows/aur-publish.yml`
- `.github/workflows/linux-packages.yml`
- Any **new** upstream workflow added solely for desktop installers, Linux DEB/RPM/Nix/AUR
  packaging, Docker/GHCR server or Super Agent images, Google Play, TestFlight, or GitHub Pages.

### 2. Do not overwrite with upstream (keep fork-owned; port mobile fixes selectively)

- **`README.md`**: Always keep DeskFleet Plus's mobile-focused README (`git checkout --ours README.md`).
  Do not merge upstream desktop install tips, badges, feature lists, or contributor walls back in.
- **`.github/workflows/ci.yml`, `test.yml`, `build.yml`, `publish.yml`**:
  - **Drop** upstream changes to non-mobile jobs: `package` (Electron/server/Docker/Super Agent),
    `static`, `checks` (desktop/Electron tests), `backend`, `nix*`, `aur*`, `linux_packages`,
    `deploy-pages`, `image`, `super_agent_image`, `google_play`, and `testflight`.
  - **Port selectively** upstream improvements to shared infrastructure or mobile steps:
    `actions/checkout`, `setup-build`, `setup-gradle-mirror`, `changes` classifier, `prune_caches`,
    Android SDK/Gradle/signing steps, pinned Xcode version, and iOS archive/signing steps.
- **Workflow contract tests in `scripts/`**:
  - `scripts/ci-docs-only.test.ts`
  - `scripts/ci-ios-release.test.ts`
  - `scripts/ci-release-build.test.ts`
  - `scripts/home-downloads.test.ts`
  - `scripts/package-linux-release.test.ts`
  - `scripts/package-nix-release.test.ts`
  - Keep mobile-only workflow assertions; do **not** pull back assertions that expect deleted
    desktop/Nix/DEB/RPM/TestFlight/Google Play/Pages jobs. Keep all non-workflow logic tests from
    upstream.

### 3. Merge carefully (preserve fork identity and mobile runtime)

Accept upstream bug fixes and refactors in these files, while preserving DeskFleet Plus's
fork-specific behavior:

- **App / Bundle / App Group identity** (`moe.remon.deskfleet.plus`,
  `group.moe.remon.deskfleet.plus`, `DeskFleet Plus`):
  - `apps/web/capacitor.config.ts`
  - `apps/web/android/app/build.gradle.kts` (also keep `noCompress`, `useLegacyPackaging = true`),
    `apps/web/android/app/src/main/AndroidManifest.xml` (`extractNativeLibs="true"`),
    `apps/web/android/app/src/main/res/values/strings.xml`
  - `apps/web/ios/App/App.xcodeproj/project.pbxproj`, `App/Info.plist`, `App/App.entitlements`,
    `BroadcastUpload/*`, `DeskFleetJITHelper/*`
  - `packages/capacitor-bridge/ios/Sources/DeskFleetBridge/{LocalFilesBridge,OutlineAudioShared}.swift`
  - `scripts/{package-ios-release,prepare-ios-signing,publish-ios-release}*.ts`
- **Mobile runtime & bridge wiring**:
  - `apps/web/src/main.ts` (keep `https://deskfleet.yetanother.ai` native fallback,
    `attachLocalEnrollment`, `createLocalDaemonHostSettings`, `createCapacitorWirelessAdbApi`,
    `createCapacitorIosScreenShareApi`)
  - `packages/capacitor-bridge/**` (Android `proot` / `LocalDaemonService` / Wireless ADB,
    iOS `librvvm` / `DeskFleetJITHelper` / `rppairing` / `RvvmRamDonor` / `IosScreenBridgeServer` /
    `IosCoreDeviceSessionManager` / `IosCoreDeviceVideoPipeline` / `IosScreenShareShared` /
    `local-daemon.ts` / `wireless-adb.ts` / `ios-screen-share.ts`)
  - `crates/native/src/ios_screen.rs` (and minimal Linux-only dispatch hooks in
    `crates/native/src/{lib,media,desktop_access,input}.rs`)
  - `Cargo.toml` (keep `"packages/capacitor-bridge/ios/rppairing"` in workspace `exclude`)
  - `scripts/build-android-viewer*.ts`, `scripts/build-ios-viewer*.ts`,
    `scripts/build-ios-riscv64-guest*.ts`, `.github/workflows/ios-guest-riscv64.yml`
- **`linux/riscv64` + Box64 agent support**:
  - `packages/agents/antigravity/src/index.ts`, `packages/agents/core/src/acp.ts`,
    `apps/daemon/src/providers/setup.test.ts`
- **Mobile UI hooks & docs**:
  - `packages/client/src/{central,desktop-api,wireless-adb,ios-screen-share}.ts`
  - `packages/components/` (`AddMachineDialog.vue`, `LocalDaemonRecoveryDialog.vue`, `PreferencesSettings.vue`,
    `WorktreeSettings.vue`, `SettingsView.vue`, `NewSessionView.vue`, `AndroidWirelessAdbSettings.vue`,
    `IosScreenShareSettings.vue`, `useLocalDaemonSettings.ts`, and `locales/*.json` keys)
  - `AGENTS.md` (keep the `DeskFleet Plus (Mobile Fork Scope)` section; accept upstream rules below),
    `THIRD_PARTY_NOTICES.md`, `docs/.vitepress/config.ts` (keep `DeskFleet Plus` sidebar links),
    `docs/content/{,zh/,ja/}guide/android.md` (keep the DeskFleet Plus note), and
    `docs/content/{,zh/,ja/}guide/deskfleet-plus.md`

### 4. Accept upstream directly

Take upstream changes unmodified for shared non-mobile trees so future merges stay clean:

- `apps/server/**`, `apps/desktop/**`, `apps/daemon/**` (except the `riscv64` test in `setup.test.ts`),
  `crates/**`, `packages/protocol/**`, `packages/mcp/**`, `specs/**`, `nix/**`, `packaging/**`,
  and `.agents/skills/**` / `apm*.yaml`.
- Note: Do **not** delete `apps/desktop`, `apps/server`, `nix/`, or `packaging/` source trees from
  the repo—keeping them intact avoids widespread modify/delete conflicts on every upstream sync,
  while our pruned CI workflows ensure they are never built or published here.

### Post-merge verification

After resolving a merge from `upstream/main`:

1. Run `node --test scripts/ci-docs-only.test.ts scripts/ci-ios-release.test.ts scripts/ci-release-build.test.ts scripts/home-downloads.test.ts`
   (or full `mise run ci:preflight`) — `scripts/ci-release-build.test.ts` enforces that pruned
   upstream workflows and non-mobile jobs were not accidentally reintroduced.
2. Verify `git diff --name-status HEAD~1` did not restore deleted workflows or revert
   `moe.remon.deskfleet.plus` / `README.md`.
3. Run `mise run android:test` and (on macOS) `mise run ios:test` when mobile code or bridge
   contracts changed.
