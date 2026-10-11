# 開発ログ（2026-10-09）

HanaLima の最初の 1 日の経緯を時系列でまとめる。決定事項、実験、その結果を記録する。設計の要点は [04](04-design.md)、ネットワーク調査の詳細は [02](02-networking-investigation.md) を参照。

## 1. 調査と方針決定
- Lima 用の既存 GUI を調べた（lima-gui［Qt］、Limac［メニューバー］、xbar プラグイン、Podman Desktop 拡張）。VM の作成、リソース割り当て、仮想ネットワーク構築まで GUI でできるものは無かった → [01](01-research-and-architecture.md)。
- アーキテクチャは「SwiftUI ネイティブアプリ＋`limactl` CLI ラッパー」に決めた（Lima の Go コードはリンクしない）。
- 工数は、フルタイム 1 人で 3.5〜5 か月と見積もった（配布を除く）。
- ユーザーの決定: **macOS 26 以上のみ対応**。Lima 2.2.1 は Homebrew で導入。

## 2. MVP（`27ad64d`）
- LimaKit（ProcessRunner／LimaClient／各モデル）と SwiftUI アプリ（サイドバー、概要・コンソール・設定・ログの各タブ、作成シート）を作った。
- Lima v2.2.1 のソースから、`list --format json`（NDJSON）と `watch --json` のイベント形式を確認した。
- 実験と対処:
  - SwiftTerm 1.12 以降は Metal シェーダが必要で、最初は 1.11.2 に固定した。ユーザーが Metal Toolchain を入れたあと、1.20.x に上げた（1.99 は 2.0 のプレビュー版なので避けた）。
  - `--tty=false` ではイメージのダウンロード進捗が一切出ず、止まったように見えた（ユーザーがテストを中断した）。→ `DownloadMonitor` が Lima のキャッシュにある `data.tmp.*` のサイズと Content-Length から進捗を推定する。
  - テストを強制終了すると `limactl watch` が残った。→ アプリ終了時に止め、起動時に孤児プロセスを片付ける。
  - `sh` の孫プロセスがパイプを掴んだままだと、ストリームが終わらなかった。→ プロセス終了後のパイプ読み取り待ちを最大 1 秒にした。
  - 画面収録の権限が無い。→ Debug 用のスナップショット機能（アプリ内で描画して PNG に保存）を作った。
- アプリ名を LimaGUI から **HanaLima** に変更し、バンドル ID を `org.izawa.HanaLima` にした。フォルダ名もユーザーが変更した。

## 3. 設定編集とディスク（`5a11fb7`）
- `InstanceConfig`: 生の lima.yaml を Yams で読み、`limactl edit --set` 用の差分式を作る。実効設定をそのまま書き戻すと `~` が絶対パスになり、既定値も埋め込まれてしまうため、この方式にした。
- YAML 全体の保存: `limactl edit` はターミナル以外から全文を受け取る方法がないので、`VISUAL` をコピー用スクリプトにした。不正な YAML は拒否され、元のファイルはそのまま残る。
- `limactl edit` の失敗時に `lima.REJECTED.yaml` がカレントディレクトリに出るので、子プロセスは専用の一時ディレクトリで実行する。
- `limactl disk` の作成、サイズ変更、削除、接続を実装した。VZ では Lima が qcow2 を raw に自動変換する。

## 4. コンソールの接続待ち（`04a3325`）
- ユーザーから報告: 起動直後のコンソールで `Connection refused`、続いて `Connection reset by peer` が出た。
- 原因: `limactl list` は VM が起動した時点で Running を返すが、SSH が使えるのは約 1 分後。
- 対処: `watch` の `running` イベント（ホストエージェントが全要件を満たしたあとに送られる）を準備完了の合図にした。すぐ失敗した場合は自動で再試行する。SwiftTerm が返す終了コードは waitpid の生の値（65280 → 255）なので、変換して表示する。

## 5. ネットワーク調査（`3d8227b`）
- 試作: macOS 26 の `vmnet_network_create` と `vmnet_interface_start_with_network` は、`com.apple.security.virtualization` 付きの ad-hoc 署名であれば root なしで動く。
- Lima の VZ と QEMU は `networks: - socket:` で QEMU stream 形式のソケットに接続する。これを vmnet に中継すると、改造していない Lima でも DHCP、ホストとの通信、NAT、VM 同士の通信ができた。

## 6. 仮想ネットワーク（`020f3c2`）
- `hanalima-netd` と LaunchAgent（ソケットアクティベーション。`launch_activate_socket` は dlsym 経由で呼ぶ）を作った。アプリを閉じても、CLI から起動した VM でもネットワークが使える。
- 仮想ネットワークエディタ、VM の NIC 選択、作成時の NIC 選択を作った。
- ユーザーの確認: Mac から VM の lima0 へ ping が通った。

## 7. ブリッジと固定 IP（`a0fd62a` 〜 `f1d252d`）
- socket_vmnet のセットアップ画面: 公式リリースを取得し、SHA-256 を検証する。管理者認証は osascript で 1 回だけ。`limactl sudoers` の出力は visudo で検査してから配置する。
  - バグ: sudoers を 0440（root:wheel）で置いたため、admin だが wheel ではないユーザーには `--check` が読めなかった。→ 0444 にした。
- DHCP 予約: vmnet の予約が効かなかった。bootpd は DUID ベースのクライアント識別子でクライアントを識別するためで、ゲストの dhcpcd を `clientid` にすると .50 が割り当てられることを確認した。→ netd が、予約のある MAC からの要求に限りオプション 61 を除去する（`DHCPClientIDFilter`）。
- ユーザーが固定 IP 192.168.200.10 への ping を確認した。
- 2 回目の起動で予約が効かず .5 になった。→ 原因はフォーラム 847642 の不具合（アイドルになったネットワークは予約を失う）。→ netd を「最初の接続時に作成し、最後の切断で解放する」方式にした（`f00392c`、`355ed29`）。E2E で 2 回目も .50 になることを確認した。
- ブリッジ: 最初は `vmenet0` が DOWN のままで DHCP が届かなかった（tcpdump にも何も出なかった）。Mac を再起動すると、LAN の DHCP から 192.168.100.13 が取れた。
- **衝突の発見:** HanaLima のネットワークとブリッジを同時に使うと、`bridge100` の取り合いが起きた。片方が壊れ、Mac 本体の IPv4 も消えた（再起動で回復）。→ 同時使用を拒否する `NetworkConflict` を入れた（`355ed29`）。ユーザーが起動拒否の表示を確認した。
- サブネット作成の一時的な 1001 に対し、再試行を 60 秒にした（`f1d252d`）。

## 8. Apple への報告（`3f3c0ab` 〜 `b38d65f`）
- Lima を使わない再現ツール（`Prototypes/vmnet-bridge100-repro`）を作った。ユーザーの端末で手順を実行した。
  - 新規に作ったものどうしは、どちらの順でも共存した（`bridge100` と `bridge101`）。
  - **インターフェースを止めた vmnet_network を再利用したとき**だけ、`bridge100` を奪い、`en0` を外し、IPv4 が消えた。`sudo ipconfig set en0 DHCP` で回復した。
- その場で sysdiagnose を取得した。ユーザーが Apple Developer に無料登録し、Feedback Assistant（Developer Technologies & SDKs → macOS → Virtualization Framework）から **FB25122122** を送信した。
- 反省: Claude が確認なしに en0 のブリッジ実験を走らせてしまった（影響は無かった）。また、テストで SIGINT による即時終了を使ったため、サブネットを使えなくしてしまった。→ en0 に関わる実験は事前に確認すること、vmnet の実験は使い捨てのサブネットで行い正しく終了させることを決めた。

## 9. netd の終了処理（`e105f0c`）
- 判明: netd のシグナルハンドラが main actor 扱いになり、SIGTERM のたびに SIGTRAP で落ちていた。インターフェースを止めずに終了するため、サブネットが再起動まで使えなくなっていた（今日あちこちのサブネットが使えなくなったのは、主にこれが原因）。
- 対処: ハンドラを `@Sendable` にし、`Terminator.shutdownAndExit` ですべてのインターフェースを止め、ネットワークを解放してから終了する。インターフェースの停止は 1 回だけ実行する。E2E の `DaemonTerminationTests` を追加した。

## 10. 同時使用禁止の見直し（`feature/relax-network-conflict`）
- ユーザーの承認を得て、実機の VM で 6 パターン（起動・再起動の順序の組み合わせ、1 台の VM に両方の NIC）を検証した。すべて正常で、ホストの IPv4 も維持された（詳細は [02](02-networking-investigation.md) の末尾）。
- 起動の拒否を、確認ダイアログ（「このまま起動」/「キャンセル」）に変えた。設定画面の赤い警告も、オレンジの注意表示に変えた。
- バグ: 確認ダイアログが表示されなかった。同じビューに `.alert` を 2 つ付けると、片方しか効かないため。→ 内側のビューに移した。
- バグ（Claude の操作ミス）: デバッグ用の起動フックがネットワーク定義の読み込みより前に動いたため、確認なしで `hanalima-dev` を起動してしまった。→ フックを読み込みの後に移した。
- 判明: その起動では、socket_vmnet の起動と重なった demo のネットワーク作成が 1001 で 60 秒以上失敗した。netd は 60 秒で諦め、しかも `fail()` でプロセスごと終了していた。→ 作成の失敗ではプロセスを終了せず、VM が接続している間は再試行し続けるように変えた（別プロセスにサブネットを握らせた状態で、解放後 2 秒以内に接続できることを確認）。
- 判明: テストで使えなくなっていた 192.168.240.0/24 が、数時間後には再起動なしで使えるようになっていた。

## 11. メニューバーと自動起動（2026-10-09）
- メニューバー（`MenuBarExtra`）、設定画面、VM ごとのログイン時の自動起動（`limactl autostart`）を追加した。Lima 2.2.1 の自動起動は `~/Library/LaunchAgents/io.lima-vm.autostart.<名前>.plist` の有無で判定され、登録した VM の起動・停止は Lima が launchd 経由で行う。`--keep-alive` は無く、`--condition=boot` は sudo が必要なので扱わない。

## 12. root 不要のブリッジ（2026-10-09）
- 従来 API のブリッジが、entitlement 付きの署名なら root なしで動くことを実機で確かめ、netd の「ブリッジ」ネットワークとして組み込んだ（詳細は [02](02-networking-investigation.md)）。
- アプリでの確認中に 2 つの問題を見つけて直した: ネットワーク作成とブリッジ開始の競合で 1001 が続く件（ファイルロックで直列化）、ヘルパーの上書きで LaunchAgent が起動できなくなる件（バージョンごとに別名で配置）。

## 13. 公開（2026-10-10）
- MIT License で https://github.com/izawa/HanaLima として公開した。公開用の履歴は 1 件のコミットから始めた。
- `gh-pages` ブランチにティザーサイト（https://izawa.github.io/HanaLima/）を作った。
- ユーザーの方針で、他社の製品名は使わず、「GUI でかんたんに」のように実現していることで表現する。

## 14. v0.4（2026-10-10）
- スナップショット（QEMU、停止中のみ）、画面のサムネイル（VZ、画面ありのみ）、ログビューア（ホストエージェント、シリアル）、プロビジョニングの編集を追加した。Lima 2.2.1 の実際の挙動と、それに合わせた判断は [04](04-design.md) の「v0.4 の機能」。
- 判明した不具合: ウィンドウを閉じたまま終了すると、次の起動でメイン画面が開かず、メニューバーも「確認しています…」のままだった（ウィンドウの復元が原因）。メニューバーのアイコンから開くように直した。

## 15. ディスクを外付けに置く調査（2026-10-11）
- 一時的な VM の大きなファイルを外付けドライブに置けるかを調べた。VM のフォルダごとシンボリックリンクにすると `limactl list` に出なくなるので使えない。ディスクのファイル `disk` だけをリンクにすれば、VZ・QEMU とも動く（移すときは `rsync --sparse`）。詳細は [05](05-external-disk-investigation.md)。HanaLima の機能にするかは未定。

## 16. Wi-Fi のブリッジ（2026-10-11）
- 有線 en0 をつないだまま、Wi-Fi（en1）にブリッジする E2E を実行した。VM は LAN の DHCP からアドレスを取得し、ルーターへの ping も通った（3〜13 ms。電波を経由している）。ブリッジの E2E に、ルーターへの ping を足した。詳細は [02](02-networking-investigation.md)。

## 17. socket_vmnet のセットアップ画面をやめた（2026-10-12）
- 「socket_vmnet ならできて、HanaLima のネットワークではできないこと」を洗い出した。機能面ではなく、残るのは Lima 標準との互換（HanaLima なしでも動く `lima.yaml`、Lima の手順との一致）だけだった。導入（root、sudoers）は Lima の手順に任せ、セットアップ画面を削除した。既存の `lima:*` NIC は引き続き表示・起動・編集でき、未導入のときは追加の選択肢に出さない。

## 現在の状態（`e105f0c` 時点）
- テスト: 単体 66 件。E2E は 7 スイート（`HANALIMA_E2E=1`）。
- 試験用の資源: VM `hanalima-dev`（Alpine。NIC は `demo` のみ、固定 IP 192.168.200.10）、仮想ネットワーク `demo`（192.168.200.0/24）、追加ディスク `hanalima-demo`、socket_vmnet 1.2.2 インストール済み。
- 再起動まで使えないサブネット: 192.168.240.0/24、192.168.241.0/24、10.250.252.0/24（テストの途中で使えなくなったもの）。
