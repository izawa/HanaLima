<p align="center">
  <img src="Resources/AppIcon/AppIcon-1024.png" width="160" alt="HanaLima icon: a plumeria with five petals">
</p>

# HanaLima

[Lima](https://lima-vm.io/) の仮想マシンを、GUI でかんたんに作成・運用できる macOS アプリです。CPU、メモリ、ディスク、ネットワークインターフェースを割り当てて VM を作り、起動・停止・操作できます。仮想 NAT、ホストオンリー、ブリッジのネットワークも、管理者権限なしで作れます。

**Web サイト: [izawa.github.io/HanaLima](https://izawa.github.io/HanaLima/)** · [English README](README.md)

*Hana lima* はハワイ語で「手作り」（*hana*＝作る、*lima*＝手。*lima* には「5」の意味も）。アイコンは、ハワイを象徴する 5 弁の花・プルメリアです。花びらの一枚一枚が、ひとつのネットワークのまわりに手で組み上げていく VM を表しています。

> [!IMPORTANT]
> **HanaLima は非公式の個人プロジェクトです。** Lima プロジェクトおよび Cloud Native Computing Foundation (CNCF) とは関係がなく、公認も支援も受けていません。「Lima」の名前は、このアプリが扱う対象を説明するためだけに使っています。HanaLima の問題は、Lima プロジェクトではなく、このリポジトリに報告してください。

> [!WARNING]
> HanaLima は開発の初期段階です。署名・公証済みのリリースはまだありません。ソースからビルドして使ってください。

## 機能

- **VM の一覧と操作**: Lima のテンプレートからの作成、起動、停止、再起動、削除。`limactl watch` による状態のリアルタイム表示と、イメージのダウンロード進捗の表示。
- **コンソール**: アプリ内のターミナル（`limactl shell`）。VM の準備ができるまで待ってから接続します。
- **設定の編集**: CPU、メモリ、ディスクサイズ、NIC、共有フォルダ、ポート転送をフォームで編集できます。`lima.yaml` 全体も編集でき、Lima の検証を通ります。変更した項目だけを書き戻します。
- **追加ディスク**: 作成、サイズ変更、削除、VM への接続（`limactl disk`）。
- **root 不要の仮想ネットワーク**: サブネットと DHCP 予約（固定 IP）を指定できる NAT とホストオンリー、ホストのインターフェース（例: `en0`）への**ブリッジ**。アプリに同梱した小さなヘルパー（`hanalima-netd`）が macOS 26 の vmnet で提供します。`sudo` も socket_vmnet も不要です。
- **socket_vmnet のセットアップ**（任意、従来方式）: 公式リリースと Lima の sudoers ファイルを、1 回の管理者認証で導入します。
- **メニューバー**: すべての VM の状態、起動・停止、コンソールの呼び出し。ウィンドウを閉じても、メニューバーで動き続けます。
- **ログイン時の自動起動**: VM ごとに `limactl autostart` を切り替えます。
- **スナップショット**（QEMU の VM）: 停止中に、ディスクの状態の保存・復元・削除ができます。
- **画面のサムネイル**（画面を有効にした VZ の VM）: 概要タブに VM の画面を表示します。
- **ログ**: ホストエージェントのログとシリアルコンソールを、検索しながらリアルタイムに見られます。
- **プロビジョニング**: Lima が起動のたびに適用するスクリプトとファイルを編集できます。

## 動作環境

- macOS 26 以降（macOS 27 / Apple Silicon で開発。Intel Mac は未確認）
- Homebrew の [Lima](https://lima-vm.io/) 2.2 以降
- ビルドには Xcode 26 以降と Metal Toolchain（[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) が必要とします）

## クイックスタート

1. Lima と追加のゲストエージェントを入れます。

   ```bash
   brew install lima lima-additional-guestagents
   ```

2. Xcode の Metal Toolchain を入れます（入れていない場合）。

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

3. クローンしてビルドします。スクリプトが `build/HanaLima.app` を作り、この Mac 用に ad-hoc 署名します。

   ```bash
   git clone https://github.com/izawa/HanaLima.git
   cd HanaLima
   scripts/build-app.sh release
   ```

4. 起動します。

   ```bash
   open build/HanaLima.app
   ```

   `/Applications` にインストールして、そこから起動することもできます（動いている HanaLima は先に終了させます）。

   ```bash
   scripts/make-app.sh --install --open
   ```

5. サイドバー下の **＋ 新規仮想マシン** を押し、テンプレート（例: `default`、`alpine`）を選んで作成します。最初の起動時に OS イメージをダウンロードします。

固定 IP やブリッジを使うには、サイドバーの **ネットワーク** で **＋** からネットワークを作り、VM の **設定 → ネットワーク** でそのネットワークの NIC を追加します。

## 仕組み

HanaLima は Lima の Go コードをリンクせず、Lima の公式なインターフェースである `limactl` コマンドを呼び出し、その JSON 出力（`limactl list --format json`、`limactl watch --json`）を読みます。`lima.yaml` の変更は `limactl edit` を通すので、Lima が検証します。

仮想ネットワークは、アプリに同梱したヘルパー `hanalima-netd` が提供します。ネットワークごとに、ソケットアクティベーションを使うユーザーの LaunchAgent として登録します。VM は Lima の `networks: - socket: <パス>`（socket_vmnet のプロトコル）で接続し、ヘルパーがフレームを vmnet のネットワーク（NAT／ホストオンリー）かブリッジのインターフェースに中継します。ヘルパーに root は不要で、`scripts/build-app.sh` が付ける `com.apple.security.virtualization` の entitlement だけが必要です。アプリを起動していなくても、`limactl start` で起動した VM でもネットワークは使えます。

| パス | 内容 |
|---|---|
| `Sources/LimaKit` | `limactl` のラッパー（UI に依存しない） |
| `Sources/NetworkKit` | 仮想ネットワークの定義、LaunchAgent の管理、DHCP 関連 |
| `Sources/hanalima-netd` | ネットワークのヘルパー（Lima のソケット ⇄ vmnet の中継） |
| `Sources/HanaLima` | SwiftUI アプリ |
| `Prototypes/` | ネットワーク調査の実験コード（macOS の vmnet の不具合の再現ツールを含む） |
| `docs/` | 設計メモと調査の記録 |

HanaLima が作るファイル:

- `~/Library/Application Support/HanaLima/` — `networks.json`、配置したヘルパー、ネットワークのソケット
- `~/Library/LaunchAgents/org.izawa.HanaLima.net.<名前>.plist` — 仮想ネットワークごとに 1 つ
- `~/Library/Logs/HanaLima/` — ヘルパーのログ

Lima 自身のファイル（`~/.lima`、ログイン時の自動起動用の `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist`）は `limactl` が管理します。

## 既知の問題

- macOS 27.0.1 の vmnet には不具合があり、HanaLima はそれを回避しています。特に、インターフェースを止めた vmnet ネットワークを再利用すると、ブリッジの `bridge100` を奪い、Mac 本体の IPv4 アドレスが消えることがあります（Apple に FB25122122 として報告済み）。HanaLima はネットワークを再利用しませんが、同時に動くほかの仮想化ツールが再利用する可能性はあります。Mac の IPv4 アドレスが消えたときは、システム設定で DHCP リースを更新する（または `sudo ipconfig set en0 DHCP`）か、Mac を再起動してください。詳細: [docs/02-networking-investigation.md](docs/02-networking-investigation.md)
- Lima 2.2 の制約で、スナップショットは QEMU の VM だけ、スクリーンショットは画面を有効にした VZ の VM（画面ウィンドウが開いているとき）だけで使えます。スナップショットは、実行中に作ると共有フォルダ（9p）があるときに黙って失敗するため、HanaLima では停止中に操作します。
- Wi-Fi へのブリッジは未確認です。

## アンインストール

先にアプリで HanaLima のネットワークを削除し（LaunchAgent の登録が外れます）、アプリとデータを削除します。

```bash
rm -rf ~/Library/Application\ Support/HanaLima ~/Library/Logs/HanaLima
```

LaunchAgent が残っている場合は、`launchctl bootout gui/$(id -u)/org.izawa.HanaLima.net.<名前>` で外し、`~/Library/LaunchAgents` の plist を削除してください。`~/.lima` の VM には触れません。

## 開発

```bash
scripts/build-app.sh                                  # build/HanaLima.app のデバッグビルド
swift test --skip EndToEnd --skip DaemonTermination   # 単体テスト（VM 不要、数秒）
HANALIMA_E2E=1 swift test --filter <スイート名>        # 実際の VM を使う E2E テスト
```

E2E テストは `hanalima-e2e-*` という名前の VM と一時的なネットワークを作り、終わったら削除します。ネットワークのテストには entitlement 付きのヘルパーが必要なので、先に `scripts/build-app.sh` を実行してください。`BridgeEndToEndTests` はホストのインターフェースをブリッジに入れるので、`HANALIMA_E2E_BRIDGE=en0` のようにインターフェースを指定したときだけ動きます。

Mac の再起動後に `metal` が見つからずビルドに失敗する場合は、`swift package clean` してからビルドし直してください。

設計上の判断とその理由は [docs/04-design.md](docs/04-design.md) にあります。

## コントリビューション

Issue とプルリクエストを歓迎します（日本語・英語どちらでも）。大きな変更は、先に Issue で方針を相談してください。

## ライセンス

HanaLima は [MIT License](LICENSE) で公開しています。

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）と [Yams](https://github.com/jpsim/Yams)（MIT）を使っています。Lima（Apache License 2.0）は同梱せず、Mac にインストール済みの `limactl` を呼び出します。

## 作者

Yukimitsu IZAWA — [izawa@izawa.org](mailto:izawa@izawa.org)
