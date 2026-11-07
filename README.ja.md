<p align="center">
  <img src="Resources/AppIcon/AppIcon-1024.png" width="160" alt="HanaLima icon: a plumeria with five petals">
</p>

# HanaLima

[Lima](https://lima-vm.io/) の VM を GUI で手軽に作成・運用する macOS アプリです。CPU、メモリ、ディスク、ネットワークインターフェースを割り当てて VM を作り、起動・停止・操作まで行えます。仮想 NAT、ホストオンリー、ブリッジのネットワークも管理者権限なしで作れます。

**Web サイト: [izawa.github.io/HanaLima](https://izawa.github.io/HanaLima/)** · [English README](README.md)

*Hana lima* はハワイ語で「手作り」。*hana* は作る、*lima* は手で、*lima* には「5」の意味もあります。アイコンはハワイを象徴する 5 弁の花、プルメリアにしました。ひとつのネットワークにつながる VM を手で組み上げていく様子を、花びらの一枚一枚で表しています。

> [!IMPORTANT]
> **HanaLima は非公式の個人プロジェクトです。** Lima プロジェクトおよび Cloud Native Computing Foundation (CNCF) とは関係がなく、公認も支援も受けていません。「Lima」という名前はアプリが何を扱うかを説明するためだけに使っています。HanaLima の問題の報告先はこのリポジトリです。Lima プロジェクトへの報告は避けてください。

> [!WARNING]
> HanaLima はまだ開発の初期段階で、署名・公証済みのリリースはありません。ソースからビルドして使ってください。

## 機能

- **VM の一覧と操作**: Lima のテンプレートからの作成、起動、停止、再起動、削除。テンプレートはディストリビューションごとに「Ubuntu 24.04 LTS」のような名前で表示します。`limactl watch` で状態をリアルタイムに反映し、イメージのダウンロード中は進捗の割合・速度・残り時間も表示します。
- **コンソール**: アプリ内のターミナル（`limactl shell`）。VM の準備ができるまで待ってから接続します。
- **設定の編集**: CPU、メモリ、ディスクサイズ、NIC、共有フォルダ、ポート転送をフォームで編集。`lima.yaml` 全体の編集にも対応し、Lima で検証してから変更した項目だけを書き戻します。VM の実行中はプロビジョニングのスクリプトも含めて読み取り専用で確認できます。プロビジョニングの例もワンクリックで追加できます。基本ツール一式、自分の dotfiles・公開鍵、Docker Engine、XDP の開発環境、日本向けの設定、自動更新の停止、スワップファイル、開発言語（Go・Node.js・uv・rustup）、一度だけの全パッケージ更新、コンソールへの自動ログイン、出口を絞るゲートウェイ（ゲスト専用ネットワークの「ルーター」にする VM 用。後ろの VM に NAT と DNS を与え、許可リストの先だけ通します）を用意しています。Ubuntu・Fedora と、対応するものは Alpine で確認済み。最初の 4 つは Debian でも確認しています。
- **Mac のファイルを VM から見せない**: Lima は既定でホームフォルダを読み取り専用ですべての VM と共有します。そのため VM から `~/.ssh` などの認証情報も読めます。HanaLima では作成時にこの共有を外せます（`--mount-none`）。AI のコーディングエージェントなど、信頼しきれないものを VM で動かすときのための設定です。代わりに作業フォルダを 1 つだけ共有でき、書き込み可・読み取り専用を選べます。VM の中でもパスは同じです。この設定で隠せるのはファイルだけで、ネットワークは別に考える必要があります。Lima の標準のネットワークでは VM からインターネット、LAN、Mac の `127.0.0.1` で待ち受けるサービスに届きます（[docs/06](docs/06-isolation-investigation.md)）。ネットワークも切り離す場合は、下記の HanaLima 自身のドライバーの隔離プロファイルを使います。
- **追加ディスク**: 作成、サイズ変更、削除、VM への接続（`limactl disk`）。
- **ディスクを外付けドライブに**: VM でいちばん大きなファイルであるディスクを別のドライブへ移して、Mac の空き容量を節約できます。作成時の保存場所としても選べます。移動前に別のボリュームか、APFS か、空き容量が足りるかを確認し、スパースのまま移します。ドライブが外れている間は VM を起動させません。VM を削除すると移動先のディスクも削除します。いつでも内蔵ドライブに戻せます。
- **使用量**: VM、ディスク、ダウンロードしたイメージを Lima がどこに置いているか、実際にどれだけ容量を使っているかを表示します。イメージを使っている VM も確認でき、どの VM も使っていないイメージは削除できます。キャッシュ全体の削除は `limactl prune`。VM ごとのスナップショットの容量も表示します。`limactl` で直接削除した VM のスナップショットや外付けディスクが残っていれば、それらの確認・削除もできます。
- **root 不要の仮想ネットワーク**: サブネットと DHCP 予約（固定 IP）を指定できる NAT とホストオンリー、ホストのインターフェース（例: `en0`）への**ブリッジ**、VM 同士だけをつなぐ **ゲスト専用** の 4 種類。どれも同梱の小さなヘルパー `hanalima-netd` が提供し、ゲスト専用以外は macOS 26 の vmnet を使います。`sudo` も socket_vmnet も要りません。ゲスト専用のネットワークには Mac は参加せず、ヘルパーが vmnet を使わずに VM 間でフレームを中継します。下記の隔離した VM 同士は、このネットワークでつながります。ヘルパーの DHCP は、DNS サーバーとしてヘルパー自身と検索ドメイン `hanalima` を配ります。経路は、ネットワークに「ルーター」（そのネットワーク上の VM のアドレス）を指定したときだけ配り、その VM を DNS の 2 番目にも並べます。隔離した VM 群を、外に通じる VM 1 台の後ろに置く構成に使います。この DNS が答えるのは、そのネットワークの VM の名前（`lima-<名前>`。`.hanalima` を付けても可）だけです。ほかの名前には REFUSED を返し、リゾルバーは次のサーバーへ進むので、NIC 0 もある VM はインターネットの名前を Lima のユーザーモードネットワークの DNS で引けます。Ubuntu（systemd-resolved）はリンクごとに問い合わせ先を分けるのでそのまま使えます。Alpine は NIC 0 があると cloud-init が書いた resolv.conf（ユーザーモードの DNS だけ）が残るので、ヘルパーの DNS にはサーバーを指定して問い合わせます。隔離した Alpine の VM はヘルパーをリゾルバーにします。ネットワークを変更・削除すると、それを使う VM に必要な操作を案内します。実行中なら再起動ボタンを出し、削除したネットワークを指す NIC は次の起動前に外すか確認します。古いビルドのヘルパーが動いたままの VM にも、ネットワークの保存・削除時に同じ再起動の印を付けます。
- **Lima の従来方式のネットワーク**: `lima:shared`・`lima:host`・`lima:bridged` を使う VM もそのまま動かし、編集できます。これらに必要な socket_vmnet は Lima の手順で導入してください。HanaLima は導入を行いません。HanaLima 自身のネットワークなら root は要りません。
- **メニューバー**: すべての VM の状態確認、起動・停止、コンソールの呼び出し。ウィンドウを閉じてもメニューバーで動き続けます。
- **ログイン時の自動起動**: VM ごとに `limactl autostart` を切り替えます。
- **スナップショット**: 停止中の VM の状態を保存して、いつでもその状態に戻せます。Lima は 2.3 でも VZ のスナップショットに対応していないため、VZ の VM には HanaLima 独自のスナップショットを使います。ディスクの APFS クローンなので保存はすぐに終わり、容量はその後に変わった分だけです。QEMU の VM は Lima のスナップショットを使います。HanaLima のドライバーの VM では `limactl snapshot`（create・apply・delete・list）からも同じものを扱えます。停止中のみで、タグは空白なしの 1 語。スナップショットから新しい VM も作れます。
- **インストーラーの ISO から作成**: Lima が起動できるのはクラウドイメージだけですが、HanaLima では Linux のインストーラーの ISO（arm64）からも VM を作れます。空のディスクで VM を作り、下記の HanaLima のドライバーで専用ウインドウにインストーラーを起動して、そのディスクへ直接インストールします。インストーラーはアプリとは別のプロセスで動くので、アプリを終了しても続行します。次にアプリを開くと再接続します。インストールした OS で仕上げのコマンドを 1 行実行すれば Lima に引き渡され、ユーザー、SSH の鍵、ゲストエージェント、共有フォルダ、プロビジョニングがほかの VM と同じように設定されます。Ubuntu Server 26.04 で確認済み。インストール後の OS には cloud-init が必要で、Ubuntu・Debian・Fedora・Alpine では仕上げの処理で入れます。作成するのは VZ（Lima）の VM で、QEMU には使えません。
- **救出起動**: sshd の設定ミスなどで Lima（SSH）から接続できなくなった VM を、下記の HanaLima のドライバーで画面とキーボード付きで起動します。画面のコンソールにログインして修正し、「Lima で起動」で通常の起動に戻します。NIC は Lima と同じユーザーモードのネットワーク。インターネットと名前解決も使えるので、パッケージの入れ直しもできます。アプリを終了しても VM は動き続け、次にアプリを開くと再接続します。VZ の Linux ゲストのみ対応。Lima はユーザーのパスワードをロックするので、**SSH が壊れる前に保険として**次を済ませておきます。
  1. 設定タブの「プロビジョニング」で「例から追加…」→「コンソールに自動ログイン（画面・シリアル）」を追加して保存する。
  2. 通常の「起動」で一度起動する（Lima の起動時にプロビジョニングが走り、ゲストに自動ログインが設定されます）。
  3. 以後は停止中の VM でツールバーの救急箱（救出起動）を押すと、ログイン済みのシェルが画面に出ます。
- **HanaLima 自身の VM ドライバー**（新規作成の既定）: Lima の `vz`・`qemu` に加えて、同梱の [Lima の外部ドライバー](docs/09-external-driver-investigation.md) `hanalima` で VM を動かせます。ドライバーのプロセスで動くのは VM 本体だけで、イメージ、cloud-init、SSH、ポート転送、`limactl` は Lima が担当します。`vz`・QEMU も選べます。既存の VZ の VM との切り替えは設定タブで 1 手順。ディスクと EFI の変数ストアは共通です。
  - **双方向のシリアルコンソール**: コンソールタブのシェルと並ぶ「シリアル」で、読むだけでなく入力もできます。sshd を壊した VM に入るための、救出起動とは別のもう 1 つの経路です。手順は下記。
  - **閉じても開き直せる画面**（概要タブの「画面を開く」）と、`limactl screenshot` を使わないサムネイル。Virtualization.framework の制約で、画面には Mac のクリップボードから貼り付けられません。貼り付けにはコンソールタブを使います。
  - **SSH は vsock**: ネットワークを介しません。systemd 256 以降のゲスト（Ubuntu 24.10 以降、Fedora 41 以降）はそのまま。Alpine や古い systemd は、NIC 0 付きで一度起動すると HanaLima の起動スクリプトが socat の中継を入れます。
  - **隔離プロファイル**: 「NIC 0: Lima のユーザーモード NAT」を外すと、VM からインターネット・LAN・Mac の `127.0.0.1` への経路がなくなります。届くのは追加した NIC の先だけで、HanaLima のホストオンリーやゲスト専用などを使えます。SSH・ゲストエージェント・ポート転送は vsock で動きます。作成画面の「隔離した仮想マシンとして作る」という 1 つのスイッチでまとめて設定できます。「最初の 1 回だけ NIC 0 を付けて起動する」を選ぶと、最初の停止時に NIC 0 が自動で外れます。隔離中はドライバーが hostResolver と containerd を切り、eth0 を optional にして、DNS をゲスト専用ネットワークのものにします。この変更は `lima.yaml` には書かず、設定タブと概要タブに注記を出します。apt・dnf は外に出られないので、プロビジョニングは入れません。
  - **Lima と同じに使えるもの**: Rosetta は Mac に入っていなければ共有なしで起動し、ログに案内を出します。自動では入れません。`lima:` ネットワークは socket_vmnet の shared・host・bridged と、NIC 0 としての user-v2 に対応。`limactl snapshot`（create・apply・delete・list）はアプリと同じ APFS クローンを使います。停止中のみで、タグは 1 語です。
  - **ターミナルの `limactl` からも**: HanaLima の起動時に毎回、Lima がドライバーを探す場所へコピーします。Homebrew なら `/opt/homebrew/lib/lima/` です。`LIMA_DRIVERS_PATH` も sudo も不要。VM がなくなり、ドライバーを起動した Lima のプロセスも終了すると、ドライバーは自分で終了します。
  - HanaLima のない Mac では起動できません。別の Mac に移すなら、先に VZ に戻しておきます。Alpine・Ubuntu LTS・Fedora・Debian で E2E 確認済み。
  - シリアルコンソールからログインするには:
    1. 救出起動と同じく、設定タブで例「コンソールに自動ログイン（画面・シリアル）」を追加して一度起動する。イメージにはシリアルポート `hvc0` のログインが用意されていないので、この設定がないとシリアルには何も出ません。
    2. 作成時、または停止中の設定タブで、その VM のドライバーに HanaLima を選ぶ。
    3. 起動してコンソールタブの「シリアル」を開くと、SSH を介さないログイン済みのシェルが出ます。
- **複製**: `limactl clone` と APFS のクローンで、停止中の VM を一瞬で複製します。名前、ホスト名、MAC アドレス、SSH の鍵は新しくなります。ディスクを外付けに移した VM でも、コピーは元とディスクを共有せず、同じ外付けの上に自分のディスクを持ちます。VM ごとにコピー元、コピー、メモを表示します。
- **画面のサムネイル**: 概要タブに VM の画面をライブで表示します。対象は画面を有効にした VZ の VM と、HanaLima のドライバーの VM（こちらはドライバー経由）です。
- **ログ**: ホストエージェントのログとシリアルコンソールをリアルタイムに表示。検索しながら確認できます。
- **プロビジョニング**: Lima が起動のたびに適用するスクリプトとファイルの編集。**今すぐ実行**では項目や例を保存せずに実行中の VM で走らせ、出力を表示します。**一度だけ実行する**を選ぶと、成功した印を残して以後の起動では実行を飛ばします。失敗した場合は次の起動で再試行。「もう一度実行」で印を新しくします。
- **Mac から Ansible**: VM 用の Playbook を選び、設定タブから実行します。出力はシートに表示。HanaLima が Lima の `ssh.config` を使う ssh のインベントリを書きます。グループは `[hanalima]`、ホストは `lima-<名前>` です。`brew install ansible` か `pip install ansible` で入れた手元の `ansible-playbook` を Playbook のフォルダで起動するので、隣にある roles や `ansible.cfg` がそのまま使えます。Lima がパスワードなしの sudo を用意するため、`become` も設定不要です。同じインベントリはターミナルからも使えます: `ansible-playbook -i ~/Library/Application\ Support/HanaLima/ansible/inventory.ini …`。
- **英語と日本語の UI**: macOS の言語設定に合わせて表示します。

## 動作環境

- macOS 26 以降（macOS 27 / Apple Silicon で開発。Intel Mac は未確認）
- Homebrew の [Lima](https://lima-vm.io/) 2.3 以降
- ビルドには Xcode 26 以降と Metal Toolchain が必要（[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) が使います）

## クイックスタート

1. Lima と追加のゲストエージェントを入れます。

   ```bash
   brew install lima lima-additional-guestagents
   ```

2. Xcode の Metal Toolchain がまだ入っていなければ入れます。

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

3. クローンしてビルド。スクリプトが `build/HanaLima.app` を作り、この Mac 用に ad-hoc 署名します。

   ```bash
   git clone https://github.com/izawa/HanaLima.git
   cd HanaLima
   scripts/build-app.sh release
   ```

4. 起動します。

   ```bash
   open build/HanaLima.app
   ```

   `/Applications` にインストールして起動する場合は次のコマンドを使います。HanaLima が動いていれば先に終了させておきます。

   ```bash
   scripts/make-app.sh --install --open
   ```

5. サイドバー下の **＋ 新規仮想マシン** を押し、テンプレート（例: `default`、`alpine`）を選んで VM を作ります。新規 VM のドライバーは既定で HanaLima です。最初の起動時に OS イメージがダウンロードされます。

固定 IP やブリッジを使う場合は、サイドバーの **ネットワーク** の **＋** からネットワークを作ります。VM の **設定** タブを開き、ネットワーク欄の **NIC を追加** で作成したネットワークを選びます。

### 表示言語

優先する言語が日本語なら日本語、それ以外は英語で表示します。HanaLima だけ言語を変える場合は、システム設定 → 一般 → 言語と地域 → アプリケーション で選ぶか、次のように起動します。

```bash
open build/HanaLima.app --args -AppleLanguages '(en)'
```

## 仕組み

HanaLima は Lima の Go コードをリンクしていません。Lima の公式インターフェースである `limactl` コマンドを呼び出し、JSON 出力（`limactl list --format json`、`limactl watch --json`）を読んでいます。`lima.yaml` の変更は `limactl edit` を通し、Lima 側で検証します。

仮想ネットワークは同梱のヘルパー `hanalima-netd` が担当します。ネットワークごとにユーザーの LaunchAgent として登録し、ソケットアクティベーションで起動します。VM は Lima の `networks: - socket: <パス>` で接続します。プロトコルは socket_vmnet と同じで、ヘルパーがフレームを vmnet のネットワーク（NAT／ホストオンリー）かブリッジのインターフェースへ中継します。ゲスト専用では vmnet を使わず、ヘルパー自身が VM 間のフレームを中継します。ヘルパーに root は不要。必要なのは `scripts/build-app.sh` が付ける `com.apple.security.virtualization` の entitlement だけです。アプリが起動していなくてもネットワークは使え、`limactl start` で起動した VM からも接続できます。

| パス | 内容 |
|---|---|
| `Sources/LimaKit` | `limactl` のラッパー（UI に依存しない） |
| `Sources/NetworkKit` | 仮想ネットワークの定義、LaunchAgent の管理、DHCP 関連 |
| `Sources/hanalima-netd` | ネットワークのヘルパー（Lima のソケット ⇄ vmnet の中継／ゲスト専用のスイッチ） |
| `Sources/HanaLima` | SwiftUI アプリ |
| `Driver/` | Lima の外部ドライバー `lima-driver-hanalima`（vmType `hanalima`） |
| `Prototypes/` | ネットワーク調査用の実験コード（macOS の vmnet の不具合を再現するツールを含む） |
| `docs/` | 設計メモと調査の記録 |

HanaLima が作るファイル:

- `~/Library/Application Support/HanaLima/` — `networks.json`、配置したヘルパー、ネットワークのソケット
- `~/Library/LaunchAgents/org.izawa.HanaLima.net.<名前>.plist` — 仮想ネットワークごとに 1 つ
- `~/Library/Logs/HanaLima/` — ヘルパーのログ
- `<prefix>/lib/lima/lima-driver-hanalima`（Homebrew なら `/opt/homebrew/lib/lima/`）— VM のドライバー。アプリの起動時に毎回コピーします

Lima 自身のファイルは `limactl` が管理します。VM の `~/.lima`、イメージのキャッシュ `~/Library/Caches/lima`、ログイン時の自動起動用の `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist` が該当します。サイドバーの **ストレージ → 使用量** で確認できます。

## 既知の問題

- macOS 27.0.1 の vmnet の不具合には、HanaLima 側で回避策を入れています。特に、インターフェースを止めた vmnet ネットワークを再利用すると、ブリッジの `bridge100` を奪って Mac 本体の IPv4 アドレスが消えることがあります。Apple に FB25122122 として報告済み。HanaLima 自身はネットワークを再利用しませんが、同時に動くほかの仮想化ツールが再利用する可能性は残ります。Mac の IPv4 アドレスが消えた場合は、システム設定で DHCP リースを更新するか、`sudo ipconfig set en0 DHCP` を実行するか、Mac を再起動してください。詳細: [docs/02-networking-investigation.md](docs/02-networking-investigation.md)
- Lima の制約で、Lima のスナップショットは 2.3 でも QEMU の VM のみ対応。VZ の VM には HanaLima 独自のものを使います。画面のサムネイルは、画面を有効にした VZ の VM で、画面ウィンドウを開いているときだけ表示します。Lima 2.3 は QEMU の VM の画面も撮れますが、HanaLima はまだ使っていません。共有フォルダ（9p）がある VM では実行中のスナップショット作成がエラーを出さずに失敗するため、HanaLima では停止中に操作します。HanaLima のドライバーの VM にはこの制約がなく、`limactl snapshot` もサムネイルもドライバーを通して動きます。
- Wi-Fi へのブリッジは手元の環境では動きました。`en1` 経由で VM が LAN のアドレスを取得しています。ただし、1 台の端末から複数の MAC アドレスが出るのを拒むアクセスポイントもあります。Wi-Fi のブリッジで VM にアドレスが付かない場合は、有線のインターフェースを試してください。

## アンインストール

HanaLima のドライバーを使う VM があれば、まずアプリの設定タブで VZ に切り替えておきます。ドライバーを削除すると起動できなくなるためです。次にアプリで HanaLima のネットワークを削除し、LaunchAgent の登録を外します。その後、アプリとデータ、コピーしたドライバーを削除します。Homebrew の場合、ドライバーの配置先は `/opt/homebrew/lib/lima/` です。

```bash
rm -rf ~/Library/Application\ Support/HanaLima ~/Library/Logs/HanaLima /opt/homebrew/lib/lima/lima-driver-hanalima
```

LaunchAgent が残っていれば `launchctl bootout gui/$(id -u)/org.izawa.HanaLima.net.<名前>` で登録を外し、`~/Library/LaunchAgents` の plist を削除します。`~/.lima` の VM には触れません。

## 開発

```bash
scripts/build-app.sh                                  # build/HanaLima.app のデバッグビルド
swift test --skip EndToEnd --skip DaemonTermination   # 単体テスト（VM 不要、数秒）
HANALIMA_E2E=1 swift test --filter <スイート名>        # 実際の VM を使う E2E テスト
```

E2E テストは `hanalima-e2e-*` という名前の VM と一時的なネットワークを作り、終了時に削除します。ネットワークのテストには entitlement 付きのヘルパーが必要です。先に `scripts/build-app.sh` を実行しておきます。`BridgeEndToEndTests` はホストのインターフェースをブリッジに入れるため、`HANALIMA_E2E_BRIDGE=en0` のようにインターフェースを指定したときだけ動きます。

Mac の再起動後に `metal` が見つからずビルドに失敗する場合は、`swift package clean` を実行してからビルドし直します。

### 多言語対応

UI は英語と日本語に対応しています。元の文字列は日本語で、英訳は String Catalog の `Resources/Localizable.xcstrings` にあります。Xcode でも開けます。SwiftPM でビルドしているので、文字列の抽出はスクリプトから Swift コンパイラーを呼んで行います。

```bash
scripts/update-strings.sh    # Sources/ から文字列を抽出してカタログに反映する
scripts/check-strings.py     # 翻訳されない日本語のリテラルを一覧にする
```

SwiftUI にリテラルで渡す文字列（`Text("…")`、`Button("…")`）は自動で翻訳されます。コードで組み立てる文字列には `String(localized: "…")` を使います。`LabeledContent(_:value:)` の value は翻訳されないため、`LabeledContent("…") { Text("…") }` と書きます。

設計上の判断と理由は [docs/04-design.md](docs/04-design.md) にまとめています。

## コントリビューション

Issue とプルリクエストは日本語・英語どちらでも歓迎です。大きな変更の場合は先に Issue で方針を相談してください。

## ライセンス

HanaLima は [MIT License](LICENSE) で公開しています。

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）と [Yams](https://github.com/jpsim/Yams)（MIT）を使っています。Lima（Apache License 2.0）は同梱していません。Mac にインストール済みの `limactl` を呼び出して使います。

## 作者

Yukimitsu IZAWA — [izawa@izawa.org](mailto:izawa@izawa.org)
