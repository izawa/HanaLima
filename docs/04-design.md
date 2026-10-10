# 設計メモ

HanaLima の設計上の判断と、その理由をまとめる。経緯は [03](03-development-log.md)、ネットワーク調査は [02](02-networking-investigation.md) を参照。

## 構成

| ターゲット | 役割 |
|---|---|
| `LimaKit` | `limactl` CLI のラッパー（UI 非依存）。`ProcessRunner`、`LimaClient`（list/watch/create/start/edit/disk/autostart、ログストリーム）、`InstanceConfig`（lima.yaml の差分を `--set` 式に変換）、`DownloadMonitor`、`SocketVMNetSetup` |
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
- **`limactl watch` は app の終了時に止める**（`ProcessRunner.terminateBackgroundProcesses`）。強制終了で残ったものは次回起動時に片付ける。
- **ネットワークは 3 系統。**
  1. HanaLima 仮想ネットワーク（NAT／ホストオンリー: サブネット指定、DHCP 予約。ブリッジ: 接続先インターフェースを指定）: root 不要。
  2. vzNAT: root 不要。サブネットは指定できない。
  3. socket_vmnet（`lima:shared/host/bridged`）: 従来方式。セットアップ画面で公式リリースを入れ、管理者認証は 1 回だけ。
- **HanaLima のブリッジは、VM の接続ごとに従来 API のインターフェース（`vmnet_start_interface` + `VMNET_BRIDGED_MODE`）を作る。** entitlement 付きの署名なら root なしで動く（macOS 27.0.1 で確認）。2 台同時、仮想ネットワークとの同時使用、再起動の順序も実機で確認済み（docs/02）。`vmnet_network` を使わないので、同時使用の確認ダイアログの対象外。
- **hanalima-netd の vmnet ネットワークは、最初の VM 接続時に作り、最後の VM が切断したら解放する。** 使い回すと、macOS の不具合で DHCP 予約が消え、ブリッジ番号も衝突する（下記）。
- **すべての終了経路でインターフェースを止めてから終了する。** 止めずに終了すると、vmnet がそのサブネットを再起動まで予約したままになる。シグナルハンドラは `@Sendable` にすること（main.swift のトップレベルに書いたクロージャは main actor 扱いになり、別スレッドで動くと SIGTRAP で落ちる）。
- **ヘルパーは上書きせず、バージョンごとに別名で置く（`bin/hanalima-netd-<hash>`、`bin/current`）。** launchd は登録時のプログラムの cdhash を記録していて、別のビルドで上書きすると次の起動が `spawn failed`（終了コード 78）になる。エージェントの登録し直しは、ヘルパーが動いていないときだけ行う（`upgradeIdleAgents`）。
- **netd どうしは、vmnet の操作（ネットワークの作成、インターフェースの開始）をファイルロック（`net/vmnet.lock`）で 1 つずつ行う。** ネットワークの作成とブリッジの開始が重なると、そのプロセスでは 1001 が続く（新しいプロセスにすると作成できた）。
- **DHCP 予約は、予約のある MAC からの DHCP 要求に限り、オプション 61 を除去して効かせる。** bootpd はクライアント識別子（Linux の DUID）があるとそれで識別するため、MAC による予約が一致しない。
- **socket_vmnet と HanaLima ネットワークの同時使用は、確認ダイアログを出したうえで許可する**（`NetworkConflict`）。netd はネットワークを使い回さないので、実機の 6 パターン（起動・再起動の順序、1 台の VM に両方の NIC）で問題は起きなかった。ほかのツールや古い netd が使い回すと macOS の不具合が起きうるので、警告は残している。

## v0.4 の機能と Lima 2.2.1 の実際の挙動

- **スナップショットは QEMU のみ、停止中だけ操作する。** VZ ドライバーは `unimplemented`。QEMU では、停止中は `qemu-img` の内部スナップショット（起動ディスクのみ）で、作成・適用・削除とも正しく動く。実行中は HMP `savevm` を使うが、9p の共有フォルダがあると QEMU が拒否し、**limactl は終了コード 0 を返す**（何も作られない）。さらに、`loadvm` に失敗すると VM が `restore-vm`（停止）のまま残る（QMP `cont` で再開できた）。そのため HanaLima は停止中だけ操作を許し、作成後は一覧にタグがあるかを確かめる。
- **スクリーンショットは、画面を有効にした VZ の VM だけ。** `limactl screenshot` は、ホストエージェントが表示している VM のウィンドウを `CGWindowListCreateImage` で撮る。QEMU は非対応、`video.display: none`（既定）では撮れない。ウィンドウを閉じると撮れなくなる。概要タブでは 3 秒ごとに更新する（表示中のみ）。
- **ログは差分だけ読む。** `ha.stderr.log`（logrus の JSON）と `serial*.log` を、前回の位置から追記分だけ読む（`LogFileFollower`）。Lima は起動のたびにファイルを作り直すので、i-node が変わるか小さくなったら最初から読み直す。シリアルの ANSI エスケープは除去する。
- **プロビジョニングは起動のたびに実行される**（cloud-init の `scripts_per_boot`）。冪等に書く必要があることを画面に明記している。スクリプト系（system/user/boot/dependency）と data は編集でき、`file` を使うものや yq・ansible は読み取り専用で保持する。
- **コードの編集は `CodeEditor`（NSTextView）で行う。** SwiftUI の TextEditor はシステム設定に従ってスマート引用符やダッシュに置き換えるため、スクリプトや YAML が壊れる。
- **メイン画面はメニューバーのアイコンから開く。** ウィンドウを閉じた状態で終了すると、ウィンドウの復元で「ウィンドウなし」が戻り、`.defaultLaunchBehavior(.presented)` や `.restorationBehavior(.disabled)` でも開かなかった。常に存在するメニューバーのラベルが、起動時にウィンドウがなければ `openWindow` で開き、`bootstrap()`（1 回だけ実行）も始める。

## macOS vmnet の既知の不具合（2026-10, macOS 27.0.1）

- アイドルになった `vmnet_network` は、ref を保持していても DHCP 予約とポート転送規則を失う（[フォーラム 847642](https://developer.apple.com/forums/thread/847642), FB24895271）。
- ブリッジ番号はネットワークの初回起動時に決まり、使い回すと衝突する（[apple/container#2051](https://github.com/apple/container/issues/2051)）。インターフェースを止めた `vmnet_network` を再利用すると、従来 API のブリッジの `bridge100` を奪い、`en0` を外し、**Mac 本体の IPv4 が消える**。Apple に **FB25122122** として報告済み。再現ツール: `Prototypes/vmnet-bridge100-repro`。回復は `sudo ipconfig set en0 DHCP` か再起動。
- 新規に作ったものどうしなら、従来のブリッジと共存できる（`bridge100` と `bridge101` に分かれる）。
- インターフェースを開始したままプロセスが終了すると、そのサブネットはしばらく（数時間か再起動まで）`vmnet_network_create` が 1001 になる。ほかにも、socket_vmnet の起動と重なったときなどに、1001 が 1 分以上続くことがある。netd は、VM が接続している間は 2 秒おきに作成を再試行し続ける（その間に VM が送るフレームは捨てる）。失敗しても netd 自体は終了しない。
- `vmnet_network_configuration_set_ipv4_subnet` に渡すのはゲートウェイ（.1）。ネットワークアドレス（.0）を渡すとインターフェースの開始に失敗する。
- entitlement なしの ad-hoc 署名では `vmnet_network_create` が 1002 で失敗する。従来の bridged モードも、この署名なら root なしで起動した（未調査）。
