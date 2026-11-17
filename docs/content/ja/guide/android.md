# Android で実行する（Termux）

[Termux](https://termux.dev/)（`proot-distro`）内でスタンドアロンの `linux-arm64` 版 `deskfleet-daemon` を実行すると、Android スマートフォンやタブレットを DeskFleet マシンとして登録できます。エージェント、PTY ターミナル、ファイル転送に加え、任意のネイティブ画面ストリーミングとタッチ／キーボード遠隔操作にも対応します。

## 1. Termux の準備

1. F-Droid または GitHub Releases から **Termux**（自動起動する場合は **Termux:Boot** も）をインストールします。
2. Android の設定で Termux のバッテリー使用量を**制限なし（Unrestricted）**にし、Android 14 以降では**開発者向けオプション → 子プロセスの制限を無効にする（Disable child process restrictions）**を有効にします。
3. Wake lock を取得し、`aarch64` Linux コンテナを作成します：

```sh
termux-wake-lock
pkg update && pkg install proot-distro
proot-distro install ubuntu
proot-distro login ubuntu
```

## 2. `deskfleet-daemon` のインストールと登録

Ubuntu コンテナ内で次を実行します：

1. ルート証明書を導入し、[GitHub Releases](https://github.com/yet-another-ai/deskfleet/releases) からダウンロードした `deskfleet-linux-arm64.tar.gz` を展開します：
   ```sh
   apt update && apt install -y ca-certificates
   tar -xzf deskfleet-linux-arm64.tar.gz
   ```
2. デーモンを起動し、接続先バックエンドとチーム用の登録バンドルを生成します：
   ```sh
   ./deskfleet-daemon &
   ./deskfleet-daemon prepare-enrollment --server-url https://your-backend.example --team-id <TEAM_ID>
   ```
3. DeskFleet のデスクトップ、Web、またはモバイルクライアントで **マシンを追加 → 別のマシン** を開き、出力を貼り付けて発行された認証情報 JSON を保存します。
4. 標準入力から認証情報を取り込みます：
   ```sh
   ./deskfleet-daemon enroll --server-url https://your-backend.example < machine-credentials.json
   ```

## 3. 画面ストリーミングと遠隔操作を有効にする（任意）

DeskFleet から Android の画面を表示・操作するには、上流の [`scrcpy-server`](https://github.com/Genymobile/scrcpy/releases) JAR（v2.4+ または v3.x）を `DESKFLEET_ANDROID_SCRCPY_SERVER` に指定し、UID 2000（`shell`）経路を用意します：

- **ワイヤレスデバッグ（`adb`）**：端末でワイヤレスデバッグをペアリングし、ループバック接続します（`adb connect 127.0.0.1:<port>`）。
- **Shizuku または Root（`DESKFLEET_ANDROID_SHELL`）**：`DESKFLEET_ANDROID_SHELL="rish -c"`（Shizuku）または `DESKFLEET_ANDROID_SHELL="su -c"`（Root）を設定すると、モバイルデータ通信でも Wi-Fi ADB なしでストリーミングを維持できます。

```sh
export DESKFLEET_ANDROID_SCRCPY_SERVER=/root/scrcpy-server-v3.1
# 任意：シェル経路、ADB シリアル、プロトコルバージョンの指定
# export DESKFLEET_ANDROID_SHELL="rish -c"
./deskfleet-daemon
```

## 4. バックグラウンド常駐と自動起動

毎回手動で起動せずに済むよう、`termux-services` と **Termux:Boot** を設定できます：

1. Termux 本体（`proot-distro` の外）で `runit` サービスを登録します：
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
2. **Termux:Boot** をインストールし、`~/.termux/boot/deskfleet.sh`（`chmod +x`）に `termux-wake-lock` を記載すると、再起動後のロック解除時にバックグラウンドで自動起動します。

## 非公式の方法：KernelSU（Root）

> [!WARNING]
> **非公式のサードパーティ製手法であり、使用は強く非推奨です：**
> - 以下の KernelSU 手法は**非公式のサードパーティ製フォーク**（[`LemonNekoGH/deskfleet-plus`](https://github.com/LemonNekoGH/deskfleet-plus)）に基づくものであり、**公式の DeskFleet プロジェクトおよび `deskfleet.org` とは一切関係がなく、公式サポート・保証の対象外です**。
> - この手法は Android のアプリサンドボックスを回避し、`chroot` 環境に**極めて高い権限（Root 権限）**を付与します。この方法で起動したデーモン、ターミナル、および AI エージェントは端末全体に対して極めて強い権限を持つことになります。
> - **利用前に必ず定期的なバックアップを取得してください。** 重要なデータを含むメイン端末での使用は避けてください。**この方法で起動したエージェントやコマンドによって生じたデータの破損・消失、その他の損害について、`deskfleet.org` は一切の責任を負いません。**

上記のリスクを完全に理解し自己責任で [KernelSU](https://kernelsu.org/) 環境に導入する場合：

1. サードパーティ製の **`DeskFleet (KSU)`** APK（`moe.remon.deskfleet.plus`、公式版 `ai.yetanother.deskfleet` とは別アプリ）をインストールします。
2. **KernelSU マネージャー → スーパーユーザー** から **DeskFleet (KSU)** にルート権限を付与します。
3. アプリにログインして **マシンを追加 → このコンピューター** を開き登録を確定すると、`/data/adb/deskfleet/rootfs` と `deskfleet_daemon` KernelSU モジュールが自動的に展開・導入されます。
