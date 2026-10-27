# 設計メモ

HanaLima の設計上の判断と、その理由をまとめる。経緯は [03](03-development-log.md)、ネットワーク調査は [02](02-networking-investigation.md) を参照。

## 構成

| ターゲット | 役割 |
|---|---|
| `LimaKit` | `limactl` CLI のラッパー（UI 非依存）。`ProcessRunner`、`LimaClient`（list/watch/create/start/edit/disk/autostart、ログストリーム）、`InstanceConfig`（lima.yaml の差分を `--set` 式に変換）、`DownloadMonitor`、`HostInterfaces`（ブリッジ先の一覧） |
| `NetworkKit` | HanaLima 仮想ネットワーク: `VirtualNetwork`/`networks.json`、`LaunchAgentManager`、`HelperInstaller`、`DHCPClientIDFilter`、`DHCPLeases`、`NetworkConflict` |
| `hanalima-netd` | ネットワークごとに 1 プロセス。Lima の `socket:` ネットワーク（socket_vmnet 互換の QEMU stream: 4 バイト長＋フレーム）を vmnet に中継する。root 不要（`com.apple.security.virtualization` が必須） |
| `HanaLima` | SwiftUI アプリ。`AppModel`（@Observable, @MainActor）、`AppModel+Networks` |

実行時のファイル配置: `~/Library/Application Support/HanaLima/{networks.json, bin/hanalima-netd-<hash>, net/<名前>.sock}`、`~/Library/LaunchAgents/org.izawa.HanaLima.net.<名前>.plist`（launchd のソケットアクティベーション）、`~/Library/Logs/HanaLima/net-<名前>.log`。

## 設計方針

- **Lima の Go コードはリンクせず、`limactl` CLI を呼ぶ。** CLI が Lima の公式で安定したインターフェースだから。JSON 出力（`list --format json`、`watch --json`、`disk list --json`）を使う。
- **lima.yaml は `limactl edit --set` で変更する。** フォームで変えた項目だけを式にし、リストは生の lima.yaml（Yams）から読む。こうすると Lima が補った既定値が書き込まれず、未知のキーも残る。YAML 全体の置き換えは、`VISUAL` にコピー用スクリプトを指定して `limactl edit --tty=true --start=false` で行い、Lima の検証を通す。
- **子プロセスは `$TMPDIR/HanaLima` で実行する。** `limactl edit` は失敗時に `lima.REJECTED.yaml` をカレントディレクトリに書くため。PATH の先頭には `/opt/homebrew/bin` を足す（Finder から起動したアプリは PATH を引き継がない）。
- **起動状態は `limactl list` の Running だけで判断しない。** Running になってから SSH が使えるまで約 1 分かかる。`watch` の `running` イベントか `limactl start` の完了で「準備完了」とし、コンソールはそれまで待つ（すぐ失敗したら 10 回まで自動で再試行）。
- **ログイン時の自動起動は Lima の `limactl autostart` に任せる。** 登録の有無は `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist` があるかで判定する（Lima 自身の判定と同じ）。登録した VM の `limactl start`/`stop` は Lima が launchd 経由で行うので、アプリ側の分岐は不要。
- **メイン画面は単一の `Window`、メニューバーは `MenuBarExtra`。** メニューバーに表示している間は、ウィンドウを閉じてもアプリは終了しない。メニューバーから開く操作（コンソール、新規作成）は、モデルの `consoleRequest`/`createRequested` を通して画面に伝える。
- **テンプレートの一覧は Lima から取り、表示名とグループは名前から作る**（`TemplateCatalog`）。一覧は `limactl info` の `templates`（`--list-templates` と同じ名前に、ファイルの場所が付く）。`ubuntu-24.04` → 「Ubuntu 24.04 LTS」（LTS は偶数年の .04）のように名前から組み立てるので、Lima の更新で版が増えてもそのまま並ぶ。`ubuntu`・`ubuntu-lts`・`debian`・`default` など最新版を指すテンプレートは、YAML の `base: - template:_images/<名前>` をたどって今の版を表示する（`_images/ubuntu` のような版なしの画像は、中身が同じ `_images/ubuntu-26.04.yaml` を探す）。知らない名前は「その他」に元の名前で出る。
- **使用量の画面は、`LIMA_HOME`（`limactl info` の `limaHome`）とダウンロードのキャッシュ（`~/Library/Caches/lima`、macOS では場所を変えられない）を、ファイルの実際の使用量（`du` と同じ）で集計する。** VM のディスクはスパースなので、名目のサイズは使わない。キャッシュの 1 項目には、ダウンロードしたファイル（`data`）と VZ 用に変換した `imgconv/raw` が含まれる。「すべて削除」は `limactl prune`。「使われていないイメージを削除」は HanaLima が判定してキャッシュの項目を消す（`prune --keep-referred` はテンプレートが参照するものも残すので、ほぼ何も消えない）。判定は、どれかの VM の lima.yaml に URL があれば使用中、テンプレート（`_images/` を含む）にだけあれば未使用、どちらにもなければ Lima の部品（nerdctl など、起動のたびに cidata へ入れるもの）として残す。VM の作成・起動中はダウンロードと重なるので押せない。保存先の変更（`LIMA_HOME`）は、すべての `limactl` 呼び出しと自動起動の登録に関わるので、まだ扱わない。
- **`limactl watch` は app の終了時に止める**（`ProcessRunner.terminateBackgroundProcesses`）。強制終了で残ったものは次回起動時に片付ける。
- **ネットワークは 3 系統。**
  1. HanaLima 仮想ネットワーク（NAT／ホストオンリー: サブネット指定、DHCP 予約。ブリッジ: 接続先インターフェースを指定）: root 不要。
  2. vzNAT: root 不要。サブネットは指定できない。
  3. socket_vmnet（`lima:shared/host/bridged`）: Lima の従来方式。既存の VM のために表示・起動・編集はできるが、導入（root、sudoers）は HanaLima では行わず Lima の手順に任せる（2026-10-12 ユーザー判断）。未導入のときは NIC の追加メニューと組み込みの一覧に出さない。HanaLima のネットワークに機能面の不足はなく、socket_vmnet に残る利点は Lima 標準との互換（HanaLima なしでも動く `lima.yaml`）だけだったため。
- **HanaLima のブリッジは、VM の接続ごとに従来 API のインターフェース（`vmnet_start_interface` + `VMNET_BRIDGED_MODE`）を作る。** entitlement 付きの署名なら root なしで動く（macOS 27.0.1 で確認）。2 台同時、仮想ネットワークとの同時使用、再起動の順序も実機で確認済み（docs/02）。`vmnet_network` を使わないので、同時使用の確認ダイアログの対象外。
- **hanalima-netd の vmnet ネットワークは、最初の VM 接続時に作り、最後の VM が切断したら解放する。** 使い回すと、macOS の不具合で DHCP 予約が消え、ブリッジ番号も衝突する（下記）。
- **すべての終了経路でインターフェースを止めてから終了する。** 止めずに終了すると、vmnet がそのサブネットを再起動まで予約したままになる。シグナルハンドラは `@Sendable` にすること（main.swift のトップレベルに書いたクロージャは main actor 扱いになり、別スレッドで動くと SIGTRAP で落ちる）。
- **ヘルパーは上書きせず、バージョンごとに別名で置く（`bin/hanalima-netd-<hash>`、`bin/current`）。** launchd は登録時のプログラムの cdhash を記録していて、別のビルドで上書きすると次の起動が `spawn failed`（終了コード 78）になる。エージェントの登録し直しは、ヘルパーが動いていないときだけ行う（`upgradeIdleAgents`）。
- **netd どうしは、vmnet の操作（ネットワークの作成、インターフェースの開始）をファイルロック（`net/vmnet.lock`）で 1 つずつ行う。** ネットワークの作成とブリッジの開始が重なると、そのプロセスでは 1001 が続く（新しいプロセスにすると作成できた）。
- **DHCP 予約は、予約のある MAC からの DHCP 要求に限り、オプション 61 を除去して効かせる。** bootpd はクライアント識別子（Linux の DUID）があるとそれで識別するため、MAC による予約が一致しない。
- **ネットワークを変えたあとの案内。** 実行中の VM が使うネットワークを保存・削除したら、その VM に「再起動が必要」の印を付け（`restartNeeded`）、VM の画面の帯とサイドバーで知らせる。印は再起動か停止で消える。削除したネットワークを指す NIC（`net/` の下のソケットで、`networks.json` に無いもの）は「削除したネットワーク」と表示し、起動・再起動の前に「NIC を外して起動」するか尋ねる。外すのは `limactl edit --set '.networks |= map(select(.socket != "…"))'`（実行中なら先に停止）。
- **VM のディスクを外付けドライブなどへ移せる（`ExternalDisk`）。** Lima は VM の置き場所を選べず、VM のフォルダごとシンボリックリンクにすると `limactl list` に出ない（docs/05）。そこでフォルダは `~/.lima` に残し、`disk` だけを `<選んだ場所>/HanaLima Disks/<名前>/disk` に移してリンクを置く。コピーは `copyfile` の `COPYFILE_DATA_SPARSE`（データのある範囲だけを写す）で `disk.partial` に取り、末尾の穴の分だけ長さを元に合わせ（copyfile は最後のデータで止まる）、サイズを照合してから改名し、最後に rename 1 回でファイルをリンクに置き換える（途中で失敗・中止しても元のディスクは残る）。戻すときも同じ手順で逆向き。移動先の判定（同じボリューム、APFS 以外、空き不足、既存のフォルダ）はシートで先に示し、通らなければ移動できない。外付けの空き容量は「重要な用途」の値が返らないことがあるので、通常の空き容量で補う。ドライブが外れているときは起動を止めて知らせ、VM の削除では移動先のフォルダ（目印の `hanalima.json` があるものだけ）も削除する。作成画面でも保存場所を選べる（作成後、最初の起動の前に移す）。選んだフォルダ自体が `HanaLima Disks` に似た名前なら、中にもう 1 段作らない。最後の VM を片付けて空になった `HanaLima Disks` も消す。ディスクの場所はモデルの状態として持ち、一覧の更新とボリュームのマウント・取り外しの通知で更新する（描画のたびにファイルを読むと、抜き差しで表示が古いまま残る）。`rsync --sparse` は使わない（ブロックごとにゼロか判定するので、散らばったデータで約 2 倍に膨らむ）。**`limactl clone` はリンクをそのまま写す**ので、コピーした VM は元の VM と同じディスクを指す。目印の `instanceDir` が持ち主で、削除で消すのは持ち主のディスクだけ。持ち主でない VM は「ディスクを共有」と表示して起動を止め、「ディスクを独立させる」で同じドライブの上に APFS のクローン（`clonefile`）を作ってリンクを付け替える。目印の VM がもう無いかリンクしていない（Lima の外で改名・削除された）ときは、いまリンクしている VM が目印を引き継ぐ。
- **作成画面で、ホームフォルダの共有を外せる。** Lima のテンプレートは `_default/mounts` でホーム（`~`、読み取り専用）をマウントするので、VM から Mac の認証情報（`~/.ssh` など）を読める。AI のエージェントなどを隔離して動かす用途のために、切り替えをオフにすると `limactl create --mount-none` を付ける（テンプレートのマウントはすべて外れる）。既定はオンで、Lima と同じ。オフのときは作業フォルダを 1 つ選べ、`--mount-only=<パス>[:w]` でそのフォルダだけを（VM の中でも同じパスに）共有する。パスに `:` を含むフォルダは選べない（Lima が `:w` の区切りとして読む）。隠せるのはファイルだけで、Lima の NIC 0（外す設定がない）を通って Mac の `127.0.0.1` のサービス、LAN、インターネットに届くので、作成画面に注意を出す（docs/06）。
- **VM の複製（`InstanceCopy`）は `limactl clone` に任せ、残りを HanaLima が補う。** clone は APFS のクローンで一瞬に写し（10 GB・実使用 267 MB で 25 ミリ秒）、ホスト名、MAC、VZ のマシン識別子、SSH のポートとホスト鍵を新しくする。HanaLima は、手で指定した MAC を消し（`--set 'del(.networks[].macAddress)'`）、写ったログを空にし、外付けのディスク（リンクが写る）を同じドライブの上でクローンし、記録を書く。複製は停止中だけ。固定 IP（MAC に結びつく）と自動起動は引き継がない。複製元と複製の DHCP: ゲストの DUID はディスク上のファイルなので複製でも同じだが、HanaLima のネットワーク（bootpd）では別の IP になる（E2E、Alpine・Fedora・Ubuntu LTS）。Alpine の dhcpcd は識別子を IAID（既定は MAC から作る）＋DUID にし、Ubuntu は Lima の netplan で MAC を識別子にするため。netd のオプション 61 の除去は、予約のある MAC に限ったままにする。
- **VM ごとの記録 `~/.lima/<名前>/hanalima-vm.json`（`InstanceMetadata`）。** ID、作成日時、テンプレート、親（ID、当時の名前、日時、スナップショット名）、メモ。VM のフォルダに置くので `limactl rename` で付いていき、`delete` で消える。親だけを持ち、子は持たない（コピーは独立していて、つながりは情報にすぎない。何世代でも 1 VM 1 ファイル）。clone は記録も写すので、記録のフォルダと今のフォルダが違えば、同じ ID の VM が元の場所にいれば CLI の複製（新しい ID、親はその VM）、いなければ名前の変更（ID を保つ）と判断して直す。サイドバーは平らなまま、系譜は概要タブに出す。
- **VZ のスナップショット（`DiskSnapshot`）は、ディスクと `vz-efi` の APFS クローン。** Lima 2.2 の VZ ドライバーにはスナップショットがない。クローンは同じボリューム内でしか作れないので、ディスクと同じボリュームに置く: 内蔵なら `~/.lima/_hanalima-snapshots/<VM の ID>/<ID>/`、外付けなら `HanaLima Disks/<名前>/snapshots/<ID>/`。**VM のフォルダの中には置かない**（サブフォルダがあると `limactl clone` が permission denied で失敗した）。`_` で始まるフォルダは Lima が VM として数えない。戻すときはクローンを `disk.hanalima-restoring` に作って rename で置き換え、保存後に広げたディスクは長さを保つ。停止中だけ。スナップショットがあるあいだはディスクを移動できない（同じボリュームに置くため）。HanaLima で VM を削除すると消す（CLI で削除すると残る）。UI は「VM が増えるのが複製、同じ VM の過去に戻るのがスナップショット」で分け、スナップショットから新しい VM も作れる（複製してからスナップショットを戻す）。
- **持ち主のいないデータ（`Leftovers`）を使用量に出す。** HanaLima のスナップショットと外付けのディスクは Lima が知らないので、`limactl delete` で VM を消すと残る。`_hanalima-snapshots/<ID>` はどの VM の記録の ID でもないもの、外付けの `HanaLima Disks/<名前>` は目印の VM のフォルダがもう無く、どの VM のリンクも指していないものだけを残りものとする（目印のないフォルダ、Lima の外で改名した VM、移動中のディスクは対象外）。外付けは、HanaLima がディスクを置いたフォルダを覚えておき（UserDefaults `knownExternalDiskFolders`。一覧の更新のたびに外付けの VM から覚える）、接続中のものだけ調べる。削除の直前にもう一度判定する。スナップショットの容量は持ち主の VM の行に数える。
- **プロビジョニングの例（`ProvisionExamples`）を同梱する。** 基本ツール一式、dotfiles・公開鍵、Docker Engine、XDP の開発環境。設定タブの「例から追加…」で選ぶと、普通の項目として追加され、そのまま編集できる。Lima は起動のたびにプロビジョニングを実行するので、どのスクリプトも「済んでいれば何もしない」形にし、apt・dnf・apk を見分ける。公開鍵は `authorized_keys` に追記する（Lima の鍵があるので上書きしない）。Docker のグループは、Lima が使い回す SSH の接続には次のログインまで反映されない。スクリプトは LimaKit に、名前と説明はアプリ側に置く（翻訳のため）。E2E（`ProvisionExamplesEndToEndTests`）で Ubuntu LTS・Fedora・Debian・Alpine を確認。
- **プロビジョニングの「今すぐ実行」と「一度だけ実行」。** Lima のプロビジョニングは起動のたびに走るので、HanaLima が 2 つを足す。(1) 今すぐ実行（`ScriptRun`、`ProvisionScripts`）: 項目か例を、保存せずに実行中の VM で `limactl shell --tty=false <名前> sh -s`（標準入力にスクリプト）で実行し、出力をシートに流す。順番は起動時と同じ（data はファイルを書く、system は `sudo`、user はそのまま）。Lima のテンプレート変数（`{{.User}}` `{{.Home}}` `{{.UID}}` `{{.Name}}` `{{.Hostname}}`）はゲストの中で `sed` で展開する。data の親フォルダが無ければ所有者で作る（cloud-init は root のまま残す）。実行中は操作（`Operation.Kind.runScript`）として数え、起動・停止と重ならない。(2) 一度だけ実行（`ProvisionOnce`）: system・user のスクリプトを固定のラッパーで包み、成功したら印（root は `/var/lib/hanalima/once/<id>.done`、user は `$HOME/.local/state/hanalima/once/`）を残して以後の起動では何もしない。失敗は印を残さず次の起動で再試行する。本体はサブシェルで走らせるので、本体の `exit` でも印は付く。編集画面は本体だけを見せ、「もう一度実行」で id を変える。印はディスク上にあるので、複製は引き継ぎ、スナップショットを戻すとその時点に戻る。E2E は `ProvisionOnceEndToEndTests`（Alpine、2 回起動＋今すぐ実行）。
- **インストーラーの ISO から VM を作る（`InstallerVM`・`InstallSession`・`InstallerFixup`、docs/07）。** Lima は cloud-init 対応のイメージしか起動できないが、VM のファイルは `~/.lima/<名前>/` のただのファイルで、Lima は既存の `disk`・`vz-efi` をそのまま使う。そこで 1 MiB のダミーの raw イメージで `limactl create` して空の `disk` を作らせ、アプリ自身が Virtualization.framework（アプリ本体に `com.apple.security.virtualization` が要る）で ISO を USB の記憶装置として EFI 起動し、Lima の `disk`・`vz-efi`（インストーラーが書く起動エントリが残る）・`vz-identifier` を共有して OS を入れる。画面は `VZVirtualMachineView` なのでアプリのプロセスの中で動き、クリップボードは届かない。インストール後、ラベル `HANALIMA` の小さな ISO（`limaify.sh`、Lima の公開鍵、ユーザー名）を使って `sudo mount -L HANALIMA /mnt && sudo sh /mnt/limaify.sh` を手入力してもらい、cloud-init と sshd を入れ、インストーラーが残した cloud-init の設定を消して `cloud-init clean` で「次が初回」にする。あとは `limactl start` で Lima の cidata が設定する。記録に `pendingInstall` を持ち、Lima の起動が成功するまで起動・複製・ディスクの移動を止め、画面に「インストーラーを開く」を出す（印は Lima の初回起動が成功した時点で消す）。containerd はオフ。VZ 専用、ディスクはまず Mac の中。E2E は無人インストール（`InstallerAutoinstall`: ISO の shim と GRUB を FAT イメージに写し、HanaLima の `grub.cfg` で `autoinstall` を付けて EFI 起動。直接のカーネル起動は EFI が無くブートローダーの設定で失敗する。無人設定の YAML は `: ` を含む行を必ず引用する）。
- **socket_vmnet と HanaLima ネットワークの同時使用は、確認ダイアログを出したうえで許可する**（`NetworkConflict`）。netd はネットワークを使い回さないので、実機の 6 パターン（起動・再起動の順序、1 台の VM に両方の NIC）で問題は起きなかった。ほかのツールや古い netd が使い回すと macOS の不具合が起きうるので、警告は残している。

## v0.4 の機能と Lima 2.2.1 の実際の挙動

- **Lima のスナップショットは QEMU のみ、停止中だけ操作する**（VZ は HanaLima 独自の `DiskSnapshot`。上記）。VZ ドライバーは `unimplemented`。QEMU では、停止中は `qemu-img` の内部スナップショット（起動ディスクのみ）で、作成・適用・削除とも正しく動く。実行中は HMP `savevm` を使うが、9p の共有フォルダがあると QEMU が拒否し、**limactl は終了コード 0 を返す**（何も作られない）。さらに、`loadvm` に失敗すると VM が `restore-vm`（停止）のまま残る（QMP `cont` で再開できた）。そのため HanaLima は停止中だけ操作を許し、作成後は一覧にタグがあるかを確かめる。
- **スクリーンショットは、画面を有効にした VZ の VM だけ。** `limactl screenshot` は、ホストエージェントが表示している VM のウィンドウを `CGWindowListCreateImage` で撮る。QEMU は非対応、`video.display: none`（既定）では撮れない。ウィンドウを閉じると撮れなくなる。概要タブでは 3 秒ごとに更新する（表示中のみ）。
- **ログは差分だけ読む。** `ha.stderr.log`（logrus の JSON）と `serial*.log` を、前回の位置から追記分だけ読む（`LogFileFollower`）。Lima は起動のたびにファイルを作り直すので、i-node が変わるか小さくなったら最初から読み直す。シリアルの ANSI エスケープは除去する。
- **プロビジョニングは起動のたびに実行される**（cloud-init の `scripts_per_boot`）。冪等に書く必要があることを画面に明記している。スクリプト系（system/user/boot/dependency）と data は編集でき、`file` を使うものや yq・ansible は読み取り専用で保持する。
- **コードの編集は `CodeEditor`（NSTextView）で行う。** SwiftUI の TextEditor はシステム設定に従ってスマート引用符やダッシュに置き換えるため、スクリプトや YAML が壊れる。
- **メイン画面はメニューバーのアイコンから開く。** ウィンドウを閉じた状態で終了すると、ウィンドウの復元で「ウィンドウなし」が戻り、`.defaultLaunchBehavior(.presented)` や `.restorationBehavior(.disabled)` でも開かなかった。常に存在するメニューバーのラベルが、起動時にウィンドウがなければ `openWindow` で開き、`bootstrap()`（1 回だけ実行）も始める。

## 多言語対応

- **String Catalog（`Resources/Localizable.xcstrings`）を使い、元の言語は日本語。** キーは日本語の原文で、英訳をカタログに持つ。
- **文字列の抽出は Swift コンパイラーで行う**（`scripts/update-strings.sh`）。SwiftPM のビルドには Xcode のような自動抽出がない。`xcstringstool extract`（軽量な構文解析）は引数の型が分からず `%arg` を出すので、実行時のキー（`%@`、`%lld`）と一致しない。`-emit-localized-strings` でコンパイルすると正しいキーが得られる。別の scratch path でビルドするので、通常のビルドを壊さない。
- **`scripts/check-strings.py` で漏れを調べる。** コードで組み立てた文字列（`String(localized:)` が必要）、`LabeledContent(_:value:)` の value（翻訳されない）、文の一部だけを三項演算子で切り替えるもの（語順が言語で違うので文全体を書き分ける）が漏れやすい。
- **アプリの既定の言語は英語**（`CFBundleDevelopmentRegion = en`）。日本語でも英語でもない環境では英語になる。その代わり、日本語の訳がないキーは英語の表（複数形の規則も）を探しに行くので、`update-strings.sh` がすべてのキーに日本語の値を明示する。
- **「停止」のように、日本語では同じでも英語で訳し分けるものは、別のキーにする**（`vm-status.stopped`、`defaultValue: "停止"`）。
- **操作名に「中」を付けるような組み立てはしない。** 英語では語尾を付けられないので、`progressLabel`（「起動中」「Starting」）を別に持つ。

## macOS を更新したときの確認

HanaLima は、ドキュメントに約束されていない macOS の振る舞いに頼っているところがある。Apple は告知なく変えることがあるので、macOS のメジャー・マイナーの更新のたびに、次を確かめる（結果は docs/03 に記録する）。

| 頼っている振る舞い | 変わったときの影響 | 確かめ方 |
|---|---|---|
| `copyfile` の `COPYFILE_DATA_SPARSE` がデータの範囲だけを写し、末尾の穴で止まる | ディスクの移動で容量が膨らむ、またはディスクの長さが変わる | `swift test --filter ExternalDisk`（使用量が元と同じか、長さを補えているか、中止で何も残らないか） |
| シンボリックリンクにした `disk` を Lima（VZ・QEMU）がたどる。`limactl list` は本物のフォルダしか数えない | 外付けに移した VM が起動しない、または一覧から消える | `HANALIMA_E2E=1 swift test --filter ExternalDiskEndToEnd` |
| 外付けのボリュームの空き容量（「重要な用途」の値が返らないことがある） | 移動先が「空き不足」と誤判定される | 同上と、実機の外付けで移動のシートを開く |
| entitlement 付きの署名なら `vmnet_network` と従来のブリッジが root なしで動く | 仮想ネットワーク・ブリッジが作れない（1002 など） | `NetworkEndToEndTests`、`DHCPReservationEndToEndTests`、`BridgeEndToEndTests`（ブリッジはユーザーに確認してから） |
| vmnet の既知の不具合（下の節）とその回避 | 直っていれば回避が不要に、悪化していれば新しい回避が必要に | `Prototypes/vmnet-bridge100-repro`、上のネットワークの E2E |
| launchd が登録時のプログラムの cdhash を覚えている | ヘルパーの更新で `spawn failed`、または回避が不要に | アプリの更新後に `launchctl print gui/$(id -u)/org.izawa.HanaLima.net.<名前>` の終了コード |
| `NSWorkspace` のマウント・取り外しの通知 | ドライブの抜き差しで表示が古いまま残る | 外付けを抜き差しして、VM の画面の表示が切り替わるか |
| Lima の CLI（`limactl info`/`list`/`watch` の JSON、`prune`、`autostart`） | Lima の更新でも同じ。一覧・テンプレート・使用量が崩れる | 単体テストと `EndToEndTests` |

## macOS vmnet の既知の不具合（2026-10, macOS 27.0.1）

- アイドルになった `vmnet_network` は、ref を保持していても DHCP 予約とポート転送規則を失う（[フォーラム 847642](https://developer.apple.com/forums/thread/847642), FB24895271）。
- ブリッジ番号はネットワークの初回起動時に決まり、使い回すと衝突する（[apple/container#2051](https://github.com/apple/container/issues/2051)）。インターフェースを止めた `vmnet_network` を再利用すると、従来 API のブリッジの `bridge100` を奪い、`en0` を外し、**Mac 本体の IPv4 が消える**。Apple に **FB25122122** として報告済み。再現ツール: `Prototypes/vmnet-bridge100-repro`。回復は `sudo ipconfig set en0 DHCP` か再起動。
- 新規に作ったものどうしなら、従来のブリッジと共存できる（`bridge100` と `bridge101` に分かれる）。
- インターフェースを開始したままプロセスが終了すると、そのサブネットはしばらく（数時間か再起動まで）`vmnet_network_create` が 1001 になる。ほかにも、socket_vmnet の起動と重なったときなどに、1001 が 1 分以上続くことがある。netd は、VM が接続している間は 2 秒おきに作成を再試行し続ける（その間に VM が送るフレームは捨てる）。失敗しても netd 自体は終了しない。
- `vmnet_network_configuration_set_ipv4_subnet` に渡すのはゲートウェイ（.1）。ネットワークアドレス（.0）を渡すとインターフェースの開始に失敗する。
- entitlement なしの ad-hoc 署名では `vmnet_network_create` が 1002 で失敗する。従来の bridged モードも、この署名なら root なしで起動した（未調査）。
