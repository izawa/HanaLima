# 09. Lima の外部ドライバーで VZ を自前にできるか（2026-11-05 調査）

HanaLima が Lima に任せている部分のうち、Virtualization.framework の操作だけを自前にする道として、Lima 2.x の**外部 VM ドライバー**を調べた。Lima 2.2.1 のソース（`pkg/driver`、`pkg/driver/external`、`pkg/registry`、`pkg/driverutil`、`pkg/hostagent`、`pkg/driver/vz`、`pkg/networks/usernet`）と公式ドキュメント（lima-vm.io/docs/dev/drivers/）による。コードは書いていない。

## 結論

- **できる。** Lima 2.0 以降、VM ドライバーは `lima-driver-<名前>` という別の実行ファイルにでき、hostagent は gRPC（Unix ソケット）で呼ぶ。ドライバーは Go でなくてよい（契約は `driver.proto` だけ。公式は「実験的で API は変わりうる」と明記）。
- **Lima が残してくれるもの**: イメージの取得と変換、テンプレート、cloud-init（cidata.iso）、SSH の鍵と待ち受け、ポート転送、ゲストエージェントとの会話、`list`/`watch`、autostart、clone、edit、ゲストの初期化スクリプト。つまり [docs/03 §31 の検討](03-development-log.md)で「難しい」とした層はすべて残る。
- **自前になるもの**: VZ の設定と起動・停止、**NIC 0 のユーザーモードネットワーク（usernet）**、vsock でのゲストエージェント接続、画面。usernet は hostagent ではなく **vz ドライバーの中で動いている**ので、ドライバーを替えるとこれも引き受ける。ただし Lima は `limactl usernet` という独立したサブコマンドで同じネットスタックを提供しており、HanaLima のドライバーはそれを子プロセスとして起動して使える。
- **名前は `vz` にできない。** 内部ドライバーと同名の外部ドライバーは登録時に無視される（`registry.registerExternalDriver`）。`vmType: hanalima`（仮）のような新しい名前になり、既存の VM は `lima.yaml` の `vmType` を書き換えて移す（Lima は「vmType は作成後に変えられない」としているが、ファイルの実体は同じ）。
- 工数の目安は **1.5〜2 人月**（gRPC の口、VZ の構成、usernet の受け渡し、vsock、E2E、既存 VM の移行）。得るもの: シリアルの双方向（救出起動が不要になる）、VZ の `saveMachineState` による一時停止・再開、ディスクの置き場所の自由、起動完了の判定を SSH でなく vsock で行える、画面を HanaLima のウインドウに出せる。

## 仕組み（Lima 2.2.1）

### 発見と起動

- 探す場所: 環境変数 `LIMA_DRIVERS_PATH`（`:` 区切り、ディレクトリかファイル）と、`limactl` の置き場所から決まる標準ディレクトリ `<prefix>/libexec/lima/` と `<prefix>/lib/lima/`（Homebrew では `/opt/homebrew/lib/lima/`。`libexec` は Homebrew が私用に取るため）。実行可能で `lima-driver-` で始まるファイルが名前 `<名前>` のドライバーになる（`pkg/registry/registry.go`）。
- 選び方: `limactl create --vm-type=<名前>`。`vmType` の検証は組み込みの一覧か登録済みのドライバーにあれば通る（`driverutil.ResolveVMType`）。`limactl info` の `vmTypes` に外部ドライバーも並ぶ。
- 起動: hostagent が `<ドライバー> --inst-dir <VM のフォルダ>` を実行し、stderr を `<VM>/driver.stderr.log` に、PID を `<VM>/<名前>.drv.pid` に書く。ドライバーは `<VM>/<名前>.drv.sock` で gRPC を待ち受ける。**ソケットがすでに応答すれば、新しいプロセスを起動せずそれに接続する**（`server.Start` の "Reusing already-running external driver server"）。つまり HanaLima のアプリ自身がこのソケットで待ち受けていれば、hostagent はアプリに接続する。
- 状態の問い合わせ: `limactl list` は `<ドライバー> --inspect-status` を実行し、stdin に instance の JSON を渡して stdout の JSON を読む（VM が動いていなくても呼ばれる。vz ドライバーは空文字を返して hostagent の PID 判定に任せる）。

### 契約（`driver.proto`、JSON を運ぶ gRPC）

起動の順序は `Configure`（instance の JSON を渡し、既定値を埋めた JSON を返す。`SSHLocalPort` もここで届く）→ `Validate` → `Create`（`vz-identifier` のような初回の支度。冪等。ディスクは作らない）→ `CreateDisk` → `Start`（サーバーストリーミング。起動を始めたら最初の応答、以後のエラーをストリームで、終了時に最後の応答）→ `AdditionalSetupForSSH`（最初の SSH の前。vz はここで usernet が SSH ポートを転送し始めるのを待つ）→ `SSHAddress`（`dynamicSSHAddress` のときだけ再照会）。ほかに `Stop`（ブロックして終わるまで待つ）、`Delete`、`BootScripts`（cidata に入れる `boot.Linux/<名前>` のスクリプト。vz は Rosetta のマウントの 1 本だけ）、`Info`（名前、vsock のポート、virtio のポート、機能フラグの JSON。hostagent が定期的に呼ぶのでサーバーは並行に応答する）、`RunGUI`（`canRunGui` のとき hostagent が呼び、VM が終わるまでブロック）、スナップショット 4 つ、`ForwardGuestAgent`／`GuestAgentConn`。`limactl create` は `Configure` と `Create` だけを呼ぶ。

### ネットワーク（いちばん重い部分）

- NIC 0（`192.168.5.0/24`、SSH の転送、DNS、`host.lima.internal`）は gvisor-tap-vsock のネットスタックで、**vz ドライバーの `startVM` が自分のプロセス内で起動している**（`startUsernet`）。hostagent が動かすのは hostResolver の DNS だけ。
- ドライバーと netstack のつなぎ方は 2 つのソケット: `<VM>/…_ep.sock`（HTTP のエンドポイント。gvproxy の API: `/services/forwarder/expose`・`unexpose`、`/services/dhcp/leases`、Lima 拡張の `/extension/wait_port?ip=&port=22&timeout=`、DNS の静的ホスト追加）と `<VM>/…_fd.sock`（SCM_RIGHTS で socketpair の片側を渡す "Bess 互換"。VZ 側は `VZFileHandleNetworkDeviceAttachment` にもう片側を付ける）。
- Lima には同じネットスタックを単独で動かす **`limactl usernet --endpoint <ep.sock> --listen <fd.sock> --subnet 192.168.5.0/24 --leases 192.168.5.15=<MAC>`** がある（`lima:user-v2` ネットワークの実体）。外部ドライバーはこれを子プロセスにし、HTTP と SCM_RIGHTS を自分で話せばよい。起動後の手順は vz ドライバーと同じ: DHCP のリースで MAC → IP を引き、`expose` で `127.0.0.1:<SSHLocalPort>` を `<IP>:22` に転送し、`wait_port` で sshd が開くのを待ってから `AdditionalSetupForSSH` を返す。
- vz ドライバーは SSH を vsock（ポート 22 相当）でも試し、通れば usernet の転送をやめる。これは省略できる（usernet の転送だけでも動く）。
- `networks:` の `socket:`（HanaLima の netd）、`vzNAT`、`lima:*` はドライバーが VZ のデバイスとして付ける。netd の socket は QEMU 互換ストリーム（4 バイト長＋フレーム）を unixgram に変換する `DialQemu` が要るが、これは `hanalima-netd` が話している側のプロトコルなので HanaLima の既知の領域。

### ゲストエージェント

- `ForwardGuestAgent` が false なら、ドライバーの `GuestAgentConn` が返した接続（vz は vsock のポート 2222）を**外部ドライバーのサーバー側が `<VM>/ga.sock` に橋渡し**し、hostagent はそこに unix で接続する。Swift のドライバーも `VZVirtioSocketDevice` で接続し、ga.sock で待ち受ければよい。true を返せば hostagent が SSH で転送するので、最初は true で済ませられる。

### 画面

- 内部の vz は hostagent のプロセス（`limactl`、`runtime.LockOSThread`）で `VZVirtualMachineView` のウインドウを開く。外部ドライバーでは `RunGUI` が**ドライバーのプロセス**で呼ばれるので、画面を出すならドライバーが GUI を持てるプロセス（LSUIElement のアプリか、HanaLima 本体）である必要がある。HanaLima 本体がソケットで待ち受ける形なら、画面は HanaLima のウインドウに出せる（一方で HanaLima を終了すると VM も止まる。インストーラーと同じ）。VM をアプリから独立させたいなら、別プロセスのドライバーにして画面は後回し。

### ディスク

- `CreateDisk` はドライバーの仕事。vz は `SupportedImageFormats: raw, asif` を名乗り、Lima 側が qcow2 を raw に変換して渡す（`pkg/imgutil`）。HanaLima のドライバーは置き場所（外付けドライブ）を `CreateDisk` の時点で選べるようになる。

## HanaLima でやるとしたら

1. **段階 0（1〜2 日）**: Go の `cmd/lima-driver-vz` を `make ADDITIONAL_DRIVERS=vz limactl additional-drivers` で外部化し、`LIMA_DRIVERS_PATH` に置いて `--vm-type=vz` が外部で動くこと、`driver.stderr.log` と `vz.drv.sock` の挙動、`limactl list` の `--inspect-status` の呼ばれ方を実機で見る。名前の衝突（内部 `vz` が優先）もここで確認する。
2. **段階 1（2〜3 週）**: Swift の `lima-driver-hanalima`。grpc-swift（Swift 6）でサーバー、protobuf は `driver.proto` から生成。`Configure`/`Info`/`Create`/`CreateDisk`/`Start`/`Stop`/`Validate`/`BootScripts`/`SSHAddress`。VZ の構成は `HostedVM` を土台に。usernet は `limactl usernet` の子プロセス＋HTTP＋SCM_RIGHTS。`ForwardGuestAgent` は true。画面なし。E2E: Alpine と Ubuntu LTS で `limactl create --vm-type=hanalima` → start → shell → stop。
3. **段階 2（1〜2 週）**: vsock のゲストエージェント（`ga.sock`）、シリアルの双方向（HanaLima のコンソールに serial 端末を足す）、`saveMachineState` による一時停止、netd の `socket:` NIC、vzNAT、virtiofs の共有（`mounts` の `virtiofs` はドライバーがタグを付け、ゲスト側は Lima の boot script がマウントする。タグの命名を vz と揃える）。
4. **段階 3**: 画面（HanaLima 本体がドライバーを兼ねるか、別プロセスで `RunGUI`）、既存 VM の移行（`vmType` の書き換え。`vz-efi`・`vz-identifier`・`disk` はそのまま使える）、QEMU の VM はこれまで通り Lima の内部ドライバー。

## 注意

- API は実験的（公式の明記）。Lima 2.3.0-rc では Unix ソケットの転送が gRPC に変わるなど周辺が動いている（docs/03 §29）。`driver.proto` の差分を版ごとに追う前提になる。
- `vmType` を新しい名前にすると、HanaLima なしの `limactl start` はドライバーが見つからず失敗する（ドライバーの実行ファイルを `/opt/homebrew/lib/lima/` に置けば HanaLima を起動していなくても動く。これは `hanalima-netd` と同じ配り方）。
- Rosetta（`rosettaEnabled`/`rosettaBinFmt`）と virtiofs のタグ、`05-rosetta-volume.sh` の boot script は vz の実装を写す。
- 外部ドライバーの `Info` は hostagent から頻繁に呼ばれ、10 秒のタイムアウトがある。サーバーは並行に答える。

## 隔離への応用（docs/06 の未解決への答え）

docs/06 で「Lima を改造しないと NIC 0（usernet）は外せず、Mac の 127.0.0.1・LAN・インターネットに届く」と結論した。外部ドライバーなら NIC 0 を付けるかどうかをドライバーが決めるので、改造なしに「隔離のプロファイル」が作れる見込み。

- Lima の配管は usernet 無しで成り立つ材料を持っている。SSH: vz ドライバーは起動後に vsock のポート 22 を試し、通れば usernet の転送をやめる（`startVsockForwarder`。ゲスト側は systemd 256 以降の `systemd-ssh-generator`。Ubuntu 24.10・Fedora 41 以降は無設定。それ以前と Alpine はドライバーの `BootScripts` で vsock の socket unit か socat を入れる）。ゲストエージェント: `GuestAgentConn` が vsock を返せばよい。ポートの自動転送: 2.x ではエージェントの gRPC トンネル経由。失うのは hostagent の DNS（hostResolver）だけ。
- プロファイル案: (a) NIC なし＝ホストとの接点は vsock と共有フォルダだけ。(b) NIC 0 を HanaLima のホストオンリーに＝届くのはそのサブネットだけ。Mac の 127.0.0.1 だけで待つサービス、LAN、インターネットには届かない。ただし Mac はブリッジのゲートウェイ IP でそのサブネットに居るので、`0.0.0.0` で待つサービスには届く。
- cidata の network-config は usernet の MAC で eth0 を書くが `optional: true` なので NIC が無くても起動は止まらない。apt・dnf は出られないので、プロビジョニングはその VM では使えない前提。
- Lima 2.3 の `hostLoopback: false`（docs/03 §29）は 127.0.0.1 だけを塞ぐ部分解で、こちらはそれより強く切れる。

## 段階 0 の結果（2026-11-05、実機）

Lima 2.2.1 の `cmd/lima-driver-vz` を `go build` して ad-hoc 署名（`vz.entitlements`）し、`LIMA_DRIVERS_PATH` の下に `lima-driver-vz` と `lima-driver-hanalima` の 2 名で置いた。

- **名前**: `lima-driver-vz` は「内部に同名あり」で無視され（`--debug` に "already registered as an internal driver" と出る）、`lima-driver-hanalima` は `limactl info` の `vmTypes` に `hanalima` として並ぶ。Homebrew の標準の置き場所は `/opt/homebrew/Cellar/lima/2.2.1/libexec/lima/`（Lima 自身が krunkit をここに外部ドライバーとして入れている）。版ごとに変わるので、HanaLima は `LIMA_DRIVERS_PATH` を `limactl` の環境に足す方が確実。
- **プロセスとファイル**: `limactl start` で hostagent がドライバーを `--inst-dir` 付きで起動し、`<VM>/hanalima.drv.sock`・`hanalima.drv.pid`・`driver.stderr.log` ができる。usernet のソケットは `default_ep.sock`・`default_fd.sock`。`limactl stop` は "Waiting for the host agent and the driver processes to shut down" のあと 14 秒で終わり、ドライバーのプロセスもソケットも消える。`limactl list` は `vmType` に `hanalima` と出す。`LIMA_DRIVERS_PATH` が無い環境で `limactl list` すると、その VM は "vmType `hanalima` is not a registered driver" の警告つきで空の行になる（壊れはしない）。
- **`--inspect-status`**: stdin に instance の JSON（`limactl list --format json` と同じ形）を Go の `[]byte` の JSON（base64 の文字列）で渡し、stdout に同じ形で返す。
- **落とし穴（最初の起動が失敗した原因）**: cidata は `vmType == "vz"` のときだけ DNS を usernet のゲートウェイ（192.168.5.2）にし、それ以外は QEMU の SLIRP の流儀で 192.168.5.3 にする（`pkg/cidata/cidata.go`）。gvisor の usernet は .3 に答えないので、Alpine の `10-alpine-prep.sh` が apk の DNS で失敗し、その中の `usermod -p '*'` が走らず、ロックされたままのアカウントを sshd が拒否して（"Permission denied (publickey)"）起動が 10 分でタイムアウトした。**`dns: [192.168.5.2]` と `hostResolver.enabled: false` を入れると通る**（Alpine、57 秒で READY。DNS、virtiofs の共有（`05-lima-mounts.sh` は vz 以外で何もしないが、cloud-init の `mounts:` の fstab でマウントされる）、ゲストエージェントの vsock、`limactl shell` まで正常）。Swift のドライバーでは `Configure` の応答でこの 2 つを補えばよい（hostagent は応答の JSON で instance を置き換えてから cidata を作る）。ほかに `vmType` の名前で分岐しているのは `05-lima-mounts.sh`（パスの空白の扱い）だけ。
- **注意**: `limactl start <存在しない名前>` は既定テンプレート（Ubuntu、4 CPU、4 GiB、100 GiB）で VM を作ってしまう。`create` の失敗を確かめずに `start` を続けない。
- **Swift のスタブで gRPC が通った**（`Prototypes/lima-driver-spike`、Codex に骨組みを書かせて手で直した）: `limactl create --vm-type=hanalima` が Info → Configure → Create（1 回目の起動）、Configure → Validate → Create → Info → CreateDisk（2 回目）の順にスタブを呼び、`limactl list`（`--inspect-status`）と `delete` も通る。ドライバーのプロセスは呼び出しのたびに起動され、`create` の終わりで消える。分かったこと: (1) **Lima はドライバーの `Configure` に既定値を埋めさせる**。`mountType` を空で返すと `limayaml.Validate` が nil を踏んで `limactl` が panic する（vz の `fillConfig` 相当: `mountType`、`ssh.overVsock`、`vmOpts.vz`）。(2) **Lima はソケットを「接続して即 close」で疎通確認する**が、Darwin の NIO はその accept で `NIOFcntlFailedError` を出し、grpc-swift-nio-transport はそれで accept ループごと終わる（listen し直しても Go 側の dial に間に合わない）。待ち受けチャネルに `errorCaught` でその例外だけ握りつぶすハンドラを `channelDebuggingCallbacks.onBindTCPListener` から足して解決。(3) grpc-swift-protobuf のプラグインは `protoc.executablePath` を設定しないと protoc を見つけない。(4) パッケージは `grpc-swift-2`・`grpc-swift-nio-transport` 2.x・`grpc-swift-protobuf` 2.x で揃える（2.0.0 のタグが別リポジトリを指していて重複する）。
- 段階 0 の結論: **外部ドライバーの経路は Swift から使える。** 段階 1 は、このスタブに `HostedVM` の VZ 起動と `limactl usernet` の接続を足すこと。

## 段階 1 の結果（2026-11-05）: Swift のドライバーで Lima の VM が起動する

`Driver/`（別パッケージ、`lima-driver-hanalima`）。Lima の `limactl start` が Swift のドライバーを呼び、ドライバーのプロセスの中で Virtualization.framework が VM を動かし、`limactl shell`・DNS・virtiofs の共有・ゲストエージェント・ポート転送・`limactl stop` まで通った（E2E `DriverEndToEndTests`、Alpine: 起動 53 秒、停止 5 秒、残骸なし）。

- **構成**: `InstanceSpec`（Configure の JSON から dir・cpus・memory・sshLocalPort・mounts）、`VZMachine`（専用の DispatchQueue、EFI の変数ストア、識別子、disk、cidata、virtiofs のタグ `lima-<sha256(location:mountPoint) の先頭 8 バイト>`、serialv.log、エントロピー、バルーン、NIC は `VZFileHandleNetworkDeviceAttachment` に Lima の MAC）、`DriverCore`（actor。usernet の子プロセス、socketpair、SSH の転送、停止）、`DriverService`（gRPC）、`FDPassing`・`UsernetClient`（Codex が書き、自己テストで確認）。
- **Configure で埋めるもの**: `mountType: virtiofs`、`ssh.overVsock: false`、`vmOpts.vz`、`dns: [192.168.5.2]` と `hostResolver.enabled: false`（段階 0 の落とし穴）。
- **CreateDisk**: `image`（Lima の imgconv キャッシュから来る raw）を `disk` に改名するだけ。大きさの変更は Lima の `instance/start.go` がそのあとで行う。
- **usernet**: `limactl usernet --endpoint <dir>/default_ep.sock --listen <dir>/default_fd.sock --subnet 192.168.5.0/24 --leases 192.168.5.15=<MAC> --pidfile …`。socketpair（SOCK_DGRAM、送受信バッファ 1〜4 MiB）の片側を `default_fd.sock` に SCM_RIGHTS で渡し、もう片側を VZ に付ける。静的リースなので `/services/dhcp/leases` には起動前から 192.168.5.15 が載る。
- **wait_port は使わない**: usernet の `/extension/wait_port` は、ポートが開いた瞬間に応答を書かずに接続を閉じる（curl でも再現）。Lima の Go クライアントは EOF で再試行するので気づかない。ドライバーは転送先 `127.0.0.1:<sshLocalPort>` に接続して `SSH-` のバナーが返るまで待つ。usernet は accept してからゲストに dial するので、接続できるだけでは足りない。
- **pid ファイル**: `<dir>/hanalima.pid` に自分の pid（`limactl stop --force` が殺す）、`hanalima-usernet.pid`。停止で両方消す。
- **grpc-swift の注意**（段階 0 の 4 点に加えて）: 生成物（`Generated/driver.pb.swift`・`driver.grpc.swift`）はコミットし、protoc をビルドの必須にしない。
- **未解決の 1 回**: Lima 経由の最初の起動で、VM は running なのにゲストが usernet に一切パケットを出さず、10 分でタイムアウトした（usernet のログに tcpproxy の dial 失敗だけ）。直後に同じ構成で起動すると通り、以後は再現していない。直前のスモークの停止から 1 秒後の起動だったので、EFI の変数ストアか NIC の初期化の競合を疑っている。E2E の回数を重ねて様子を見る。
- **Codex のレビュー（読み取りのみ）で直した 8 点**: `VZMachine.stop` が starting/stopping の途中を「止まった」と誤認する、Stop が中断している間に次の Start が走ると古い Stop が新しい VM を片付ける（起動ごとの世代番号で防ぐ）、Start の途中失敗で usernet と pid ファイルが残る、強制停止の失敗で Start のストリームが終わらない、usernet の古い pid ファイルで再起動が拒まれる（`--pidfile` は既存を拒否）、VZ の delegate をキューの外で設定していた、gRPC サーバーの異常終了で usernet が残る、qcow2 の magic の比較が UTF-8 で壊れていた。
- **usernet の道連れ**: `limactl delete --force` はドライバーを SIGKILL するので、usernet が孤児になった（実機で 1 件）。macOS に親の死の通知は無いので、usernet は `sh` の番犬（ドライバーの pid を 1 秒おきに `kill -0`、消えたら子を kill、SIGTERM は trap で転送）の下で動かす。kill -9 の実機確認: usernet は 4 秒以内に消える。残った hostagent のせいで Lima は VM を "Broken: host agent is running but driver is not" と表示し、`start` を拒む（`delete --force` は通る）。これは Lima の外部ドライバー一般の挙動。
- **E2E**: Alpine（起動 58 秒、停止 5 秒）と Ubuntu LTS（起動 42 秒、停止 8 秒）。Ubuntu は resolv.conf が systemd-resolved なので `resolvectl status` も見る、nc が無いので python3 で待ち受ける。URLSession の既定の 60 秒タイムアウトで転送の確認ループが 20 分になった（3 秒に短縮）。
- **起動が失敗する経路**（`vz-efi` をディレクトリにして確認）: `limactl start` は 2 秒で fatal になり、ドライバーの pid ファイルと usernet は残らない。残るのは Lima 側の `hanalima.drv.pid`・`.drv.sock`。
- **ドライバーのプロセスの親は hostagent ではない**: 起動の Prepare（Configure・Create・CreateDisk）を `limactl start` のプロセスが起動したドライバーで行い、hostagent はその「動いているサーバー」を使い回す。だから「親が消えたら終了する」番犬をドライバーに入れると、`limactl start` が READY で抜けた瞬間にドライバーが死んで VM が Broken になる（実機で確認して取り消した）。
- **残り（段階 2 へ）:** vsock のゲストエージェント（`ga.sock` の橋渡し）、SSH の vsock 化、`socket:` の NIC（netd）、vzNAT、追加ディスク、Rosetta、画面、アプリ側（作成画面の `hanalima`、`LIMA_DRIVERS_PATH=Contents/Helpers` を `ProcessRunner` の環境に）。
