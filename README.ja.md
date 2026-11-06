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
- **設定の編集**: CPU、メモリ、ディスクサイズ、NIC、共有フォルダ、ポート転送をフォームで編集できます。`lima.yaml` 全体も編集でき、Lima の検証を通ります。変更した項目だけを書き戻します。VM の実行中は、プロビジョニングのスクリプトも含めて読み取り専用で閲覧できます。プロビジョニングの例（基本ツール一式、自分の dotfiles・公開鍵、Docker Engine、XDP の開発環境、日本向けの設定、自動更新の停止、スワップファイル、開発言語（Go・Node.js・uv・rustup）、一度だけの全パッケージ更新）を、ワンクリックで追加できます（Ubuntu・Fedora と、対応するものは Alpine で確認。最初の 4 つは Debian でも確認）。
- **Mac のファイルを VM から見せない**: Lima は既定で、ホームフォルダを読み取り専用ですべての VM と共有するので、VM から `~/.ssh` などの認証情報を読めます。作成時にこの共有を外せます（`--mount-none`）。AI のコーディングエージェントなど、信頼しきれないものを VM で動かすときに使います。代わりに作業フォルダを 1 つだけ（書き込み可または読み取り専用で）共有でき、VM の中でも同じパスで見えます。隠せるのはファイルで、ネットワークは別です。Lima の標準のネットワークを通じて、VM からインターネット、LAN、Mac の `127.0.0.1` で待ち受けるサービスに届きます（[docs/06](docs/06-isolation-investigation.md)）。ネットワークも切り離すには、HanaLima 自身のドライバーの隔離プロファイル（下記）を使います。
- **追加ディスク**: 作成、サイズ変更、削除、VM への接続（`limactl disk`）。
- **ディスクを外付けドライブに**: VM のディスク（いちばん大きなファイル）を別のドライブへ移して、Mac の空き容量を節約できます。作成時に保存場所を選ぶこともできます。移す前に移動先を確かめ（別のボリューム、APFS、空き容量）、スパースのまま移し、ドライブが外れているときは起動を止め、VM を削除すると移したディスクも削除します。いつでも内蔵に戻せます。
- **使用量**: Lima が VM、ディスク、ダウンロードしたイメージを置いている場所と、それぞれが実際に使っている容量、ダウンロードしたイメージをどの VM が使っているかの表示。どの VM も使っていないイメージの削除（キャッシュ全体は `limactl prune`）。VM ごとのスナップショットの容量と、`limactl` で直接削除した VM が残したスナップショットや外付けのディスクも表示し、削除できます。
- **root 不要の仮想ネットワーク**: サブネットと DHCP 予約（固定 IP）を指定できる NAT とホストオンリー、ホストのインターフェース（例: `en0`）への**ブリッジ**、そして **ゲスト専用**（VM 同士だけで、Mac はセグメントに参加しない。ヘルパーが vmnet を使わずに VM のあいだでフレームを中継し、自前の DHCP は経路を配らず、DNS サーバーとしてヘルパー自身を、検索ドメイン `hanalima` とともに配ります。ヘルパーはそのネットワークの VM の名前（`lima-<名前>`。そのままか `.hanalima` 付き）だけに答え、ほかは拒否するので、NIC 0 もある VM はインターネットの名前を Lima のユーザーモードネットワークで引き続けます。Ubuntu（systemd-resolved）はリンクごとに引き分けます。NIC 0 のある Alpine は cloud-init の resolv.conf（ユーザーモードの DNS だけ）のままなので、ヘルパーに直接問い合わせてください。隔離した Alpine の VM はヘルパーをリゾルバーにします。下の隔離した VM 同士は、これでつながります）。いずれもアプリに同梱した小さなヘルパー（`hanalima-netd`）が提供し、前の 3 つは macOS 26 の vmnet を使います。`sudo` も socket_vmnet も不要です。ネットワークを変更・削除すると、それを使う VM に次の操作を案内します（実行中なら再起動ボタン、削除したネットワークを指す NIC は次の起動前に外すかを確認）。ヘルパーがまだ古いビルドのままの VM にも、ネットワークの保存・削除のときに同じ再起動の印を付けます。
- **Lima の従来方式のネットワーク**: `lima:shared`・`lima:host`・`lima:bridged`（socket_vmnet。Lima の手順で導入）を使う VM も、そのまま動かし、編集できます。socket_vmnet の導入は HanaLima では行いません（HanaLima のネットワークは root 不要です）。
- **メニューバー**: すべての VM の状態、起動・停止、コンソールの呼び出し。ウィンドウを閉じても、メニューバーで動き続けます。
- **ログイン時の自動起動**: VM ごとに `limactl autostart` を切り替えます。
- **スナップショット**: 停止中の VM の状態を保存し、いつでもその状態に戻せます。Lima 2.2 がスナップショットに対応していない VZ の VM は、HanaLima 独自のスナップショット（ディスクの APFS クローン。すぐに終わり、容量はその後に変わった分だけ）を使います。QEMU の VM は Lima のスナップショットを使います。HanaLima のドライバーの VM では `limactl snapshot`（create・apply・delete・list）からも同じスナップショットを扱えます（停止中のみ。タグは空白なしの 1 語）。スナップショットから新しい VM を作ることもできます。
- **インストーラーの ISO から作成**: Lima が起動できるのはクラウドイメージだけですが、HanaLima は Linux のインストーラーの ISO（arm64）からも作れます。空のディスクで VM を作り、HanaLima のドライバー（下記）がインストーラーを専用のウインドウに起動して、そのディスクに直接インストールします。インストーラーはアプリとは別のプロセスで動くので、アプリを終了しても続き、次に開いたときにつながり直します。インストールした OS で仕上げのコマンドを 1 行実行すると Lima に引き渡され、ほかの VM と同じように設定されます（ユーザー、SSH の鍵、ゲストエージェント、共有フォルダ、プロビジョニング）。Ubuntu Server 26.04 で確認済み。インストールが終わった OS には cloud-init が入っている必要があり、仕上げが Ubuntu・Debian・Fedora・Alpine でそれを入れます。作るのは VZ（Lima）の VM で、QEMU には使えません。
- **救出起動**: sshd の設定を誤るなどして Lima（SSH）から届かなくなった VM を、HanaLima のドライバー（下記）が画面とキーボード付きで起動します。画面のコンソールにログインして直し、「Lima で起動」で戻します。NIC は Lima と同じユーザーモードのネットワークなので、インターネットと名前解決も通ります（パッケージの入れ直しができます）。アプリを終了しても VM は動き続け、次に開いたときにつながり直します。VZ の Linux ゲストのみ。Lima はユーザーのパスワードをロックするので、**SSH が壊れる前に保険として**次を済ませておきます。
  1. 設定タブの「プロビジョニング」で「例から追加…」→「コンソールに自動ログイン（画面・シリアル）」を追加して保存する。
  2. いつもの「起動」で一度起動する（プロビジョニングは Lima の起動時に走るので、ここで自動ログインがゲストに入る）。
  3. 以後は、停止中の VM でツールバーの救急箱（救出起動）を押すと、ログイン済みのシェルが画面に出ます。
- **HanaLima 自身の VM ドライバー**（新規作成の既定。Lima の `vz`・`qemu` も選べます）: その 2 つに加えて、HanaLima が同梱する [Lima の外部ドライバー](docs/09-external-driver-investigation.md) `hanalima` で VM を動かせます。VM を Virtualization.framework で動かすのは HanaLima 自身で、イメージ、cloud-init、SSH、ポート転送、`limactl` はこれまでどおり Lima の仕事です。ドライバーが VM を持つことで、Lima の `vz` に無いものが 3 つ付きます: **打ち込めるシリアルコンソール**（コンソールタブにシェルと並んで「シリアル」）、**閉じても開き直せる画面のウインドウ**（概要タブの「画面を開く」）、`limactl screenshot` に頼らない画面のサムネイル。作成画面で「HanaLima のドライバー」を選ぶか、既存の VZ の VM を設定タブの「仮想化方式」で切り替えます（ディスクと EFI の変数ストアは共通なので、戻すのも同じ 1 手順）。SSH はネットワークを介さず vsock を通ります（systemd 256 以降のゲスト（Ubuntu 24.10 以降、Fedora 41 以降）は標準で、Alpine や古い systemd のゲストは HanaLima の起動スクリプトが入れる socat の中継で）。さらに**隔離プロファイル**: 作成時（または設定タブ）で「NIC 0: Lima のユーザーモード NAT」を外すと、VM にはインターネット・LAN・Mac の `127.0.0.1` への経路が一切なくなり、届くのは足した NIC の先（HanaLima のホストオンリーやゲスト専用など）だけになります。SSH・ゲストエージェント・ポート転送は vsock で動きます。systemd 256 以降のゲストはそのまま、Alpine や古い systemd のゲストは NIC 0 を付けて一度起動すると HanaLima の起動スクリプトが socat を入れて同じ経路を作ります。作成画面の「隔離した仮想マシンとして作る」は、これ（ドライバー、NIC 0 なし、共有なし、NIC 1 はゲスト専用ネットワーク）を 1 つのスイッチでまとめて設定し、「最初の 1 回だけ NIC 0 を付けて起動する」を選ぶと、パッケージを入れる初回の起動のあと、最初の停止で自動的に NIC 0 を外します。隔離した VM では apt・dnf が出られないので、プロビジョニングは入れません。隔離中はドライバーが Lima のホストリゾルバーと containerd をメモリ上だけで切り（`lima.yaml` は変えません）、eth0 を optional にし、最初のゲスト専用ネットワークの DNS を VM に渡します。設定タブと概要タブにその注記が出ます。Rosetta は Lima の `vz` と同じく使えます（共有と Lima の起動スクリプト）。HanaLima が Rosetta を勝手に入れることはなく、Mac に無ければ共有なしで起動し、ドライバーのログに入れ方を出します。Lima の `lima:` のネットワークも使えます（socket_vmnet の shared・host・bridged と、NIC 0 の代わりにもなる `lima:user-v2`）。これらの VM では `limactl snapshot` も使えます（「スナップショット」参照）。画面のウインドウには Mac のクリップボードから貼り付けられません（Virtualization.framework の制約）。貼り付けはコンソールタブで行ってください。Alpine・Ubuntu LTS・Fedora・Debian で E2E を確認済み。`hanalima` の VM は HanaLima の入っている Mac でしか起動できません（ほかへ持ち出すときは先に VZ に切り替えます）。HanaLima は起動のたびにドライバーを Lima が探す場所（Homebrew なら `/opt/homebrew/lib/lima/`）に写すので、`LIMA_DRIVERS_PATH` も `sudo` もなしに、ターミナルの `limactl` からもそのまま使えます。ドライバーは、VM が無く、自分を呼んだ Lima のプロセスが消えると自分で終了します。シリアルコンソールからログインするには（sshd を壊した VM に入る、もう 1 つの経路）:
  1. 救出起動と同じく、設定タブで例「コンソールに自動ログイン（画面・シリアル）」を追加して一度起動する（イメージはシリアルポート `hvc0` にログインを置いていないので、これが無いとシリアルは無音です）。
  2. その VM に HanaLima のドライバーを選ぶ（作成時、または停止中に設定タブで）。
  3. 起動してコンソールタブの「シリアル」を開くと、SSH を介さないログイン済みのシェルが出ます。
- **複製**: 停止中の VM を一瞬で複製します（`limactl clone`、APFS のクローン）。名前、ホスト名、MAC アドレス、SSH の鍵は新しくなり、外付けドライブにあるディスクはそのドライブの上で複製します。VM ごとに、コピー元、コピー、メモを表示します。
- **画面のサムネイル**（画面を有効にした VZ の VM と、HanaLima のドライバーの VM（ドライバー経由））: 概要タブに VM の画面をライブで表示します。
- **ログ**: ホストエージェントのログとシリアルコンソールを、検索しながらリアルタイムに見られます。
- **プロビジョニング**: Lima が起動のたびに適用するスクリプトとファイルを編集できます。**今すぐ実行**は、項目や例を保存せずに実行中の VM で走らせて出力を表示します。**一度だけ実行する**にすると、成功したら印を残して以後の起動では飛ばします（失敗は次の起動で再試行。「もう一度実行」で印を新しくします）。
- **Mac から Ansible**: VM に Playbook を選んで、設定タブから実行できます。出力はシートに流れます。HanaLima は Lima の `ssh.config` を通る ssh のインベントリ（グループ `[hanalima]`、ホスト `lima-<名前>`）を書き、お使いの `ansible-playbook`（`brew install ansible` か `pip install ansible`）を Playbook のフォルダで起動するので、隣の roles や `ansible.cfg` がそのまま効きます。`become` は設定なしで使えます（Lima がパスワード無しの sudo を用意しています）。同じインベントリはターミナルからも使えます: `ansible-playbook -i ~/Library/Application\ Support/HanaLima/ansible/inventory.ini …`。
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

5. サイドバー下の **＋ 新規仮想マシン** を押し、テンプレート（例: `default`、`alpine`）を選んで作成します。新しい VM は既定で HanaLima のドライバーで動きます。最初の起動時に OS イメージをダウンロードします。

固定 IP やブリッジを使うには、サイドバーの **ネットワーク** で **＋** からネットワークを作り、VM の **設定** タブのネットワーク欄にある **NIC を追加** で、そのネットワークを選びます。

### 表示言語

優先する言語が日本語なら日本語で、それ以外なら英語で表示します。HanaLima だけ別の言語にするには、システム設定 → 一般 → 言語と地域 → アプリケーション で選ぶか、次のように起動します。

```bash
open build/HanaLima.app --args -AppleLanguages '(en)'
```

## 仕組み

HanaLima は Lima の Go コードをリンクせず、Lima の公式なインターフェースである `limactl` コマンドを呼び出し、その JSON 出力（`limactl list --format json`、`limactl watch --json`）を読みます。`lima.yaml` の変更は `limactl edit` を通すので、Lima が検証します。

仮想ネットワークは、アプリに同梱したヘルパー `hanalima-netd` が提供します。ネットワークごとに、ソケットアクティベーションを使うユーザーの LaunchAgent として登録します。VM は Lima の `networks: - socket: <パス>`（socket_vmnet のプロトコル）で接続し、ヘルパーがフレームを vmnet のネットワーク（NAT／ホストオンリー）かブリッジのインターフェースに中継します。ゲスト専用のネットワークでは、vmnet を使わずにヘルパー自身が VM のあいだでフレームを中継します。ヘルパーに root は不要で、`scripts/build-app.sh` が付ける `com.apple.security.virtualization` の entitlement だけが必要です。アプリを起動していなくても、`limactl start` で起動した VM でもネットワークは使えます。

| パス | 内容 |
|---|---|
| `Sources/LimaKit` | `limactl` のラッパー（UI に依存しない） |
| `Sources/NetworkKit` | 仮想ネットワークの定義、LaunchAgent の管理、DHCP 関連 |
| `Sources/hanalima-netd` | ネットワークのヘルパー（Lima のソケット ⇄ vmnet の中継／ゲスト専用のスイッチ） |
| `Sources/HanaLima` | SwiftUI アプリ |
| `Driver/` | Lima の外部ドライバー `lima-driver-hanalima`（vmType `hanalima`） |
| `Prototypes/` | ネットワーク調査の実験コード（macOS の vmnet の不具合の再現ツールを含む） |
| `docs/` | 設計メモと調査の記録 |

HanaLima が作るファイル:

- `~/Library/Application Support/HanaLima/` — `networks.json`、配置したヘルパー、ネットワークのソケット
- `~/Library/LaunchAgents/org.izawa.HanaLima.net.<名前>.plist` — 仮想ネットワークごとに 1 つ
- `~/Library/Logs/HanaLima/` — ヘルパーのログ
- `<prefix>/lib/lima/lima-driver-hanalima`（Homebrew なら `/opt/homebrew/lib/lima/`）— VM のドライバー。起動のたびに写します

Lima 自身のファイル（`~/.lima`、イメージのキャッシュ `~/Library/Caches/lima`、ログイン時の自動起動用の `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist`）は `limactl` が管理します。サイドバーの **ストレージ → 使用量** で確認できます。

## 既知の問題

- macOS 27.0.1 の vmnet には不具合があり、HanaLima はそれを回避しています。特に、インターフェースを止めた vmnet ネットワークを再利用すると、ブリッジの `bridge100` を奪い、Mac 本体の IPv4 アドレスが消えることがあります（Apple に FB25122122 として報告済み）。HanaLima はネットワークを再利用しませんが、同時に動くほかの仮想化ツールが再利用する可能性はあります。Mac の IPv4 アドレスが消えたときは、システム設定で DHCP リースを更新する（または `sudo ipconfig set en0 DHCP`）か、Mac を再起動してください。詳細: [docs/02-networking-investigation.md](docs/02-networking-investigation.md)
- Lima 2.2 の制約で、Lima のスナップショットは QEMU の VM だけ（VZ の VM は HanaLima 独自のもの）、スクリーンショットは画面を有効にした VZ の VM（画面ウィンドウが開いているとき）だけで使えます。スナップショットは、実行中に作ると共有フォルダ（9p）があるときに黙って失敗するため、HanaLima では停止中に操作します。HanaLima のドライバーの VM にはこの制約がなく、`limactl snapshot` もサムネイルもドライバーを通して動きます。
- Wi-Fi へのブリッジは、手元の環境では動きました（`en1` 経由で VM が LAN のアドレスを取得）。ただし、1 台の端末から複数の MAC アドレスが出ることを拒むアクセスポイントもあります。Wi-Fi のブリッジで VM にアドレスが付かないときは、有線のインターフェースを試してください。

## アンインストール

先にアプリで、HanaLima のドライバーの VM があれば設定タブで VZ に切り替え（ドライバーが無いと起動できなくなります）、HanaLima のネットワークを削除し（LaunchAgent の登録が外れます）、それからアプリとデータとドライバーのコピー（Homebrew なら `/opt/homebrew/lib/lima/`）を削除します。

```bash
rm -rf ~/Library/Application\ Support/HanaLima ~/Library/Logs/HanaLima /opt/homebrew/lib/lima/lima-driver-hanalima
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
