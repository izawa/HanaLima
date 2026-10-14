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

- **VM の一覧と操作**: Lima のテンプレート（ディストリビューションごとに「Ubuntu 24.04 LTS」のような名前で表示）からの作成、起動、停止、再起動、削除。`limactl watch` による状態のリアルタイム表示と、イメージのダウンロード進捗（割合・速度・残り時間）の表示。
- **コンソール**: アプリ内のターミナル（`limactl shell`）。VM の準備ができるまで待ってから接続します。
- **設定の編集**: CPU、メモリ、ディスクサイズ、NIC、共有フォルダ、ポート転送をフォームで編集できます。`lima.yaml` 全体も編集でき、Lima の検証を通ります。変更した項目だけを書き戻します。VM の実行中は、プロビジョニングのスクリプトも含めて読み取り専用で閲覧できます。プロビジョニングの例（基本ツール一式、自分の dotfiles・公開鍵、Docker Engine、XDP の開発環境）を、ワンクリックで追加できます（Ubuntu・Debian・Fedora と、対応するものは Alpine で確認）。
- **Mac のファイルを VM から見せない**: Lima は既定で、ホームフォルダを読み取り専用ですべての VM と共有するので、VM から `~/.ssh` などの認証情報を読めます。作成時にこの共有を外せます（`--mount-none`）。AI のコーディングエージェントなど、信頼しきれないものを VM で動かすときに使います。代わりに作業フォルダを 1 つだけ（書き込み可または読み取り専用で）共有でき、VM の中でも同じパスで見えます。隠せるのはファイルで、ネットワークは別です。Lima の標準のネットワークを通じて、VM からインターネット、LAN、Mac の `127.0.0.1` で待ち受けるサービスに届きます（[docs/06](docs/06-isolation-investigation.md)）。
- **追加ディスク**: 作成、サイズ変更、削除、VM への接続（`limactl disk`）。
- **ディスクを外付けドライブに**: VM のディスク（いちばん大きなファイル）を別のドライブへ移して、Mac の空き容量を節約できます。作成時に保存場所を選ぶこともできます。移す前に移動先を確かめ（別のボリューム、APFS、空き容量）、スパースのまま移し、ドライブが外れているときは起動を止め、VM を削除すると移したディスクも削除します。いつでも内蔵に戻せます。
- **使用量**: Lima が VM、ディスク、ダウンロードしたイメージを置いている場所と、それぞれが実際に使っている容量、ダウンロードしたイメージをどの VM が使っているかの表示。どの VM も使っていないイメージの削除（キャッシュ全体は `limactl prune`）。VM ごとのスナップショットの容量と、`limactl` で直接削除した VM が残したスナップショットや外付けのディスクも表示し、削除できます。
- **root 不要の仮想ネットワーク**: サブネットと DHCP 予約（固定 IP）を指定できる NAT とホストオンリー、ホストのインターフェース（例: `en0`）への**ブリッジ**。アプリに同梱した小さなヘルパー（`hanalima-netd`）が macOS 26 の vmnet で提供します。`sudo` も socket_vmnet も不要です。ネットワークを変更・削除すると、それを使う VM に次の操作を案内します（実行中なら再起動ボタン、削除したネットワークを指す NIC は次の起動前に外すかを確認）。
- **Lima の従来方式のネットワーク**: `lima:shared`・`lima:host`・`lima:bridged`（socket_vmnet。Lima の手順で導入）を使う VM も、そのまま動かし、編集できます。socket_vmnet の導入は HanaLima では行いません（HanaLima のネットワークは root 不要です）。
- **メニューバー**: すべての VM の状態、起動・停止、コンソールの呼び出し。ウィンドウを閉じても、メニューバーで動き続けます。
- **ログイン時の自動起動**: VM ごとに `limactl autostart` を切り替えます。
- **スナップショット**: 停止中の VM の状態を保存し、いつでもその状態に戻せます。Lima 2.2 がスナップショットに対応していない VZ の VM は、HanaLima 独自のスナップショット（ディスクの APFS クローン。すぐに終わり、容量はその後に変わった分だけ）を使います。QEMU の VM は Lima のスナップショットを使います。スナップショットから新しい VM を作ることもできます。
- **複製**: 停止中の VM を一瞬で複製します（`limactl clone`、APFS のクローン）。名前、ホスト名、MAC アドレス、SSH の鍵は新しくなり、外付けドライブにあるディスクはそのドライブの上で複製します。VM ごとに、コピー元、コピー、メモを表示します。
- **画面のサムネイル**（画面を有効にした VZ の VM）: 概要タブに VM の画面を表示します。
- **ログ**: ホストエージェントのログとシリアルコンソールを、検索しながらリアルタイムに見られます。
- **プロビジョニング**: Lima が起動のたびに適用するスクリプトとファイルを編集できます。
- **英語と日本語の UI**: macOS の言語設定に合わせて表示します。

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

固定 IP やブリッジを使うには、サイドバーの **ネットワーク** で **＋** からネットワークを作り、VM の **設定** タブのネットワーク欄にある **NIC を追加** で、そのネットワークを選びます。

### 表示言語

優先する言語が日本語なら日本語で、それ以外なら英語で表示します。HanaLima だけ別の言語にするには、システム設定 → 一般 → 言語と地域 → アプリケーション で選ぶか、次のように起動します。

```bash
open build/HanaLima.app --args -AppleLanguages '(en)'
```

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

Lima 自身のファイル（`~/.lima`、イメージのキャッシュ `~/Library/Caches/lima`、ログイン時の自動起動用の `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist`）は `limactl` が管理します。サイドバーの **ストレージ → 使用量** で確認できます。

## 既知の問題

- macOS 27.0.1 の vmnet には不具合があり、HanaLima はそれを回避しています。特に、インターフェースを止めた vmnet ネットワークを再利用すると、ブリッジの `bridge100` を奪い、Mac 本体の IPv4 アドレスが消えることがあります（Apple に FB25122122 として報告済み）。HanaLima はネットワークを再利用しませんが、同時に動くほかの仮想化ツールが再利用する可能性はあります。Mac の IPv4 アドレスが消えたときは、システム設定で DHCP リースを更新する（または `sudo ipconfig set en0 DHCP`）か、Mac を再起動してください。詳細: [docs/02-networking-investigation.md](docs/02-networking-investigation.md)
- Lima 2.2 の制約で、Lima のスナップショットは QEMU の VM だけ（VZ の VM は HanaLima 独自のもの）、スクリーンショットは画面を有効にした VZ の VM（画面ウィンドウが開いているとき）だけで使えます。スナップショットは、実行中に作ると共有フォルダ（9p）があるときに黙って失敗するため、HanaLima では停止中に操作します。
- Wi-Fi へのブリッジは、手元の環境では動きました（`en1` 経由で VM が LAN のアドレスを取得）。ただし、1 台の端末から複数の MAC アドレスが出ることを拒むアクセスポイントもあります。Wi-Fi のブリッジで VM にアドレスが付かないときは、有線のインターフェースを試してください。

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

### 多言語対応

UI は英語と日本語に対応しています。元の文字列は日本語で、英訳は String Catalog（`Resources/Localizable.xcstrings`、Xcode でも開けます）にあります。SwiftPM でビルドしているため、文字列はスクリプトから Swift コンパイラーで抽出します。

```bash
scripts/update-strings.sh    # Sources/ から文字列を抽出してカタログに反映する
scripts/check-strings.py     # 翻訳されない日本語のリテラルを一覧にする
```

SwiftUI にリテラルで渡す文字列（`Text("…")`、`Button("…")`）は自動で翻訳されます。コードで組み立てる文字列は `String(localized: "…")` にしてください。`LabeledContent(_:value:)` の value は翻訳されないので、`LabeledContent("…") { Text("…") }` を使います。

設計上の判断とその理由は [docs/04-design.md](docs/04-design.md) にあります。

## コントリビューション

Issue とプルリクエストを歓迎します（日本語・英語どちらでも）。大きな変更は、先に Issue で方針を相談してください。

## ライセンス

HanaLima は [MIT License](LICENSE) で公開しています。

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）と [Yams](https://github.com/jpsim/Yams)（MIT）を使っています。Lima（Apache License 2.0）は同梱せず、Mac にインストール済みの `limactl` を呼び出します。

## 作者

Yukimitsu IZAWA — [izawa@izawa.org](mailto:izawa@izawa.org)
