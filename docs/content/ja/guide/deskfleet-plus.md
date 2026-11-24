# DeskFleet Plus（モバイル内蔵デーモン）

> [!NOTE]
> **非公式モバイル特化フォークについて：** [`LemonNekoGH/deskfleet-plus`](https://github.com/LemonNekoGH/deskfleet-plus)（**DeskFleet Plus**、アプリ ID `moe.remon.deskfleet.plus`）は、[`yet-another-ai/deskfleet`](https://github.com/yet-another-ai/deskfleet)（`ai.yetanother.deskfleet`）から独立してメンテナンスされているサードパーティ製フォークであり、`deskfleet.org` とは提携・公式サポート関係にありません。

DeskFleet Plus は、**Android** と **iOS** アプリのサンドボックス内に完全な Linux 版 `deskfleet-daemon` を直接組み込んでいます。Root 権限や別途 Termux の構築、デスクトップ PC なしで、スマートフォンやタブレット自体を DeskFleet マシンとしてチームへ登録し、ACP エージェント・PTY ターミナル・Git ワークツリー・ファイル転送・（Android では）リモート画面操作まで完結できます。

## アップストリーム DeskFleet との違い

デスクトップアプリ・中央サーバー・通信プロトコルはアップストリームと同一のまま、**モバイル端末でローカルデーモンを動かす機能**に特化しています：

| 項目 | アップストリーム DeskFleet（`ai.yetanother.deskfleet`） | DeskFleet Plus（`moe.remon.deskfleet.plus`） |
| --- | --- | --- |
| **主な対象** | デスクトップ（macOS / Windows / Linux）、ヘッドレスサーバー、中央サーバー、リモート専用モバイルクライアント | ローカル Linux デーモンを内蔵したモバイルアプリ（Android / iOS） |
| **Android ローカルデーモン** | 外部の Termux（`proot-distro`）へ手動インストール | 非特権 `proot` + Debian `arm64` サンドボックスを内蔵、`deskfleet-daemon` と `scrcpy-server` 同梱、Wake lock 付きフォアグラウンドサービス＆自動更新 |
| **Android ワイヤレス ADB** | 手動で `adb pair` / `adb connect` を実行 | ワイヤレスデバッグ自動検出、通知からのペアリングコード入力、TLS 自動再接続、任意の `tcpip 5555` キープアライブ、設定 UI を内蔵 |
| **iOS ローカルデーモン** | 非対応（クライアント専用） | 純 JIT の `librvvm` RISC-V 64 Linux VM を内蔵、事前構築済み Ubuntu 24.04 `riscv64` イメージ、`StikJIT` ヘルパー、iOS 27+ 端末内 RemotePairing、RAM ドネーション、無音バックグラウンド維持、Box64（`x86_64` Antigravity CLI 対応） |
| **モバイル登録・ホスト設定** | 端末登録 UI はデスクトップのみ、モバイルはホスト設定非表示 | **マシンを追加 → このコンピューター** 内にリアルタイムログ表示ターミナルを搭載、モバイルからも **リモートエージェント**・**ワークツリー** 設定を変更可能 |
| **配布チャネル** | デスクトップインストーラー、DEB/RPM、Nix、AUR、Docker、Google Play、App Store / TestFlight | GitHub Releases の Android APK（およびサイドロード向け iOS IPA）と `ios-guest-riscv64` ゲストイメージ |

## DeskFleet Plus とアップストリームの使い分け

**DeskFleet Plus を使うべきケース：**

- **Android スマホ／タブレット**を Root や Termux なしでワンタップ登録し、マシンとして活用したい。
- Android で `scrcpy` リモート画面操作のための **ワイヤレス ADB** ペアリングや `tcpip 5555` 維持をアプリ内から簡単に管理したい。
- **iPhone / iPad** 上でサイドロード＋JIT を使って実際の Linux `deskfleet-daemon` と ACP エージェントを動かしたい。

**アップストリーム [DeskFleet](https://github.com/yet-another-ai/deskfleet) を使うべきケース：**

- **macOS / Windows / Linux デスクトップアプリ**、**ヘッドレスサーバー用デーモン**、または **セルフホスト用バックエンド**（Docker / Nix / AUR）を利用したい。
- 既存の PC やサーバーへ接続するだけの公式 **Google Play / App Store** クライアントを使いたい。
- Android 上で公式デーモンを Termux 内で手動管理したい。

両者は完全に互換なプロトコルで動作し、既定では同じ `https://deskfleet.yetanother.ai`（またはセルフホストサーバー）に接続します。アプリ ID が分離されているため同一端末に共存でき、同じチーム内でアップストリームの PC と DeskFleet Plus 端末を組み合わせて利用できます。

## DeskFleet Plus の使い方

### Android

1. **インストール**：[DeskFleet Plus Releases](https://github.com/LemonNekoGH/deskfleet-plus/releases) から署名済み `deskfleet-<version>-android-arm64.apk` をダウンロードしてインストールします（パッケージ名 `moe.remon.deskfleet.plus` のため公式版と共存可能です）。
2. **サインインと端末登録**：
   - アプリでチームにサインインし、**マシンを追加 → このコンピューター** を開いて登録を確定します。
   - 組み込みターミナルに進捗が表示され、Debian 13（`trixie`）`arm64` rootfs の取得、同梱の `deskfleet-daemon`・`scrcpy-server` の配置、フォアグラウンドサービスの起動、チーム登録が自動で完了します。
3. **バックグラウンド維持**：フォアグラウンド通知を許可し、Android のバッテリー最適化から DeskFleet Plus を除外してください。
4. **ワイヤレス ADB の設定（任意・リモート画面操作向け）**：
   - Android 設定で **開発者向けオプション → ワイヤレスデバッグ** を有効にします。
   - DeskFleet Plus の **設定 → ワイヤレス ADB** を開き、ペアリングを開始して通知または設定画面からポートと 6 桁コードを入力します。
   - 必要に応じて **`tcpip 5555` を維持** をオンにすると再接続が安定します。
5. **ホスト設定**：**設定** からローカルデーモンの **リモートエージェント権限** や **ワークツリー設定** を直接変更できます。

### iOS / iPadOS

1. **サイドロード**：`DeskFleet Plus` IPA（`moe.remon.deskfleet.plus`）を SideStore / AltStore などの JIT 対応ツールで端末へインストールします。
2. **サインインと登録開始**：チームにサインインし、**マシンを追加 → このコンピューター** を開きます。
3. **JIT 有効化とペアリング**：
   - 内蔵の `librvvm` VM は JIT を必要とします。画面のガイドに従い、**iOS 27+** ではアプリ内の **端末内 RemotePairing**、それ以前の対応バージョンではペアリングファイルの読み込み（内蔵 `DeskFleetJITHelper` / `StikJIT`）または StikDebug で JIT を有効化します（**iOS 26+ TXM 端末**は VM 起動前に `P_TRACED` 状態が必要です）。
4. **ゲストイメージの自動準備**：
   - 初回起動時にフォークの `ios-guest-riscv64` リリースから事前構築済み Ubuntu 24.04 `riscv64` イメージ（`deskfleet-daemon`・Node.js・systemd・Box64 同梱）を自動ダウンロードし、VM を起動して DNS・プロキシ・時刻を同期したうえでチーム登録を完了します。
5. **エージェントと設定の管理**：
   - **設定 → エージェント** から ACP エージェントを導入・認証できます（`x86_64` 版 Antigravity CLI も内蔵 Box64 経由で自動インストール・実行可能）。
   - VM 稼働中は **設定** から **リモートエージェント**・**ワークツリー** 設定を直接変更でき、無音オーディオセッションによりバックグラウンド動作を維持します。

## サードパーティコンポーネントとライセンス

Android / iOS に同梱・利用されるサードパーティコンポーネント（`proot`、`libtalloc`、`libandroid-shmem`、`scrcpy-server`、`librvvm`、`StikJIT`、`rppairing`/`idevice`、RISC-V ファームウェア）のソースおよびライセンスは [`THIRD_PARTY_NOTICES.md`](https://github.com/LemonNekoGH/deskfleet-plus/blob/main/THIRD_PARTY_NOTICES.md) を参照してください。
