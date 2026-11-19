# Third-Party Notices (DeskFleet Plus)

`DeskFleet Plus` is licensed under the Apache License, Version 2.0 (see [`LICENSE`](LICENSE)).

---

## Android

The Android APK invokes the bundled `libproot.so` executable out-of-process via `ProcessBuilder` rather than linking against it. No Debian root filesystem or Debian `apt` packages are redistributed inside the APK; on first device setup the application downloads the official Debian 13 (`trixie`) `arm64` OCI rootfs directly from `debuerreotype/docker-debian-artifacts` (`dist-arm64v8`) and installs packages (`ca-certificates`, `git`, `curl`, `adb`) directly from official Debian mirrors (`http://deb.debian.org/debian`).

The following third-party binaries may be bundled into `DeskFleet Plus` Android builds:

### 1. `proot` (`5.1.107.102`)

- **Packaged files**: `jniLibs/arm64-v8a/libproot.so`, `jniLibs/arm64-v8a/libproot_loader.so`
- **License**: `GPL-2.0-or-later` (upstream `termux/proot` source headers; `termux-packages` declares `GPL-2.0`; dynamically linked to `libtalloc` under `LGPL-3.0-or-later`)
- **Copyright**: STMicroelectronics and PRoot / Termux contributors
- **Upstream source archive**: `https://github.com/termux/proot/archive/v5.1.107.102.zip` (`SHA-256: 30d12a6e2cc4147123756ff58edea262d3083bbc238c12d0ab9b39e3d1c40852`)
- **Termux build recipe & patches**: `https://github.com/termux/termux-packages/tree/master/packages/proot`
- **Termux `.deb` used at build time**: `https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.102_aarch64.deb` (`SHA-256: 10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030`)
- **Build-time modifications** (`scripts/build-android-viewer.ts`, `patchCStringInPlace`): in `bin/proot` (staged as `libproot.so`), replaced null-terminated ELF strings `libtalloc.so.2` -> `libtalloc.so` and `/data/data/com.termux/files/usr/lib` -> `$ORIGIN`; `libexec/proot/loader` (`libproot_loader.so`) is unmodified.

### 2. `libtalloc` (`2.5.0`)

- **Packaged file**: `jniLibs/arm64-v8a/libtalloc.so`
- **License**: `LGPL-3.0-or-later` (Samba upstream; `termux-packages` declares `GPL-3.0`)
- **Copyright**: Andrew Tridgell and Samba contributors
- **Upstream source archive**: `https://www.samba.org/ftp/talloc/talloc-2.5.0.tar.gz` (`SHA-256: 912afa237510ae542a7733998eb18a12bcda35ab6729c8e2ddb43e8d0ebab007`)
- **Termux build recipe & patches**: `https://github.com/termux/termux-packages/tree/master/packages/libtalloc`
- **Termux `.deb` used at build time**: `https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_2.5.0_aarch64.deb` (`SHA-256: 556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7`)
- **Build-time modifications** (`scripts/build-android-viewer.ts`, `patchCStringInPlace`): replaced null-terminated ELF strings `libtalloc.so.2` -> `libtalloc.so` and `/data/data/com.termux/files/usr/lib` -> `$ORIGIN`.

### 3. `libandroid-shmem` (`0.7`)

- **Packaged file**: `jniLibs/arm64-v8a/libandroid-shmem.so`
- **License**: `BSD-3-Clause`
- **Upstream source archive**: `https://github.com/termux/libandroid-shmem/archive/refs/tags/v0.7.tar.gz` (`SHA-256: 1e5ff8459bc0a8c229dd8a94b27d119987e09ef3414331c2b5ebfff20b98e867`)
- **Termux build recipe & patches**: `https://github.com/termux/termux-packages/tree/master/packages/libandroid-shmem`
- **Termux `.deb` used at build time**: `https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb` (`SHA-256: 0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6`)
- **Build-time modifications** (`scripts/build-android-viewer.ts`, `patchCStringInPlace`): replaced null-terminated ELF strings `/data/data/com.termux/files/usr/lib` -> `$ORIGIN` and `/data/data/com.termux/files/usr/tmp/ashv_key_%d` -> `./ashv_key_%d`.

```text
Copyright (c) 2013, Sergii Pylypenko
Copyright (c) 2017, Fredrik Fornwall
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this
  list of conditions and the following disclaimer in the documentation and/or
  other materials provided with the distribution.

* Neither the name of the {organization} nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 4. `scrcpy-server` (`v3.1`)

- **Packaged file** (release builds): `assets/scrcpy-server.jar`
- **License**: `Apache-2.0`
- **Copyright**: Genymobile and Romain Vimont (`Genymobile/scrcpy`)
- **Source**: `https://github.com/Genymobile/scrcpy/tree/v3.1`
- **Release binary**: `https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-server-v3.1`
- **Modifications**: Unmodified.

### 5. `deskfleet-daemon` & bundled runtime (`dsh`)

- **Packaged file** (release builds): `assets/deskfleet-daemon-linux-arm64.tar.gz`
- **License**: `Apache-2.0` (`yet-another-ai/deskfleet`), with bundled Node.js runtime (`MIT`) and `@deepseek-ai/dsh` (`MIT`)
- **Source**: `https://github.com/yet-another-ai/deskfleet`
- **Build-time modifications**: `deskfleet-server` is removed via `repackageDaemonArchive` in `scripts/build-android-viewer.ts`.

### Android Corresponding Source Notice

Full build scripts and ELF string patching code are provided in `scripts/build-android-viewer.ts`. Public binary releases should retain access to the corresponding source archives for `proot` (`5.1.107.102`) and `libtalloc` (`2.5.0`) in accordance with GPL-2.0 and LGPL-3.0.

---

## iOS

When building and distributing the iOS application (IPA), the following third-party components are included or referenced under licenses compatible with Apache-2.0:

### 1. librvvm (RVVM Library)

- **Upstream**: https://github.com/LekKit/RVVM (pinned commit `abb3ace2cd5a8ed7be00394212551abd630745e1`)
- **License**: Mozilla Public License, Version 2.0 (MPL-2.0)
- **Scope**: Only the MPL-2.0 library sources (`rvvm_static`) are compiled into `Librvvm.xcframework`.
  The upstream GPL-3.0 CLI entry points (`src/main.c` and `src/rvvm_user_main.c`) are deleted prior to
  configuration and are not compiled or linked.
- **Modifications**: Our MPL-2.0 modifications to `librvvm` for iOS W^X RVJIT dual-mapping, iOS 26+
  JIT debugger detach, and custom RAM donor hooks are published in source form at
  `packages/capacitor-bridge/ios/rvvm/ios-jit.patch`.
- **License text**: https://www.mozilla.org/en-US/MPL/2.0/

### 2. StikJIT

- **Upstream**: https://github.com/StikDebug/StikJIT (`v1.9.0`)
- **License**: Mozilla Public License, Version 2.0 (MPL-2.0)
- **Scope**: Embedded unmodified as `StikJIT.xcframework` inside `DeskFleetJITHelper.appex` for
  on-device JIT activation.
- **License text**: https://www.mozilla.org/en-US/MPL/2.0/

### 3. rppairing (On-Device RemotePairing) & idevice

- **Upstream**:
  - `packages/capacitor-bridge/ios/rppairing/` (MIT License)
  - `idevice` (https://github.com/jkcoxson/idevice, MIT License)
  - `tokio` (https://github.com/tokio-rs/tokio, MIT License)
- **License**: MIT License
- **Scope**: Compiled into `IshPlusRPPairing.xcframework` for iOS 27+ on-device RemotePairing.

### 4. Shared-Memory RAM Donation Technique (Acknowledgment)

- **Reference**: MeloNX (MIT License)
- **Scope**: `RvvmRamDonor.m` and `DeskFleetJITHelper/HelperPrincipal.m` are clean-room Apache-2.0
  implementations of the `xpc_shmem` auxiliary-extension RAM donation technique pioneered by MeloNX.

### 5. RISC-V Guest Firmware (Mere Aggregation)

- **OpenSBI (`fw_jump.bin`)**: BSD-2-Clause License (https://github.com/riscv-software-src/opensbi)
- **OpenSBI + U-Boot (`fw_payload.bin`)**: Bundled from `LekKit/RVVM` `v0.5` release as standalone
  RISC-V guest firmware booted inside the emulated RISC-V machine (mere aggregation, not linked into
  the iOS host binary). U-Boot source is available at https://source.denx.de/u-boot/u-boot.
