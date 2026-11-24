# Agent guide

Engineering documentation lives in `agents/docs/`; `docs/` is reserved for the
product website and user manual.

## DeskFleet Plus (Mobile Fork Scope)

This repository (`LemonNekoGH/deskfleet-plus`, package/bundle ID `moe.remon.deskfleet.plus`)
is a mobile-focused fork of upstream `yet-another-ai/deskfleet` (`ai.yetanother.deskfleet`).
Read [DeskFleet Plus architecture and maintenance](agents/docs/deskfleet-plus.md) before
changing mobile daemon runtimes, mobile CI/release workflows, or syncing upstream.

- **Core purpose**: Allow Android and iOS clients to host a full Linux `deskfleet-daemon`
  inside the mobile app sandbox and enroll themselves as managed Team machines, while
  keeping desktop, central backend, and wire protocol aligned with upstream.
- **Mobile runtime ownership**:
  - **Shared Capacitor bridge & UI**: `packages/capacitor-bridge/src/local-daemon.ts`
    and `wireless-adb.ts` expose unified local enrollment, streaming setup logs, CLI-backed
    host settings (`deskfleet-daemon settings`), and Wireless ADB APIs to `apps/web` and
    `packages/components`.
  - **Android**: `packages/capacitor-bridge/android/` (`ProotDaemonManager.kt`,
    `LocalDaemonService.kt`, `WirelessAdbManager.kt`, `WirelessAdbController.kt`) plus
    `scripts/build-android-viewer.ts` bundle unprivileged Termux `proot`, `scrcpy-server`,
    and upstream's `deskfleet-daemon` `linux-arm64` binary.
  - **iOS**: `packages/capacitor-bridge/ios/` (`RvvmDaemonManager.swift`, `RvvmHostBridge.c`,
    `RvvmOnDevicePairing.swift`, `RvvmRamDonor.m`, `rppairing/`, `rvvm/ios-jit.patch`),
    `apps/web/ios/App/DeskFleetJITHelper/`, `scripts/build-ios-viewer.ts`, and
    `scripts/build-ios-riscv64-guest.ts` run a pure-JIT `librvvm` RISC-V 64 Linux guest
    with Box64 (`packages/agents/antigravity` & `packages/agents/core` include `linux/riscv64`
    Box64 and timeout adaptations).
- **Mobile-only CI & releases**: `.github/workflows/ci.yml`, `test.yml`, `build.yml`, and
  `publish.yml` are intentionally pruned to `preflight` + Android/iOS tests, mobile builds,
  and GitHub Draft Releases (Android APK + optional signed iOS IPA). Desktop installers,
  Linux DEB/RPM/Nix/AUR, Docker images, Google Play, and TestFlight publishing belong to
  upstream. `.github/workflows/ios-guest-riscv64.yml` builds and publishes the pre-baked
  iOS `riscv64` guest image, and is automatically invoked by `publish.yml` on stable tags.
- **Upstream-aligned release cadence**: Cut a DeskFleet Plus stable release `vX.Y.Z`
  whenever upstream `yet-another-ai/deskfleet` publishes a formal stable release `vX.Y.Z`
  with its `deskfleet-linux-arm64.tar.gz` daemon archive available. Agents and scheduled
  sync tasks can check readiness with `node scripts/check-upstream-release.ts --check-latest`;
  `publish.yml` enforces `--require-tag` before building, refreshes `ios-guest-riscv64` on
  stable tags, and creates a Draft Release. When editing or publishing the GitHub Release
  changelog, always separate the notes under two top-level headings: `# DeskFleet Plus`
  (fork-only mobile changes) and `# Upstream` (upstream changes included in `vX.Y.Z`).
- **Upstream sync & merge exclusions** (see the full playbook in
  [agents/docs/deskfleet-plus.md](agents/docs/deskfleet-plus.md#upstream-merge-policy--conflict-playbook)):
  - **Keep deleted (never restore from upstream)**: `.github/workflows/nix.yml`,
    `nix-server.yml`, `aur.yml`, `aur-publish.yml`, `linux-packages.yml`, and any new
    upstream workflow solely for desktop, Linux package, container, or app-store publishing.
  - **Do not overwrite with upstream (keep fork-owned)**: `README.md` (keep DeskFleet Plus's
    mobile README; drop upstream desktop/badges/install copy), and desktop/server/store CI
    jobs (`package`, `static`, `checks`, `backend`, `deploy-pages`, `image`,
    `super_agent_image`, `google_play`, `testflight`) inside `.github/workflows/{ci,test,build,publish}.yml`
    plus their corresponding workflow assertions in `scripts/{ci-docs-only,ci-ios-release,ci-release-build,home-downloads,package-linux-release,package-nix-release}.test.ts`
    (only port shared tooling/Android/iOS improvements from upstream CI changes).
  - **Always preserve during conflicts**: `moe.remon.deskfleet.plus` /
    `group.moe.remon.deskfleet.plus` / `DeskFleet Plus` branding, default mobile server URL
    (`https://deskfleet.yetanother.ai`), `Cargo.toml` `exclude` for `rppairing`,
    `linux/riscv64` Box64 agent adaptations, embedded Android/iOS daemon & Wireless ADB code,
    mobile local-daemon UI hooks, `THIRD_PARTY_NOTICES.md`, and DeskFleet Plus docs.
  - **Keep diffs outside fork-owned files minimal**: accept upstream changes directly for
    `apps/server`, `apps/desktop`, `crates`, `packages/protocol`, `packages/mcp`, `specs`,
    `nix`, and `packaging` so future merges from `upstream/main` stay low-conflict.

## Architecture

- deskfleet manages a team's AI agents and working environments across machines.
  Read [the architecture](agents/docs/architecture.md) before changing component
  boundaries or resource ownership.
- The hierarchy is Team → Machine registration → Workspace → Worktree. One
  physical daemon has the same public Machine ID across Teams on each backend;
  each `(Machine, Team)` has exactly one registration. Registrations own separate
  catalogs, Sessions, terminals, providers, and credentials. Qualify API and IPC
  resource access by Team and Machine; a public Machine ID alone is not a scope.
  This is API isolation within one OS user, not filesystem or process isolation.
  Workspace creation requires ordered directory paths, with the first as default
  and no directory aliases. Its main Worktree uses those actual directories; other Worktree records
  are created and destroyed with their owning Session, never maintained separately.
  A new Session either generates its own Git worktree or works directly in the
  Workspace's directories. Archive stops live resources and applies the host's
  worktree cleanup and local-change protection settings. Restore retains protected
  checkouts or recreates cleaned ones at their saved committed HEADs. Archiving
  or deleting a directory Session never touches source files.
  A TerminalSession can belong to a Machine, Workspace, or Worktree. Its working
  directory is a separate choice.
- Cross-machine coordination belongs to agent-facing MCP tools. Do not introduce
  a global Project abstraction spanning machines.
- The central backend is open-source Rust using Actix Web. Native capabilities
  live in Rust libraries, exposed through thin napi-rs bindings.
- The machine daemon is a TypeScript library. Headless machines run it as a
  standalone Bun executable. The Electron app hosts it in the app's main process:
  it outlives the app's windows, which close to the tray, and stops when the app
  quits. One daemon hosts all registered Team runtimes concurrently; selecting a
  Team changes the client view, not the running registration. Do not spawn a
  separate daemon process from the app.
- ACP connects agent implementations. WebRTC carries peer data and media, with
  server-assisted signaling and TURN fallback.
- `PROTOCOL_VERSION` remains `1` until maintainers explicitly declare the first
  protocol freeze. Evolve provisional contracts in place. Do not add version-bump
  tasks or compatibility layers for earlier provisional shapes.

## Development workflow

Use the locked mise toolchain from the repository root:

```sh
mise install --locked
mise run dev
mise run check
```

Run commands in a login shell. Use PowerShell 7 (`pwsh`) on Windows. For a
focused command, use `mise exec -- cargo ...` or the appropriate mise task.
[Environment notes](agents/docs/environment.md) describe tool and skill updates;
[CI notes](agents/docs/ci.md) describe the reusable workflows and `Gate` check.

Keep application entry points and binding layers thin. Split code around feature
ownership. Review production files approaching 800 lines; split hand-authored
production files before they exceed 1,200 lines, and keep new files below 800.
Generated code, FFI declarations, and tests can have justified exceptions.

Write repository-owned Node scripts in TypeScript with erasable syntax so the
locked Node runtime can execute them directly.

Test deskfleet's behavior at the narrowest useful boundary. Avoid duplicating
upstream library tests. Run checks appropriate to the change.

Use SeaORM entities and SeaQuery builders for runtime database access, with typed
table and column identifiers. Do not concatenate SQL or pass string predicates
between helpers. Preserve transaction, lock, conflict, and pagination semantics
when changing queries. Keep any unsupported database-specific expression narrow
and explain the exception at its use; historical static schema migrations are
separate from runtime queries.

Update the document that owns a decision. Create or accept an ADR only when a
maintainer requests it.

## Documentation and skills

Use English for repository documentation. Keep temporary notes and generated
output out of the documentation trees.

`apm.yml` and `apm.lock.yaml` own the installed skills in `.agents/skills/`.
These installed files belong in source control so fresh checkouts have them.
Restore them with `mise run skills:install`. Change the dependency declarations
and regenerate for updates; do not hand-edit installed skill copies.
Only `apm_modules/`, the local package download cache, is ignored.

Use the installed Rust guidance for Rust work and the other skills when their
stated triggers apply. The upstream Rust example harness is excluded from the
deskfleet Cargo workspace; it is not part of the product or its build.

`vueuse-functions` applies when assisting Vue or Nuxt work. Invoke it as
`/vueuse-functions`. Before using a VueUse API, read the matching file under
`.agents/skills/vueuse-functions/references/`. Each function is `AUTO` (use when
it fits), `EXTERNAL` (only when its extra dependency is already installed), or
`EXPLICIT_ONLY` (only when asked). Instructions in this file override those
defaults.

`i-have-adhd` shapes output for an ADHD reader: lead with the next action,
number multi-step work, and restate state across turns. Invoke it as
`/i-have-adhd`; it stays on until the reader says "stop adhd mode".

`create-pr-with-evidence` prepares pull requests with verifiable change context,
architecture evidence, and before/after visual evidence when UI changes. Invoke
it as `/create-pr-with-evidence` when opening or preparing a PR. The installed
directory is `.agents/skills/create-pr-with-evidence-skill/`.

`modern-web-guidance` provides modern web platform best practices for HTML,
CSS, accessibility, forms, client-side JS, performance, and security. Invoke it
as `/modern-web-guidance` when implementing or updating web UI or client-side
browser code; its installed directory is `.agents/skills/modern-web-guidance/`.
