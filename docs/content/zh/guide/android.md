# 在 Android 上运行（Termux）

你可以在 [Termux](https://termux.dev/)（`proot-distro`）中运行独立的 `linux-arm64` 版 `deskfleet-daemon`，将 Android 手机或平板注册为一台完整的 DeskFleet 机器——运行 Agent、PTY 终端、文件传输，并可选开启原生屏幕投屏与触控/键鼠远控。

## 1. 准备 Termux 环境

1. 从 F-Droid 或 GitHub Releases 安装 **Termux**（如需开机自启可一并安装 **Termux:Boot**）。
2. 在系统设置中将 Termux 的电池策略设为**无限制（Unrestricted）**；Android 14 及以上系统请开启**开发者选项 → 停用子进程限制（Disable child process restrictions）**，避免后台 Agent 进程被系统回收。
3. 获取唤醒锁并安装 `aarch64` Linux 容器：

```sh
termux-wake-lock
pkg update && pkg install proot-distro
proot-distro install ubuntu
proot-distro login ubuntu
```

## 2. 安装并注册 `deskfleet-daemon`

在 Ubuntu 容器内执行：

1. 安装基础证书并解压从 [GitHub Releases](https://github.com/yet-another-ai/deskfleet/releases) 下载的 `deskfleet-linux-arm64.tar.gz`：
   ```sh
   apt update && apt install -y ca-certificates
   tar -xzf deskfleet-linux-arm64.tar.gz
   ```
2. 启动后台守护进程，并为你的后端地址与团队生成注册信息包：
   ```sh
   ./deskfleet-daemon &
   ./deskfleet-daemon prepare-enrollment --server-url https://your-backend.example --team-id <TEAM_ID>
   ```
3. 在 DeskFleet 桌面端、Web 端或移动端打开 **添加机器 → 其他机器**，粘贴上一步输出并复制签发的凭证 JSON。
4. 在手机容器内通过标准输入导入凭证：
   ```sh
   ./deskfleet-daemon enroll --server-url https://your-backend.example < machine-credentials.json
   ```

## 3. 开启原生屏幕投屏与远控（可选）

如需从 DeskFleet 远程查看并操控手机屏幕，请下载上游 [`scrcpy-server`](https://github.com/Genymobile/scrcpy/releases) JAR（v2.4+ 或 v3.x），通过 `DESKFLEET_ANDROID_SCRCPY_SERVER` 指定路径，并提供 UID 2000（`shell`）通道：

- **无线调试（`adb`）**：在本机开启无线调试并配对连接（`adb connect 127.0.0.1:<端口>`）。
- **Shizuku 或 Root（`DESKFLEET_ANDROID_SHELL`）**：设置 `DESKFLEET_ANDROID_SHELL="rish -c"`（Shizuku）或 `DESKFLEET_ANDROID_SHELL="su -c"`（Root），切到移动数据网络时也不会因 Wi-Fi ADB 断开而中断投屏。

```sh
export DESKFLEET_ANDROID_SCRCPY_SERVER=/root/scrcpy-server-v3.1
# 可选：自定义 shell 通道、ADB 序列号或协议版本号
# export DESKFLEET_ANDROID_SHELL="rish -c"
./deskfleet-daemon
```

## 4. 配置后台常驻与开机自启

配置一次官方服务组件即可免去每次手动启动：

1. 在 Termux 宿主环境（`proot-distro` 外部）安装 `termux-services` 守护进程：
   ```sh
   pkg install termux-services
   mkdir -p "$PREFIX/var/service/deskfleet"
   cat > "$PREFIX/var/service/deskfleet/run" <<'EOF'
   #!/data/data/com.termux/files/usr/bin/sh
   exec proot-distro login ubuntu -- /root/deskfleet-daemon
   EOF
   chmod +x "$PREFIX/var/service/deskfleet/run"
   sv-enable deskfleet
   ```
2. 安装 **Termux:Boot** 后，在 `~/.termux/boot/deskfleet.sh`（赋予 `chmod +x`）中写入 `termux-wake-lock`，手机重启解锁后即可自动在后台拉起服务。

## 非官方用法：KernelSU（Root）

> [!WARNING]
> **非官方第三方方案，非常不推荐：**
> - 下述 KernelSU 方案来自**非官方第三方 Fork**（[`LemonNekoGH/deskfleet-plus`](https://github.com/LemonNekoGH/deskfleet-plus)），**与 DeskFleet 官方项目及 `deskfleet.org` 没有任何隶属、维护或背书关系**。
> - 这种方法绕过了 Android 应用沙箱，在 `chroot` 环境中授予了**极高的权限（Root）**。通过该方式启动的守护进程、终端及 AI Agent 拥有极高系统访问能力，可能读取、修改甚至破坏设备上的任意数据。
> - **请务必在测试前做好定期完整备份**，切勿在存放个人隐私或重要数据的主力设备上使用。**使用这种方法启动的 Agent 或执行的命令如果造成任何数据损坏、数据丢失或设备故障，`deskfleet.org` 不对此负任何责任。**

如果你在充分了解并自行承担上述全部风险后，仍决定在已安装 [KernelSU](https://kernelsu.org/) 的设备上尝试：

1. 安装第三方构建的 **`DeskFleet (KSU)`** APK（包名 `moe.remon.deskfleet.plus`，与官方 `ai.yetanother.deskfleet` 应用相互独立）。
2. 在 **KernelSU 管理器 → 超级用户** 中为 **DeskFleet (KSU)** 开启 Root 权限。
3. 登录应用并打开 **添加机器 → 此电脑（本机）** 确认注册，应用将自动部署 `/data/adb/deskfleet/rootfs` 与 `deskfleet_daemon` KernelSU 模块。
