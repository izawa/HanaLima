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

## 段階 2 の結果（2026-11-05）: Lima の vz と同等の構成

E2E `DriverEndToEndTests` を広げ、Alpine（起動 71 秒、停止 4 秒）で次がすべて通る: HanaLima のネットワーク（netd の `socket:`）の NIC、vzNAT の NIC、追加ディスク（Lima が `/mnt/lima-<名前>` にマウント、`in_use_by` のロックと解放）、vsock のゲストエージェント、ポート転送、停止後に残骸なし。

- **アプリ側**: `AppModel.bootstrap` が `LIMA_DRIVERS_PATH=<バンドル>/Contents/Helpers` を `limactl` の環境に足す（ドライバーが無いビルドでは足さない）。作成画面の「仮想化方式」に「HanaLima のドライバー（VZ、試験的）」が並ぶ（ドライバーがあるときだけ）。
- **NIC**: `networks[i].macAddress` は Lima の既定値（`MACAddress("<dir>#<i>")`）が Configure の JSON に埋まっているのでそれを使う。`socket:` は `StreamDatagramRelay`（QEMU の 4 バイト長＋フレームのストリーム ↔ SOCK_DGRAM の socketpair。Lima の `DialQemu` と同じ）、`vzNAT` は `VZNATNetworkDeviceAttachment`。`lima:`（socket_vmnet、user-v2）は未対応でエラーにする。
- **追加ディスク**: `<LimaHome>/_disks/<名前>/datadisk`。**Lima 2.2.1 の `limactl disk create --format raw` は「raw を作る」と言いながら qcow2 を作る**（`disk list` も qcow2）。Lima の vz は最初の接続時に qcow2 を raw に書き換えるので、ドライバーも同じく `QCOW2Converter`（Codex が書いた v2/v3 の読み出し、圧縮・backing・暗号は拒否、スパースに書く）で `datadisk.hanalima-raw` に変換して `replaceItemAt` で置き換える。qemu-img の出力と 2 種類の画像で `cmp` 一致。ロックは `in_use_by` → VM のフォルダのシンボリックリンク（別の VM のものならエラー）。**デバイスの順番は disk（vda）、追加ディスク（vdb…）、cidata が最後**。cidata を先に付けると Lima の `05-lima-disks.sh` が cidata を `sfdisk` しようとして失敗する。
- **vsock**: `VZVirtioSocketDeviceConfiguration` を付け、`Info` の `vsockPort` を 2222、`ForwardGuestAgent` を false にする。hostagent は `GuestAgentConn` のあと `<dir>/ga.sock` に unix で接続する（Go の外部ドライバーではサーバー側の共通コードが橋渡しするが、Swift では自前）。`UnixSocketBridge`（Codex）が `ga.sock` で待ち受け、接続ごとに `VZVirtioSocketDevice.connect(toPort: 2222)` を VZ のキューで行い、その fd の dup と双方向コピーする。bridge の close は接続の終了を待たない（VM が消えた vsock は答えないので、待つと teardown が止まり、usernet と pid ファイルが残った）。
- **teardown は actor の外**（`Task.detached`）: usernet の終了待ち（最大 5 秒）で Info まで止まらないように。usernet の起動待ちも同様。
- **「ゲストが usernet に何も送らない」の原因（段階 1 の未解決、2〜5 回に 1 回）**: 失敗時は fd 渡しは成功していて（usernet と VZ のヘルパーが socketpair の両端を持つ）、usernet の `/stats` が `BytesReceived: 0`。違いは、Lima の `PassFDToUnix` が fd を渡したストリーム接続を**閉じない**のに対し、こちらは sendmsg の直後に閉じていたこと（と、バッファを SND 1 MiB／RCV 4 MiB にせず両方 1 MiB にしていたこと）。Lima に揃えてストリームを VM の寿命のあいだ開いたままにし、バッファも同じにしたら 12 回連続で通った。usernet の `listenFD` は `fd.Get` のあともその接続を持ち続けるので、こちらの hang-up が何かを壊すのだと思われる（Go 側の `Recvmsg` は data を nil で呼ぶ）。
- **2 回目の Codex のレビューで直した 7 点**: ディスクのロックを変換より先に（別の VM が使っているディスクを書き換えない）、変換の一時ファイルを pid 付きの名前にして失敗時に消す、Start/Stop の再入（`busy`）、teardown 中の次の Start を拒む、vsock の接続オブジェクトは dup のあと閉じる（保持し続けると fd が増える）、relay の `dup` の失敗を見る。
- **残る不安定さ**: Alpine で追加ディスクが `/mnt/lima-<名前>` にマウントされないことが 4 回中 1 回あった（起動自体は通る）。Lima の `05-lima-disks.sh` が初回起動で `sfdisk`・`mkfs.ext4` を要し、それは `10-alpine-prep.sh` の apk が入れるので、初回の DNS かミラーの揺らぎを疑っている。E2E は失敗時にブートログの該当箇所を出すようにした。Ubuntu では 4 回とも通る。
- **孤児の注意**: 手動の調査で `limactl usernet` を起動したまま親を落とすと残る（1 時間 52 分動いていた）。`ps -axo pid,ppid,command | grep usernet` で確かめる。
- **Codex の部品の品質**: `UnixSocketBridge` と `QCOW2Converter` は自己テストが通った。`StreamDatagramRelay` は Codex 版が自己テストの終了処理で詰まった（データは両方向に流れていた）ので、同じ設計で短く書き直した。

## 段階 3 の結果（2026-11-05）: 画面、シリアル、既存 VM の移行

- **Lima の `RunGUI` は外部ドライバーでは使えない。** `pkg/driver/external/client/methods.go` の `RunGUI` は 10 秒の `context.WithTimeout` で呼び、hostagent は `CanRunGUI` なら `return a.driver.RunGUI(ctx)` で `Run` を終える（内部の vz は VM が止まるまで `RunGUI` が返らない前提）。外部ドライバーが待てば 10 秒で DeadlineExceeded、すぐ返せば `Run` が nil で返り、どちらでも hostagent のプロセスが終わる。`limactl screenshot` も `driver.Screenshotter` を内部ドライバーにしか問わない。そこで `Info` は `canRunGui: false` のまま、画面はドライバーが自分で出す。
- **画面はドライバーのプロセスのウインドウ**（`DisplayWindow`）。`VZVirtualMachineView` は同じプロセスの VM しか映せないので、HanaLima のウインドウには出せない（アプリをドライバーにする案は VM の寿命がアプリに縛られ、ログイン時の自動起動も壊れるので採らない）。`Main` は `NSApplication` を main スレッドで回し（`setActivationPolicy(.prohibited)`）、gRPC と VM は別のスレッド。`video.display` が `none` でなければ `VZVirtioGraphicsDeviceConfiguration`（1920×1200、Lima の vz と同じ）・USB キーボード・ポインタを付け、起動後に `NSWindow` を開く。閉じる（`windowShouldClose`）は隠すだけで VM は動き続け、`openScreen` で開き直す。ウインドウを出す間は `.regular`（Cmd-Tab に出る。Dock のアイコンは `Contents/Resources/AppIcon.icns`、名前は実行ファイル名のまま）、隠すと `.accessory`。別キューの `VZVirtualMachine` を view に渡すのは Lima の vz（Go）と同じで、macOS 27 の `VZVirtualMachineViewAdaptor` は使わない（26 でも動かすため。`@unchecked Sendable` の箱で main に運ぶ）。
- **スクリーンショットは Lima の vz と同じ `CGWindowListCreateImage`。** macOS 26 の SDK はこれを「15 以降では使えない」と印し（ScreenCaptureKit を勧める）、Swift からは呼べないが、関数自体は残っていて Lima 2.2.1（`-mmacosx-version-min=11`）はこれで撮っている。ScreenCaptureKit は自分のウインドウでも画面収録の許可を求めるので、`dlsym` で呼ぶ。撮れるのはウインドウが表示中のときだけ（隠すとエラー。Lima と同じ）。タイトルバーを除いてゲストの画面だけに切り出す。
- **HanaLima とドライバーの側道 `hanalima-ctl.sock`**（`ControlServer`、LimaKit の `DriverControl`）: 1 接続に JSON 1 行ずつ。`status`（VZ の状態名、画面の有無、表示中か）、`openScreen`、`screenshot`（PNG を base64）。アプリは概要タブのサムネイルと「画面を開く」で使う。`limactl create` はドライバーを SIGKILL で終えるので、作成直後はこのソケットファイルが残る（接続は拒否されるだけ。次の起動で作り直す）。
- **シリアルコンソールは双方向**（`SerialConsole`）: `VZFileHandleSerialPortAttachment` に socketpair の片側を渡し、もう片側から読んだものを `serialv.log` と `serialv.sock`（Lima の QEMU の名前）の接続先へ流し、接続先からの入力をゲストへ書く。Lima 2.2.1 の vz は書き込み専用のログしか付けないので（docs/03 §30）、これが「シリアルからログインする」の答え。アプリのコンソールタブは `serialv.sock` があれば「シェル／シリアル」を切り替えられ、シリアルは `sh -c 'stty raw -echo; exec /usr/bin/nc -U "$1"'` を SwiftTerm の pty で動かす（`/usr/local/bin/nc` は Intel 版の残骸で落ちるので絶対パス）。
- **落とし穴: イメージは hvc0 を使っていない。** Alpine（lima 3.23）のカーネル行は `console=ttyS0,115200n8 console=ttyAMA0,115200n8` で、inittab は `tty1` の getty だけ。つまり virtio コンソールにはカーネルも getty も何も書かず、`serialv.log` は Lima の vz でも空。ゲストの中で `echo … > /dev/hvc0` と書くとホストに届くので中継は正しい。使えるようにするのはプロビジョニングの例「コンソールに自動ログイン（画面・シリアル）」で、systemd は `serial-getty@hvc0.service.d` のドロップイン（`agetty --autologin <user> --keep-baud 115200,… %I`）と `enable`、Alpine は inittab に `hvc0::respawn:/sbin/agetty --autologin <user> --noclear hvc0 linux`。起動ログまで hvc0 に出すにはカーネル行の `console=hvc0` が要り、ディストリビューションごとに違う（grub、extlinux）ので例では触らない。
- **既存 VM の移行は `limactl edit --set '.vmType = "hanalima"'` だけ。** Lima は `vmType` の変更を禁じておらず（`ValidateAgainstLatestConfig` はディスクの縮小だけ）、`edit` は新しい `vmType` のドライバーで `Validate` を呼ぶ。`disk`・`vz-efi`・`vz-identifier` は vz と同じファイルなので、vz で書いたファイルは hanalima で見え、戻しても見える（使い捨ての Alpine で往復を確認。`DriverMigrationEndToEndTests`）。設定タブの「ハードウェア」に「仮想化方式」のピッカー（vz ⇄ hanalima、ドライバー入りのビルドのとき）。`Validate` で断るもの（理由は `lima.REJECTED.yaml`）: Rosetta、`ssh.overVsock: true`、virtiofs 以外の `mountType`（マウントがあるとき）、`lima:` のネットワーク。
- **アプリ側の「VZ だけ」判定を「vz か hanalima」に広げた**（`LimaInstance.usesVirtualization`）: vzNAT の選択肢、画面のサムネイル、救出起動（同じ `disk`・`vz-efi`・MAC の導出）。QEMU の判定（スナップショット、複製、ログの順）はそのまま。
- **3 回目の Codex のレビューで直した 3 点**: シリアルの接続先の fd は読む側のスレッドだけが（ロックの中で）閉じ、送る側はロックの中で `MSG_DONTWAIT` で送る（閉じた番号が再利用されて別の接続に書く競合）、`SerialConsole` の初期化が途中で失敗したときの socketpair の解放、閉じた（VM が止まった）ウインドウは `dismiss` で無効にし `openScreen` と `screenshot` を断る（teardown と要求の順序）。
- E2E: `DriverEndToEndTests`（自動ログインの例を入れ、hvc0 のシェルでコマンドを実行して出力が `serialv.sock` と `serialv.log` に出ること、制御ソケットの `status`、画面なしの VM では `openScreen` が断られること。Alpine、起動 69〜75 秒）、`DriverMigrationEndToEndTests`（130 秒）。Alpine の追加ディスクのマウントの揺らぎ（段階 2）はこの日も 8 回中 3 回あり、原因がわかった: Lima の `05-lima-disks.sh` が `sfdisk` → `mkfs` → `mount /dev/vdb1` と進むうち、`mount` が `fsconfig() failed: /dev/vdb1: Can't lookup blockdev` で落ちる（`/proc/partitions` には vdb1 があり `mkfs.ext4` も通っているのに、`/dev/vdb1` のノードが無く `/dev/vdb` だけになっている。dmesg には `vdb: vdb1` が 2 回（初回の検出と sfdisk の再読み込み）出ていて、mdev が remove と add の順を取り違えてノードを消したように見える。`mdev -s` で作り直すと mount できる。ゲスト側（mdev）の競合で、DNS やミラーではない）。**Lima 自身の vz でも同じ**（同じ Alpine＋raw の追加ディスクで初回起動を 4 回繰り返して 2 回失敗）なので、ドライバーの問題ではない。E2E は Lima が付け損ねたときは `mdev -s` でノードを作り直して自分で `mount` し、接続と区画を確かめる。
- **残り**: `lima:` のネットワーク（socket_vmnet、user-v2）、Rosetta、スナップショット（VZ 側は HanaLima の `DiskSnapshot` が vmType を問わず使える）、macOS ゲスト、SSH の vsock 化、一時停止（`VZVirtualMachine.pause`／`saveMachineState`。Lima に「一時停止」の状態がないので、側道で持つなら Lima からは Running に見える）。
