<p align="center">
  <img src="packages/components/src/assets/deskfleet.png" width="96" height="96" alt="DeskFleet Plus logo" />
</p>

<h1 align="center">DeskFleet Plus</h1>

<p align="center">
  Mobile-focused fork of <a href="https://github.com/yet-another-ai/deskfleet">DeskFleet</a> that runs a full local <code>deskfleet-daemon</code> inside Android and iOS.<br />
  Turn your phone or tablet into a self-contained DeskFleet machine—no root, no separate Termux setup, and no desktop host required.
</p>

<p align="center">
  [<a href="#deskfleet-plus-vs-upstream-deskfleet">Plus vs Upstream</a>]
  [<a href="#when-to-use-deskfleet-plus-vs-upstream">When to Use Which</a>]
  [<a href="#how-to-use-deskfleet-plus">How to Use</a>]
  [<a href="#mobile-development">Development</a>]
  [<a href="#upstream-deskfleet">Upstream DeskFleet</a>]
</p>

> [!IMPORTANT]
> **Unofficial mobile-focused fork:** [`LemonNekoGH/deskfleet-plus`](https://github.com/LemonNekoGH/deskfleet-plus) (`moe.remon.deskfleet.plus`) is maintained independently from upstream [`yet-another-ai/deskfleet`](https://github.com/yet-another-ai/deskfleet) (`ai.yetanother.deskfleet`) and is not affiliated with or endorsed by `deskfleet.org`. Both apps use separate package/bundle IDs and can be installed side by side while connecting to the same DeskFleet backend and Teams.

## DeskFleet Plus vs Upstream DeskFleet

Upstream DeskFleet treats mobile apps (Android / iOS) as remote clients: enrolling an Android device requires manually installing `deskfleet-daemon` inside Termux, and iOS has no local daemon runtime. **DeskFleet Plus** keeps the core daemon, backend, and wire protocol aligned with upstream, and focuses on **running the Linux `deskfleet-daemon` directly inside the mobile app sandbox**:

| Area | Upstream DeskFleet (`ai.yetanother.deskfleet`) | DeskFleet Plus (`moe.remon.deskfleet.plus`) |
| --- | --- | --- |
| **Primary focus** | Desktop apps (macOS / Windows / Linux), headless daemons, central server, and remote-only mobile clients | Mobile apps (Android & iOS) with built-in local Linux daemons |
| **Android local daemon** | Manual setup inside external Termux (`proot-distro`) | Built-in unprivileged `proot` + Debian `arm64` sandbox, bundled `deskfleet-daemon` & `scrcpy-server`, foreground wake-lock service, auto-upgrade on app update |
| **Android Wireless ADB** | Manual `adb` CLI setup | Built-in Wireless ADB auto-discovery, notification pairing-code reply, TLS reconnect, optional `tcpip 5555` keep-alive, and Settings UI |
| **iOS local daemon** | Not supported (remote client only) | Embedded pure-JIT `librvvm` RISC-V 64 Linux VM, pre-baked Ubuntu 24.04 `riscv64` guest image, `DeskFleetJITHelper` (`StikJIT`) + iOS 27+ on-device RemotePairing, `xpc_shmem` RAM donation, silent-audio background keep-alive, and Box64 (`x86_64` Antigravity CLI support) |
| **Mobile enrollment & host settings** | Enrollment UI only on desktop; mobile hides host settings | Live setup terminal inside **Add machine → This computer**, plus CLI-backed **Remote Agents** and **Worktrees** settings on mobile |
| **CI & Releases** | Desktop installers, DEB/RPM, Nix, AUR, Docker images, Google Play, TestFlight | Mobile-only CI (`preflight` + Android/iOS tests & builds) and GitHub Draft Releases (Android APK + optional signed iOS IPA) plus pre-baked iOS `riscv64` guest image releases |

## When to Use DeskFleet Plus vs Upstream

- **Use DeskFleet Plus when:**
  - You want an **Android phone or tablet** to enroll itself as a DeskFleet machine in one tap without root or maintaining Termux manually.
  - You want built-in **Android Wireless ADB** pairing and `tcpip 5555` management for `scrcpy` remote screen control.
  - You want to run a real Linux **`deskfleet-daemon` and ACP agents directly on iOS / iPadOS** via sideloading + JIT (`librvvm` + Box64).
- **Use upstream [DeskFleet](https://github.com/yet-another-ai/deskfleet) when:**
  - You need the **desktop app** (macOS, Windows, Linux), **headless server daemon**, or **self-hosted backend / Docker / Nix / AUR packages**.
  - You only want an official **Google Play / App Store** mobile client to control your existing desktop or server machines.
  - You prefer running an official upstream Android daemon manually inside Termux.

Both distributions speak the same protocol and default to `https://deskfleet.yetanother.ai` (or your self-hosted DeskFleet server), so you can mix upstream desktop/server machines with DeskFleet Plus mobile devices in the same Team.

## How to Use DeskFleet Plus

Full user guides: [English](docs/content/guide/deskfleet-plus.md) · [简体中文](docs/content/zh/guide/deskfleet-plus.md) · [日本語](docs/content/ja/guide/deskfleet-plus.md)

### Android

1. Download and install the signed `DeskFleet Plus` APK (`moe.remon.deskfleet.plus`) from [GitHub Releases](https://github.com/LemonNekoGH/deskfleet-plus/releases).
2. Open the app, sign in, and go to **Add machine → This computer** (live setup progress streams in the embedded terminal).
3. DeskFleet Plus automatically provisions a Debian `arm64` `proot` container, installs the bundled `deskfleet-daemon` and `scrcpy-server`, starts the foreground daemon service, and enrolls the device with your Team.
4. *(Optional)* Open **Settings → Wireless ADB** to pair local wireless debugging (via notification or port + code) and enable `tcpip 5555` keep-alive for remote screen control.
5. Configure **Remote Agents** and **Worktrees** directly in **Settings**.

### iOS / iPadOS

1. Sideload the `DeskFleet Plus` IPA (`moe.remon.deskfleet.plus`) onto your device (e.g., via SideStore or AltStore with JIT support).
2. Sign in and open **Add machine → This computer**.
3. Complete JIT activation when prompted (on-device RemotePairing on iOS 27+, or import a pairing file with the embedded `DeskFleetJITHelper` / `StikJIT`; iOS 26+ TXM devices require debugger attach `P_TRACED` before cold-starting the VM).
4. On first run, the app downloads the pre-baked Ubuntu 24.04 `riscv64` guest image from this fork's `ios-guest-riscv64` release, boots `librvvm`, syncs host DNS/proxy/clock, and enrolls the guest `deskfleet-daemon`.
5. Manage installed ACP agents (including `x86_64` Antigravity CLI via pre-installed Box64) and local daemon settings directly from **Settings**.

## Mobile Development

Toolchain versions and tasks are locked in [`mise.toml`](mise.toml):

```sh
mise trust
mise install --locked
mise run install

# Preflight checks (formatting, script tests, Web/docs typechecks, specs)
mise run ci:preflight

# Android unit tests / release APK + AAB build
mise run android:test
mise run android:build

# iOS Simulator test / release archive build (macOS)
mise run ios:test
mise run ios:build
```

For fork architecture, runtime boundaries, and upstream sync guidelines, see [DeskFleet Plus Architecture](agents/docs/deskfleet-plus.md) and [AGENTS.md](AGENTS.md).

## Upstream DeskFleet

For full product overview, desktop installers (macOS / Windows / Linux), headless server daemon, self-hosted backend deployment, and general DeskFleet documentation, visit the upstream project:

- **GitHub**: [yet-another-ai/deskfleet](https://github.com/yet-another-ai/deskfleet)
- **Website & Docs**: [www.deskfleet.org](https://www.deskfleet.org)

## License & Third-Party Notices

DeskFleet Plus is licensed under the [Apache-2.0 License](LICENSE). Bundled Android and iOS runtime components (`proot`, `libtalloc`, `libandroid-shmem`, `scrcpy-server`, `librvvm`, `StikJIT`, `rppairing`/`idevice`, and RISC-V guest firmware) and their licenses are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
