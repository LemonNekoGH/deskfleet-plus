# DeskFleet Plus（移动端内置 Daemon）

> [!NOTE]
> **非官方移动端专精 Fork 说明：** [`LemonNekoGH/deskfleet-plus`](https://github.com/LemonNekoGH/deskfleet-plus)（**DeskFleet Plus**，包名/Bundle ID 为 `moe.remon.deskfleet.plus`）是基于 [`yet-another-ai/deskfleet`](https://github.com/yet-another-ai/deskfleet)（`ai.yetanother.deskfleet`）独立维护的第三方分支，与 DeskFleet 官方项目及 `deskfleet.org` 无隶属或背书关系。

DeskFleet Plus 将完整的 Linux `deskfleet-daemon` 直接嵌入 **Android** 和 **iOS** 应用沙箱内，让手机或平板无需 Root、无需手动折腾 Termux、也无需依赖桌面端，就能直接把自己注册为一台完整的 DeskFleet 受管机器——支持运行 ACP Agent、PTY 终端、Git worktree、文件传输，以及 Android 端的远程投屏与控制。

## 与上游 DeskFleet 的区别

DeskFleet Plus 保持桌面端、中心服务端与通信协议和上游完全一致，所有增强都聚焦在**移动端自托管本地 Daemon**：

| 维度 | 上游 DeskFleet（`ai.yetanother.deskfleet`） | DeskFleet Plus（`moe.remon.deskfleet.plus`） |
| --- | --- | --- |
| **定位与重点** | 桌面端（macOS / Windows / Linux）、无头服务器 Daemon、中心服务端、以及纯远程控制移动端 | 专注移动端（Android / iOS）内置本地 Linux Daemon |
| **Android 本地 Daemon** | 需要自行安装 Termux（`proot-distro`）并手动部署启动 | 应用内直接嵌入无特权 `proot` + Debian `arm64` 沙箱，内置 `deskfleet-daemon` 与 `scrcpy-server`，带唤醒锁前台守护并随 App 自动升级 |
| **Android 无线 ADB** | 需要在终端手动执行 `adb pair` / `adb connect` | 内置无线调试自动发现、通知栏直接输入配对码、TLS 自动重连、可选 `tcpip 5555` 保活与设置界面 |
| **iOS 本地 Daemon** | 不支持（仅作远程客户端） | 进程内嵌入纯 JIT `librvvm` RISC-V 64 虚拟机，自动下载预烘焙 Ubuntu 24.04 `riscv64` 镜像，集成 `StikJIT` 辅助扩展、iOS 27+ 机内 RemotePairing、共享内存捐赠、静音后台保活与 Box64（支持运行 `x86_64` Antigravity CLI） |
| **移动端注册与主机设置** | 仅桌面端支持本机注册，移动端隐藏主机设置 | **添加机器 → 此电脑** 内嵌实时终端流式显示部署日志，移动端开放 **远程 Agent** 与 **Worktree** 本机设置 |
| **构建与发布渠道** | 桌面安装包、DEB/RPM、Nix、AUR、Docker 镜像、Google Play、App Store / TestFlight | 专注移动端 CI 与 GitHub Release（Android APK + 可选签名 iOS IPA）以及 `ios-guest-riscv64` 预烘焙镜像 |

## 什么时候用 DeskFleet Plus，什么时候用上游？

**适合使用 DeskFleet Plus 的场景：**

- 你希望把 **Android 手机或平板**一键注册成 DeskFleet 机器，不想 Root，也不想手动安装和维护 Termux。
- 你希望在 Android 上通过图形界面一键配对 **无线 ADB** 并保持 `tcpip 5555` 在线，以支持 `scrcpy` 远程投屏操控。
- 你希望在 **iPhone / iPad** 上通过侧载 + JIT 直接运行完整的 Linux `deskfleet-daemon` 和编程 Agent。

**适合使用上游 [DeskFleet](https://github.com/yet-another-ai/deskfleet) 的场景：**

- 你需要安装 **macOS / Windows / Linux 桌面客户端**、部署**无头服务器 Daemon**，或者自建 **DeskFleet 中心服务端**（Docker / Nix / AUR 等）。
- 你只需要官方 **Google Play / App Store** 移动端来远程连接电脑或服务器，不需要手机自己跑 Daemon。
- 你更倾向于在 Android 上自己用 Termux 手动管理官方 Daemon。

两个版本使用完全相同的协议，且默认都连接 `https://deskfleet.yetanother.ai`（也支持自建服务端）；独立包名允许两者同机共存，并可以在同一个 Team 里把上游电脑/服务器和 DeskFleet Plus 移动设备混编协作。

## 如何使用 DeskFleet Plus

### Android 使用步骤

1. **安装应用**：从 [DeskFleet Plus Releases](https://github.com/LemonNekoGH/deskfleet-plus/releases) 下载并安装签名版 `deskfleet-<version>-android-arm64.apk`。包名为 `moe.remon.deskfleet.plus`，不会覆盖官方版 `ai.yetanother.deskfleet`。
2. **登录并注册本机**：
   - 打开应用并登录你的团队账号。
   - 点击 **添加机器 → 此电脑**，确认机器名称后提交。
   - 界面会展开内嵌终端实时输出进度：应用自动下载 Debian 13（`trixie`）`arm64` 根文件系统到私有沙箱、部署内置 `deskfleet-daemon` 与 `scrcpy-server`、启动带唤醒锁的前台常驻服务并完成团队注册。
3. **后台保活设置**：授予通知权限（用于前台常驻服务通知），并在系统电池设置中将 DeskFleet Plus 设为“无限制 / 不优化”，避免系统在后台杀死本地 Daemon。
4. **配置无线 ADB（可选，用于远程画面与触控）**：
   - 在 Android 系统设置中开启 **开发者选项 → 无线调试**。
   - 打开 DeskFleet Plus 的 **设置 → 无线 ADB**，点击开始配对（也可直接点击按钮跳转到开发者选项）。
   - 系统弹出配对端口和 6 位配对码后，可以直接在通知栏快捷回复，或在无线 ADB 设置页填入端口与配对码完成配对。
   - 可按需开启 **`tcpip 5555` 保活**，在网络切换后自动重连。
5. **管理本机设置**：注册完成后，可直接进入 **设置** 调整本机的 **远程 Agent 权限** 与 **Worktree 偏好**。

### iOS / iPadOS 使用步骤

1. **侧载安装**：获取 `DeskFleet Plus` IPA（`moe.remon.deskfleet.plus`），通过支持 JIT 的侧载工具（如 SideStore / AltStore）安装到设备。
2. **登录并开始本机注册**：打开应用并登录团队，进入 **添加机器 → 此电脑**。
3. **完成 JIT 激活与配对**：
   - 内置的 `librvvm` 虚拟机需要 JIT 权限，请按应用内向导完成激活：
     - **iOS 27+**：可直接在应用内完成**机内 RemotePairing** 配对。
     - **更早支持版本**：导入配对文件供内置 `DeskFleetJITHelper`（`StikJIT`）使用，或通过 StikDebug 附加。
     - **iOS 26+ TXM 设备**：冷启动 RVVM JIT 前需确保进程已附加调试器（`P_TRACED`）。
4. **自动下载并启动预烘焙 Linux 镜像**：
   - 首次注册时，应用会自动从本仓库的 `ios-guest-riscv64` Release 下载预烘焙 Ubuntu 24.04 `riscv64` 镜像（已预装 `deskfleet-daemon`、Node.js、systemd 与 Box64），启动虚拟机、同步宿主机 DNS/代理/时间并完成注册。
   - 全程日志会在注册弹窗的内嵌终端中实时滚动显示。
5. **配置 Agent 与本机设置**：
   - 在 **设置 → Agents** 安装和登录 ACP Agent（支持通过内置 Box64 在 `riscv64` 虚拟机中自动安装运行 `x86_64` 版 Antigravity CLI）。
   - 虚拟机运行期间，可在 **设置** 中直接管理 **远程 Agent** 与 **Worktree** 设置；应用会通过静音音频会话维持后台存活。

## 第三方组件与许可证

Android 与 iOS 内置的全部第三方组件（`proot`、`libtalloc`、`libandroid-shmem`、`scrcpy-server`、`librvvm`、`StikJIT`、`rppairing`/`idevice` 及 RISC-V 固件）的源码地址、修改记录与许可证详见 [`THIRD_PARTY_NOTICES.md`](https://github.com/LemonNekoGH/deskfleet-plus/blob/main/THIRD_PARTY_NOTICES.md)。
