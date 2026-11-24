# DeskFleet Plus (Mobile Local Daemon)

> [!NOTE]
> **Unofficial mobile-focused fork:** [`LemonNekoGH/deskfleet-plus`](https://github.com/LemonNekoGH/deskfleet-plus) (**DeskFleet Plus**, app ID `moe.remon.deskfleet.plus`) is an independent third-party fork of [`yet-another-ai/deskfleet`](https://github.com/yet-another-ai/deskfleet) (`ai.yetanother.deskfleet`) and has no affiliation with or endorsement from `deskfleet.org`.

DeskFleet Plus embeds a full Linux `deskfleet-daemon` directly inside the **Android** and **iOS** apps so your phone or tablet can enroll itself as a DeskFleet machine—hosting ACP agents, PTY terminals, Git worktrees, file transfers, and (on Android) remote screen control—without requiring root access, external Termux setup, or a desktop computer.

## Differences from Upstream DeskFleet

DeskFleet Plus uses the same wire protocol, backend API, and UI as upstream DeskFleet, and focuses its additions on mobile self-hosting:

| Capability | Upstream DeskFleet | DeskFleet Plus |
| --- | --- | --- |
| **App / Bundle ID** | `ai.yetanother.deskfleet` | `moe.remon.deskfleet.plus` (can be installed alongside upstream) |
| **Android local daemon** | Manual installation in external Termux (`proot-distro`) | Built-in unprivileged `proot` + Debian `arm64` sandbox, bundled `deskfleet-daemon` & `scrcpy-server`, foreground wake-lock service, auto-upgrade |
| **Android Wireless ADB** | Manual `adb pair` / `adb connect` in shell | Built-in Wireless ADB auto-discovery, notification pairing-code input, TLS reconnect, optional `tcpip 5555` keep-alive, and Settings UI |
| **iOS local daemon** | Not supported (client only) | Embedded pure-JIT `librvvm` RISC-V 64 Linux VM with pre-baked Ubuntu 24.04 `riscv64` guest, `StikJIT` helper, iOS 27+ on-device RemotePairing, RAM donation, background audio keep-alive, and Box64 (`x86_64` Antigravity CLI) |
| **Mobile enrollment & host settings** | Enrollment UI on desktop; mobile hides host settings | Embedded streaming setup terminal in **Add machine → This computer**, plus **Remote Agents** and **Worktrees** host settings on mobile |
| **Distribution** | Desktop installers, DEB/RPM, Nix, AUR, Docker, Google Play, App Store / TestFlight | GitHub Releases for Android APK (and iOS IPA for sideloading) + `ios-guest-riscv64` guest image releases |

## When to Use DeskFleet Plus vs Upstream

**Choose DeskFleet Plus when:**

- You want to turn an **Android** phone or tablet into a DeskFleet machine in one tap without root or maintaining Termux yourself.
- You want built-in **Wireless ADB** management on Android for `scrcpy` remote screen control.
- You want to run a real Linux **`deskfleet-daemon` and ACP agents on iOS / iPadOS** via sideloading + JIT.

**Choose upstream [DeskFleet](https://github.com/yet-another-ai/deskfleet) when:**

- You are installing on **macOS, Windows, or Linux** desktops, running a **headless server daemon**, or self-hosting the **central backend**.
- You only need an official **Google Play** or **App Store** mobile client to connect to existing desktop/server machines.
- You prefer managing an upstream Android daemon manually inside Termux.

Both apps connect to `https://deskfleet.yetanother.ai` by default (or your own self-hosted server), so DeskFleet Plus mobile devices work seamlessly in the same Team alongside upstream desktop and server machines.

## How to Use DeskFleet Plus

### Android

1. **Install**: Download the signed `deskfleet-<version>-android-arm64.apk` from [DeskFleet Plus Releases](https://github.com/LemonNekoGH/deskfleet-plus/releases) and install it. Because it uses `moe.remon.deskfleet.plus`, you do not need to uninstall the official DeskFleet app.
2. **Sign in and enroll this device**:
   - Open DeskFleet Plus and sign in to your Team.
   - Open **Add machine → This computer**, enter a machine name, and confirm.
   - Watch progress in the embedded setup terminal: the app automatically downloads the Debian 13 (`trixie`) `arm64` rootfs into its private sandbox, deploys the bundled `deskfleet-daemon` and `scrcpy-server`, starts the foreground daemon service with wake lock, and completes enrollment.
3. **Keep running in the background**: Allow notifications (for the foreground service) and disable aggressive battery optimization for DeskFleet Plus so Android does not kill the local daemon.
4. **Enable Wireless ADB (optional, for remote screen control)**:
   - Enable **Developer options → Wireless debugging** in Android Settings.
   - Open **Settings → Wireless ADB** inside DeskFleet Plus and tap **Start pairing** (or use the shortcut to open Developer options).
   - When Android displays the pairing port and 6-digit code, enter them directly in the notification reply or in the Wireless ADB panel.
   - Optionally enable **Keep `tcpip 5555` alive** so the container automatically reconnects across network changes.
5. **Configure host settings**: Open **Settings** to toggle **Remote Agents** permissions and configure **Worktrees** directly on the phone.

### iOS / iPadOS

1. **Install**: Obtain the `DeskFleet Plus` IPA (`moe.remon.deskfleet.plus`) and sideload it onto your device (for example with SideStore or AltStore).
2. **Sign in and start local enrollment**:
   - Open DeskFleet Plus, sign in to your Team, and open **Add machine → This computer**.
3. **Activate JIT & pairing**:
   - The embedded `librvvm` virtual machine requires JIT. Follow the in-app JIT setup guide:
     - On **iOS 27+**, you can complete **on-device RemotePairing** directly inside the app.
     - On earlier supported versions, import your pairing file for the embedded `DeskFleetJITHelper` (`StikJIT`) or attach via StikDebug.
     - On **iOS 26+ TXM devices**, debugger attachment (`P_TRACED`) is required before cold-starting RVVM JIT.
4. **Automatic guest image provisioning**:
   - On first setup, the app downloads the pre-baked Ubuntu 24.04 `riscv64` disk image (containing `deskfleet-daemon`, Node.js, systemd, and Box64) from this fork's `ios-guest-riscv64` release, boots the VM, syncs host DNS/proxy/clock, and enrolls the guest daemon.
   - Setup progress streams live in the enrollment terminal.
5. **Run agents & manage settings**:
   - Install and authenticate ACP agents in **Settings → Agents** (including `x86_64` Antigravity CLI, which runs automatically through Box64 inside the `riscv64` guest).
   - Adjust **Remote Agents** and **Worktrees** in **Settings** while the VM is running.
   - Keep background audio permission available so the silent-audio keep-alive can prevent iOS from suspending the VM when backgrounded.

## Third-Party Components & Licenses

All bundled Android and iOS runtime components (`proot`, `libtalloc`, `libandroid-shmem`, `scrcpy-server`, `librvvm`, `StikJIT`, `rppairing`/`idevice`, and RISC-V guest firmware) are documented with source URLs and licenses in [`THIRD_PARTY_NOTICES.md`](https://github.com/LemonNekoGH/deskfleet-plus/blob/main/THIRD_PARTY_NOTICES.md).
