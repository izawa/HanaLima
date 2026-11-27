<p align="center">
  <img src="Resources/AppIcon/AppIcon-1024.png" width="160" alt="HanaLima icon: a plumeria with five petals">
</p>

# HanaLima

[Lima](https://lima-vm.io/) の VM を GUI で手軽に作成・運用する macOS アプリです。CPU、メモリ、ディスク、ネットワークインターフェースを割り当てて VM を作り、起動・停止・操作まで行えます。仮想 NAT、ホストオンリー、ブリッジのネットワークも管理者権限なしで作れます。Virtualization.framework を使う HanaLima 自身のドライバーでは、隔離した VM、一時停止と休止、シリアルコンソール、Mac の USB 機器を VM に渡すことも使えます。VM をグループに分けて、グループごとに起動・停止することもできます。構成図で、どの VM がどのネットワークにつながっているかを見て、ゲストの中から疎通を確かめられます。ゲスト専用ネットワークでは、すべてのフレームを観測・記録し、遅延・損失・遮断を入れられます。試験的な機能として（v0.15 から）、AI のクライアントから MCP で HanaLima を操作できます。構成を文章か図で伝えると、ネットワークと VM を作り、疎通まで確かめます。

**Web サイト: [izawa.github.io/HanaLima](https://izawa.github.io/HanaLima/)** · [English README](README.md)

*Hana lima* はハワイ語で「手作り」。*hana* は作る、*lima* は手で、*lima* には「5」の意味もあります。アイコンはハワイを象徴する 5 弁の花、プルメリアにしました。ひとつのネットワークにつながる VM を手で組み上げていく様子を、花びらの一枚一枚で表しています。

> [!IMPORTANT]
> **HanaLima は非公式の個人プロジェクトです。** Lima プロジェクトおよび Cloud Native Computing Foundation (CNCF) とは関係がなく、公認も支援も受けていません。「Lima」という名前はアプリが何を扱うかを説明するためだけに使っています。HanaLima の問題の報告先はこのリポジトリです。Lima プロジェクトへの報告は避けてください。

> [!WARNING]
> HanaLima はまだ開発の初期段階です。Developer ID で署名し、Apple の公証を通したものを [Releases](https://github.com/izawa/HanaLima/releases/latest) で配布しています。ソースからビルドすることもできます。

## 機能

- **VM の一覧と操作**: Lima のテンプレートからの作成、起動、停止、再起動、削除。テンプレートはディストリビューションごとに「Ubuntu 24.04 LTS」のような名前で表示します。`limactl watch` で状態をリアルタイムに反映し、イメージのダウンロード中は進捗の割合・速度・残り時間も表示します。QEMU では、ゲストのアーキテクチャ（aarch64・x86_64）を選べます。Mac と違うものはエミュレーションなので、かなり遅くなります。
- **グループ**: サイドバーで VM をフォルダのようにグループにまとめ、開いたり閉じたりできます。グループの作り方は 3 通りです。「＋」のメニューか右クリックの「新規グループ」、VM のメニューの「グループへ移動」、グループに入っていない VM どうしを重ねるドラッグ。並びはドラッグで変えられ、どこへ動かしても挿入位置に線が出ます。グループの VM は、**すべて起動・すべて停止・すべて休止**でまとめて操作できます。実行の前に、対象の VM と順番、飛ばす VM とその理由を 1 枚のシートで示し、1 台ずつ実行します。起動はグループの並び順、停止と休止は逆順なので、ゲートウェイの VM を先頭に置けば、最初に起動して最後に止まります。休止できるのは下記の HanaLima のドライバーの VM だけで、ほかは飛ばします。Lima にはグループの仕組みがないので、HanaLima が VM ごとの記録に書きます。`limactl rename` しても VM はグループに残り、`limactl clone` の複製は元の VM のすぐ後ろに入ります（[docs/12](docs/12-vm-groups-design.md)）。
- **コンソール**: アプリ内のターミナル（`limactl shell`）。VM の準備ができるまで待ってから接続します。
- **設定の編集**: CPU、メモリ、ディスクサイズ、NIC、共有フォルダ、ポート転送をフォームで編集。`lima.yaml` 全体の編集にも対応し、Lima で検証してから変更した項目だけを書き戻します。VM の実行中はプロビジョニングのスクリプトも含めて読み取り専用で確認できます。プロビジョニングの例もワンクリックで追加できます。基本ツール一式、自分の dotfiles・公開鍵、Docker Engine、XDP の開発環境、日本向けの設定、自動更新の停止、スワップファイル、開発言語（Go・Node.js・uv・rustup）、一度だけの全パッケージ更新、コンソールへの自動ログイン、出口を絞るゲートウェイ（ゲスト専用ネットワークの「ルーター」にする VM 用。後ろの VM に NAT と DNS を与え、許可リストの先だけ通します）を用意しています。Ubuntu・Fedora と、対応するものは Alpine で確認済み。最初の 4 つは Debian でも確認しています。ゲートウェイは Ubuntu と Alpine だけで確認しています。
- **Mac のファイルを VM から見せない**: Lima は既定でホームフォルダを読み取り専用ですべての VM と共有します。そのため VM から `~/.ssh` などの認証情報も読めます。HanaLima では作成時にこの共有を外せます（`--mount-none`）。AI のコーディングエージェントなど、信頼しきれないものを VM で動かすときのための設定です。代わりに作業フォルダを 1 つだけ共有でき、書き込み可・読み取り専用を選べます。VM の中でもパスは同じです。この設定で隠せるのはファイルだけで、ネットワークは別に考える必要があります。Lima の標準のネットワークでは VM からインターネット、LAN、Mac の `127.0.0.1` で待ち受けるサービスに届きます（[docs/06](docs/06-isolation-investigation.md)）。ネットワークも切り離す場合は、下記の HanaLima 自身のドライバーの隔離プロファイルを使います。
- **追加ディスク**: 作成、サイズ変更、削除、VM への接続（`limactl disk`）。
- **ディスクを外付けドライブに**: VM でいちばん大きなファイルであるディスクを別のドライブへ移して、Mac の空き容量を節約できます。作成時の保存場所としても選べます。移動前に別のボリュームか、APFS か、空き容量が足りるかを確認し、スパースのまま移します。ドライブが外れている間は VM を起動させません。VM を削除すると移動先のディスクも削除します。いつでも内蔵ドライブに戻せます。
- **使用量**: VM、ディスク、ダウンロードしたイメージを Lima がどこに置いているか、実際にどれだけ容量を使っているかを表示します。イメージを使っている VM も確認でき、どの VM も使っていないイメージは削除できます。キャッシュ全体の削除は `limactl prune`。VM ごとのスナップショットの容量も表示します。`limactl` で直接削除した VM のスナップショットや外付けディスクが残っていれば、それらの確認・削除もできます。
- **root 不要の仮想ネットワーク**: サブネットと DHCP 予約（固定 IP）を指定できる NAT とホストオンリー、ホストのインターフェース（例: `en0`）への**ブリッジ**、VM 同士だけをつなぐ **ゲスト専用** の 4 種類。どれも同梱の小さなヘルパー `hanalima-netd` が提供し、ゲスト専用以外は macOS 26 の vmnet を使います。`sudo` も socket_vmnet も要りません。ゲスト専用のネットワークには Mac は参加せず、ヘルパーが vmnet を使わずに VM 間でフレームを中継します。下記の隔離した VM 同士は、このネットワークでつながります。ヘルパーの DHCP は、DNS サーバーとしてヘルパー自身と検索ドメイン `hanalima` を配ります。経路は、ネットワークに「ルーター」（そのネットワーク上の VM のアドレス）を指定したときだけ配り、その VM を DNS の 2 番目にも並べます。隔離した VM 群を、外に通じる VM 1 台の後ろに置く構成に使います。この DNS が答えるのは、そのネットワークの VM の名前（`lima-<名前>`。`.hanalima` を付けても可）だけです。ほかの名前には REFUSED を返し、リゾルバーは次のサーバーへ進むので、NIC 0 もある VM はインターネットの名前を Lima のユーザーモードネットワークの DNS で引けます。Ubuntu（systemd-resolved）はリンクごとに問い合わせ先を分けるのでそのまま使えます。Alpine は NIC 0 があると cloud-init が書いた resolv.conf（ユーザーモードの DNS だけ）が残るので、ヘルパーの DNS にはサーバーを指定して問い合わせます。隔離した Alpine の VM はヘルパーをリゾルバーにします。ネットワークを変更・削除すると、それを使う VM に必要な操作を案内します。実行中なら再起動ボタンを出し、削除したネットワークを指す NIC は次の起動前に外すか確認します。古いビルドのヘルパーが動いたままの VM にも、ネットワークの保存・削除時に同じ再起動の印を付けます。
- **Lima の従来方式のネットワーク**: `lima:shared`・`lima:host`・`lima:bridged` を使う VM もそのまま動かし、編集できます。これらに必要な socket_vmnet は Lima の手順で導入してください。HanaLima は導入を行いません。HanaLima 自身のネットワークなら root は要りません。
- **構成図**: ネットワークの画面を、一覧から構成図に切り替えられます。ネットワークを縦の線、VM を行として描き、NIC がつながる所に点とアドレスを出します。ツールバーの「疎通を確かめる」を押すと、実行中の VM の中から NIC ごとに、ゲートウェイ、ルーター、ほかの VM、外へ ping し、結果を点の印に出します（[docs/16](docs/16-network-map-design.md)）。
- **ゲスト専用ネットワークの観測と障害**: ゲスト専用ネットワークを流れるフレームを、ネットワークの側から見られます。HanaLima のヘルパーが VM のあいだのフレームをすべて中継しているためです。構成図でネットワークを選ぶと、NIC ごとの毎秒のフレーム数と、落としたフレームの数が理由ごとに出ます。「パケットを記録…」を押すと、ネットワーク全体の通信を pcap のファイルに保存します（64 MiB か 5 分まで。通信の中身がそのまま入ります）。「障害を入れる…」で、VM の NIC かネットワーク全体に、遅延・損失・遮断を最長 30 分まで指定できます。遅延と損失は VM へ届くフレームにかかります。遮断は拒否の応答を返さずに両方向のフレームを捨て、ゲストのリンクは上がったままです。ゲストで動かすプログラムが、遅い通信や応答のない相手をどう扱うかを確かめるのに使えます（[docs/17](docs/17-guest-only-observation.md)、[docs/18](docs/18-guest-only-faults.md)）。
- **メニューバー**: すべての VM の状態確認、起動・停止、コンソールの呼び出し。グループはサブメニューにまとまり、一括操作もここから選べます。ウィンドウを閉じてもメニューバーで動き続けます。
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
  - **隔離プロファイル**: 「NIC 0: Lima のユーザーモード NAT」を外すと、その NIC を通るインターネット・LAN・Mac の `127.0.0.1` への経路がなくなります。届くのは追加した NIC の先だけで、HanaLima のホストオンリーやゲスト専用などを使えます。SSH・ゲストエージェント・ポート転送は vsock で動きます。作成画面の「隔離した仮想マシンとして作る」という 1 つのスイッチでまとめて設定できます。「最初の 1 回だけ NIC 0 を付けて起動する」を選ぶと、最初の停止時に NIC 0 が自動で外れます。隔離中はドライバーが hostResolver と containerd を切り、eth0 を optional にして、DNS をゲスト専用ネットワークのものにします。この変更は `lima.yaml` には書かず、設定タブと概要タブに注記を出します。apt・dnf は外に出られないので、プロビジョニングは入れません。
  - **一時停止と休止**（[docs/11](docs/11-pause-resume-investigation.md)）: 実行中の VM を止めて、あとで続きから動かせます。一時停止はメモリを持ったまま CPU だけを止めるので、すぐに再開できます。休止はメモリの内容を VM のフォルダに保存して電源を切るので、Mac のメモリが空き、ドライバーのプロセスも終わります。次の起動で、休止した時点から続きます。Mac を再起動したあとでも、ログイン時の自動起動でも同じです。どちらもゲストは再起動せず、時計は Lima の時刻同期が合わせます。休止からの再開では、Lima が起動のたびに走らせる処理（プロビジョニングを含む）がもう一度走ります。休止したあとに設定やディスクを変えた VM は、古いメモリと変わったディスクを組み合わせないように再開を断り、保存した状態を捨てるかを尋ねます。休止中に `limactl clone` で作った複製と、休止中に `limactl rename` した VM は、保存した状態を捨てて普通に起動します。この Mac で初めて休止するときは、画面のロックを解除しておく必要があります（保存に使う鍵をそのときに作るため）。Lima の `vz` には一時停止の仕組みがないので、`vz` の VM では使えません。Alpine・Ubuntu LTS で E2E 確認済み。
  - **Mac の USB 機器を渡す**（macOS 27、v0.19 から。[docs/19](docs/19-usb-passthrough-investigation.md)）: Mac に挿した USB メモリなどを、ファイルの共有ではなく機器として VM に渡します。ゲストの USB のバスに機器が現れて `/dev/sdX` になるので、パーティションを切る、フォーマットする、生のまま読むといったことができます。メニューバーの「**仮想マシンアクセサリ**」でその機器を「HanaLima で使用」にし（ターミナルやログイン時の自動起動で起動した VM には「不明なアプリケーション」で使用にします。こちらはログインのたびに選び直します）、サイドバーの「**USB 機器**」で受け取る VM を選びます（v0.20 から）。規則の無い機器を受け取る VM を 1 台決め、機器ごとに別の VM を選べます。機器はシリアル番号か、挿したポートで見分けます。受け取り先を変えると、両方の VM が動いたまま機器が移ります（使用中なら先に確かめます）。受け取り先が止まっている機器は、ほかの VM には回さずに保留します。渡している間は Mac から使えません。ゲストでアンマウントしてから「“このMac” で使用」にすると、挿したときと同じように Mac にマウントし直されます。最初の 1 回は、リムーバブルボリュームへのアクセスの許可を求められます。一時停止の間は渡したままで、停止や休止で手放します。Apple の機器と、映像や音声を流す機器（カメラ、オーディオインターフェース）は渡せません。配布しているビルドが要ります。自分でビルドしたもの（ad-hoc 署名）は、Apple の entitlement とプロビジョニングプロファイルが無いので USB 機器を受け取れません。Ubuntu 26.04・Alpine と USB メモリで確認済み。
  - **Lima と同じに使えるもの**: Rosetta は Mac に入っていなければ共有なしで起動し、ログに案内を出します。自動では入れません。`lima:` ネットワークは socket_vmnet の shared・host・bridged と、NIC 0 としての user-v2 に対応。`limactl snapshot`（create・apply・delete・list）はアプリと同じ APFS クローンを使います。停止中のみで、タグは 1 語です。
  - **ターミナルの `limactl` からも**: HanaLima の起動時に毎回、Lima がドライバーを探す場所にドライバーへのリンクを置きます。Homebrew なら `/opt/homebrew/lib/lima/` です。HanaLima を「アプリケーション」フォルダに入れているときだけ置きます。`LIMA_DRIVERS_PATH` も sudo も不要。VM がなくなり、ドライバーを起動した Lima のプロセスも終了すると、ドライバーは自分で終了します。
  - HanaLima のない Mac では起動できません。別の Mac に移すなら、先に VZ に戻しておきます。Alpine・Ubuntu LTS・Fedora・Debian で E2E 確認済み。
  - シリアルコンソールからログインするには:
    1. 救出起動と同じく、設定タブで例「コンソールに自動ログイン（画面・シリアル）」を追加して一度起動する。イメージにはシリアルポート `hvc0` のログインが用意されていないので、この設定がないとシリアルには何も出ません。
    2. 作成時、または停止中の設定タブで、その VM のドライバーに HanaLima を選ぶ。
    3. 起動してコンソールタブの「シリアル」を開くと、SSH を介さないログイン済みのシェルが出ます。
- **複製**: `limactl clone` と APFS のクローンで、停止中の VM を一瞬で複製します。名前、ホスト名、MAC アドレス、SSH の鍵は新しくなります。ディスクを外付けに移した VM でも、コピーは元とディスクを共有せず、同じ外付けの上に自分のディスクを持ちます。VM ごとにコピー元、コピー、メモを表示します。
- **ゲストの OS**: 概要タブに、VM に入っている OS とその版を出します。VM が準備完了になったときにゲストの中で読んだもので、読んだ日時を添えます（Linux は os-release、macOS は `sw_vers`、FreeBSD は `freebsd-version`）。ゲストで OS を更新したあとなどは「確認する」で読み直せます。これから作る VM は、作成元にそのときのテンプレートの版も出します（「template:ubuntu-lts（作成時は Ubuntu 24.04 LTS）」）。複製した VM と、スナップショットを戻した VM は「未確認」から始まります（[docs/20](docs/20-guest-os-design.md)）。
- **名前の変更**: 停止中の VM の名前を変えられます。固定 IP、スナップショット、グループ、メモ、ログイン時の自動起動は引き継ぎます。Lima は MAC アドレスを VM のフォルダから作るので、HanaLima が先に NIC の今の MAC アドレスを `lima.yaml` に書き込みます。ホスト名は次の起動で `lima-<新しい名前>` になります（[docs/15](docs/15-rename-design.md)）。
- **画面のサムネイル**: 概要タブに VM の画面をライブで表示します。対象は画面を有効にした VZ の VM と、HanaLima のドライバーの VM（こちらはドライバー経由）です。
- **ログ**: ホストエージェントのログとシリアルコンソールをリアルタイムに表示。検索しながら確認できます。
- **プロビジョニング**: Lima が起動のたびに適用するスクリプトとファイルの編集。**今すぐ実行**では項目や例を保存せずに実行中の VM で走らせ、出力を表示します。**一度だけ実行する**を選ぶと、成功した印を残して以後の起動では実行を飛ばします。失敗した場合は次の起動で再試行。「もう一度実行」で印を新しくします。
- **Mac から Ansible**: VM 用の Playbook を選び、設定タブから実行します。出力はシートに表示。HanaLima が Lima の `ssh.config` を使う ssh のインベントリを書きます。グループは `[hanalima]`、ホストは `lima-<名前>` です。`brew install ansible` か `pip install ansible` で入れた手元の `ansible-playbook` を Playbook のフォルダで起動するので、隣にある roles や `ansible.cfg` がそのまま使えます。Lima がパスワードなしの sudo を用意するため、`become` も設定不要です。同じインベントリはターミナルからも使えます: `ansible-playbook -i ~/Library/Application\ Support/HanaLima/ansible/inventory.ini …`。
- **MCP で AI から操作**（試験的、v0.15 から）: HanaLima の操作を、7 つの MCP の道具（`inspect`、`plan`、`apply`、`vm`、`exec`、`job`、`delete`）として AI に渡します。設定で「AI からの操作を受け付ける」をオンにし、MCP クライアントに `~/.hanalima/mcp.json` を読ませて（HanaLima が起動のたびに書きます）、構成を文章か図で頼みます。AI は、書いたことはそのまま守り、書いていないこと（OS、大きさ、名前、空いているサブネットなど）は自分で決めて報告し、作れないことは作れる案と一緒に尋ねます。`plan` は宣言を確かめるだけで何も変えません。`apply` はゲスト専用ネットワークと新しい VM を作り（既にあるゲスト専用ネットワークに、新しい VM を DHCP でつなぐこともできます）、順に起動して、当てはまるものをゲストの中から確かめます。既定の経路がルーターを向いているか、ルーター・隣の VM（名前で）・指定した外の宛先に届くか、です。宣言には、VM に入れる同梱のプロビジョニングの例と、Mac の `127.0.0.1` からゲストの TCP のポートへの転送も書けます。同じ宣言で計画し直したときは、宣言に合い、設定が作ったときのままの VM とネットワークだけをそのまま使います。v0.18 からは、構成図、あなたが最後に走らせた疎通の検査、ゲスト専用ネットワークのフレームの数と障害を AI が読めるようになり、VM が起動しない理由を最後の起動のログから調べたり、停止中の VM を複製したりもできます。HanaLima 自身は AI を呼ばず、API キーも持ちません。AI が作った VM は AI がそのまま操作できます。あなたの VM の操作、あなたのネットワークへの接続、スナップショットの復元は、アプリで許可するまで実行しません（あなたの VM の複製も、あなたのものになります）。AI が作っていないものは、AI からは削除できません。sudo は使わず、ブリッジは AI からは作れません。設計は [docs/14](docs/14-mcp-design.md)。
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

2. [Releases](https://github.com/izawa/HanaLima/releases/latest) から `HanaLima-<版>.dmg` をダウンロードして開き、**HanaLima** を **アプリケーション** へドラッグして起動します。Developer ID で署名し、公証を通してあるので、警告なしに開けます。自分でビルドする場合は「[ソースからビルドする](#ソースからビルドする)」を見てください。

3. サイドバー下の **＋ 新規仮想マシン** を押し、VM を作ります。テンプレートは最初から Ubuntu LTS（`ubuntu-lts`）になっていて、`alpine` などほかのものも選べます。新規 VM のドライバーは既定で HanaLima です。最初の起動時に OS イメージがダウンロードされます。

固定 IP やブリッジを使う場合は、サイドバーの **ネットワーク** の **＋** からネットワークを作ります。VM の **設定** タブを開き、ネットワーク欄の **NIC を追加** で作成したネットワークを選びます。ネットワークの画面の上のボタンで、一覧と構成図を切り替えられます。

### ソースからビルドする

1. Xcode の Metal Toolchain がまだ入っていなければ入れます。

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

2. クローンしてビルド。スクリプトが `build/HanaLima.app` を作り、この Mac 用に ad-hoc 署名します。USB 機器を VM に渡すことだけは、配布しているビルドでないとできません。

   ```bash
   git clone https://github.com/izawa/HanaLima.git
   cd HanaLima
   scripts/build-app.sh release
   ```

3. 起動します。

   ```bash
   open build/HanaLima.app
   ```

   `/Applications` にインストールして起動する場合は次のコマンドを使います。HanaLima が動いていれば、スクリプトが先に終了させます。

   ```bash
   scripts/make-app.sh --install --open
   ```

### 表示言語

優先する言語が日本語なら日本語、それ以外は英語で表示します。HanaLima だけ言語を変える場合は、システム設定 → 一般 → 言語と地域 → アプリケーション で選ぶか、次のように起動します。

```bash
open -a HanaLima --args -AppleLanguages '(en)'
```

## 仕組み

HanaLima は Lima の Go コードをリンクしていません。Lima の公式インターフェースである `limactl` コマンドを呼び出し、JSON 出力（`limactl list --format json`、`limactl watch --json`）を読んでいます。`lima.yaml` の変更は `limactl edit` を通し、Lima 側で検証します。

仮想ネットワークは同梱のヘルパー `hanalima-netd` が担当します。ネットワークごとにユーザーの LaunchAgent として登録し、ソケットアクティベーションで起動します。VM は Lima の `networks: - socket: <パス>` で接続します。プロトコルは socket_vmnet と同じで、ヘルパーがフレームを vmnet のネットワーク（NAT／ホストオンリー）かブリッジのインターフェースへ中継します。ゲスト専用では vmnet を使わず、ヘルパー自身が VM 間のフレームを中継します。ヘルパーに root は不要。必要なのは `scripts/build-app.sh` が付ける `com.apple.security.virtualization` の entitlement だけです。アプリが起動していなくてもネットワークは使え、`limactl start` で起動した VM からも接続できます。ゲスト専用ネットワークのヘルパーは、VM ごとのフレームを数え、パケットを記録し、障害を入れます。その指示は 2 つ目のソケット（`<名前>.ctl.sock`、同じユーザーだけ）で受けます。DHCP のリースはファイルに書き、ヘルパーが起動し直したときに読み戻します。

| パス | 内容 |
|---|---|
| `Sources/LimaKit` | `limactl` のラッパー（UI に依存しない） |
| `Sources/NetworkKit` | 仮想ネットワークの定義、LaunchAgent の管理、DHCP 関連 |
| `Sources/hanalima-netd` | ネットワークのヘルパー（Lima のソケット ⇄ vmnet の中継／ゲスト専用のスイッチ） |
| `Sources/AgentKit` | MCP の道具のうち画面の要らない部分（構成の宣言の読み取りと計画）と構成図 |
| `Sources/MCPKit` | MCP: JSON-RPC、道具の一覧、アプリとのソケット |
| `Sources/hanalima-mcp` | MCP のクライアントが起動するヘルパー。道具の呼び出しをアプリへ中継する |
| `Sources/HanaLima` | SwiftUI アプリ |
| `Driver/` | Lima の外部ドライバー `lima-driver-hanalima`（vmType `hanalima`） |
| `Prototypes/` | ネットワーク調査用の実験コード（macOS の vmnet の不具合を再現するツールを含む） |
| `docs/` | 設計メモと調査の記録 |

HanaLima が作るファイル:

- `~/Library/Application Support/HanaLima/` — `networks.json`、配置したヘルパー、ネットワークのソケットと DHCP のリース、パケットの記録（`Captures/`）
- `~/Library/LaunchAgents/org.izawa.HanaLima.net.<名前>.plist` — 仮想ネットワークごとに 1 つ
- `~/Library/Logs/HanaLima/` — ヘルパーのログ
- `~/.hanalima/` — MCP: アプリとのソケット、`mcp.json`、AI が作ったものとジョブの記録、呼び出しの記録（字数と時間だけ）
- `<prefix>/lib/lima/lima-driver-hanalima`（Homebrew なら `/opt/homebrew/lib/lima/`）— アプリの中の VM のドライバーへのリンク。アプリの起動時に毎回置きます

Lima 自身のファイルは `limactl` が管理します。VM の `~/.lima`、イメージのキャッシュ `~/Library/Caches/lima`、ログイン時の自動起動用の `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist` が該当します。サイドバーの **ストレージ → 使用量** で確認できます。

## 既知の問題

- macOS 27（27.0.1 と 27.2.1）の vmnet の不具合には、HanaLima 側で回避策を入れています。特に、インターフェースを止めた vmnet ネットワークを再利用すると、ブリッジの `bridge100` を奪って Mac 本体の IPv4 アドレスが消えることがあります。Apple に FB25122122 として報告済み。HanaLima 自身はネットワークを再利用しませんが、同時に動くほかの仮想化ツールが再利用する可能性は残ります。消えたアドレスは自然には戻らず、`ipconfig getifaddr en0` は消える前のアドレスを返し続けるので、確かめるときは `ifconfig en0` を見てください。Mac の IPv4 アドレスが消えた場合は、システム設定で DHCP リースを更新するか、`sudo ipconfig set en0 DHCP` を実行するか、Mac を再起動してください。詳細: [docs/02-networking-investigation.md](docs/02-networking-investigation.md)
- Lima の制約で、Lima のスナップショットは 2.3 でも QEMU の VM のみ対応。VZ の VM には HanaLima 独自のものを使います。画面のサムネイルは、画面を有効にした VZ の VM で、画面ウィンドウを開いているときだけ表示します。Lima 2.3 は QEMU の VM の画面も撮れますが、HanaLima はまだ使っていません。共有フォルダ（9p）がある VM では実行中のスナップショット作成がエラーを出さずに失敗するため、HanaLima では停止中に操作します。HanaLima のドライバーの VM にはこの制約がなく、`limactl snapshot` もサムネイルもドライバーを通して動きます。
- Wi-Fi へのブリッジは手元の環境では動きました。`en1` 経由で VM が LAN のアドレスを取得しています。ただし、1 台の端末から複数の MAC アドレスが出るのを拒むアクセスポイントもあります。Wi-Fi のブリッジで VM にアドレスが付かない場合は、有線のインターフェースを試してください。

## アンインストール

HanaLima のドライバーを使う VM があれば、まずアプリの設定タブで VZ に切り替えておきます。ドライバーを削除すると起動できなくなるためです。次にアプリで HanaLima のネットワークを削除し、LaunchAgent の登録を外します。その後、アプリとデータ、ドライバーへのリンクを削除します。Homebrew の場合、ドライバーの配置先は `/opt/homebrew/lib/lima/` です。

```bash
rm -rf ~/Library/Application\ Support/HanaLima ~/Library/Logs/HanaLima ~/.hanalima /opt/homebrew/lib/lima/lima-driver-hanalima
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

`scripts/release.sh` は、リリース用に公証した DMG を作ります（管理者向け。キーチェーンに Developer ID の証明書と notarytool の認証情報が要ります。`--no-notarize` を付けると署名までで止まります）。GitHub Releases への公開までの手順は [docs/13](docs/13-release.md) にまとめてあります。

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
