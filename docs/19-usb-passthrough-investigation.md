# 19. Mac に挿した USB 機器を VM に渡せるか（2026-11-25 調査）

Mac に挿した USB メモリを、ファイルの共有ではなく**機器として** VM に渡せるかを調べた。ゲストの xHCI のバスに機器が現れ、ゲストのドライバーが `/dev/sdX` を作る形である。macOS 27.2.1、Xcode 27 の SDK、Lima 2.3.0、ゲストは Ubuntu 26.04（kernel 7.0）で確かめた。試作はブランチ `spike/usb-passthrough`（`Driver/` の `USBPassthrough.swift` と hosted モードの `--usb-passthrough`、`Prototypes/usb-passthrough-spike/`）にある。

## 結論

- **できる。** macOS 27 の Virtualization.framework に `VZUSBPassthroughDevice` が入り、Mac に挿さった USB 機器を VM が占有して使える。機器は同じく macOS 27 の AccessoryAccess（`AAUSBAccessoryManager`、`AAUSBAccessory`）で受け取る。
- **対象は HanaLima のドライバーの VM だけ。** VM を自分のプロセスで動かしているのが HanaLima のドライバーだけだからである。Lima の vz と QEMU の VM には付けられない。
- **どの機器を渡すかは、利用者がメニューバーで決める。** 機器ごとに「仮想マシンアクセサリ」のメニューで「“＜アプリ＞” で使用」か「“このMac” で使用」を選ぶ。アプリから割り当てる API は無い。
- **entitlement `com.apple.developer.accessory-access.usb` が要り、プロビジョニングプロファイルを埋め込んだアプリのバンドルでしか使えない。** ad hoc の署名と、バンドルの中に置いた素の実行ファイルでは、起動の時点で終了させられる。今の `Contents/Helpers/lima-driver-hanalima` のままでは使えない。
- **Lima が起動した、画面のないドライバーでも動いた。** ドライバーの実行ファイルを、プロファイルを持つバンドルの主実行ファイルにすれば、`limactl start` から起動しても機器を受け取って VM に付けられる。シンボリックリンク経由で起動しても同じだった。

## 仕組み

### API

- `VZUSBPassthroughDeviceConfiguration(device: AAUSBAccessory)` から `VZUSBPassthroughDevice` を作り、`VZUSBController.attach(device:)` で起動中の VM に付ける。`detach` で外す。どちらも VM のキューで呼ぶ。VM の構成には、起動の時点から `VZXHCIControllerConfiguration` が要る。
- 機器が抜かれると、`VZUSBController.Delegate` の `usbPassthroughDeviceDidDisconnect` が届き、VZ が自分で外す（macOS 27）。
- `AAUSBAccessoryManager.shared.registerListener(_:matchingCriteria:)` で、このアプリに割り当てられた機器の知らせ（`usbAccessoryDidConnect`／`usbAccessoryDidDisconnect`）を受ける。登録した時点で割り当て済みの機器は、完了の引数にも並ぶ。条件を空の配列にするとすべての機器が対象になる。条件を書いた絞り込みは、ほとんどの形で効かないと報告されている（FB24018643）。
- `AAUSBAccessory` は NSSecureCoding に対応していて、XPC の表現（`createXPCRepresentation`）も作れる。

### 割り当て

機器を挿すと、メニューバーの「仮想マシンアクセサリ」に Mac の USB 機器が並ぶ。機器ごとに、受け取りを登録しているアプリと「このMac」から選べる。macOS は機器ごとに割り当て先を覚えている。割り当て先のアプリのプロセスが起動して受け取りを登録すると、その機器が届く。

割り当て先の名前は、VM の起動のしかたで変わる。HanaLima のアプリから起動した VM では「HanaLima で使用」と出た。ターミナルや launchd（ログイン時の自動起動の代わり）から起動した VM では「不明なアプリケーション」だった。ドライバーを入れ子のバンドル（名前「HanaLima Driver」）にしても変わらなかった。macOS はドライバーの起動元のプロセスを責任元にしていて、アプリから起動すれば HanaLima、そうでなければアプリのバンドルではない `limactl` になるためだと考えている。

Mac でマウントされている機器を割り当てると、責任元に「リムーバブルボリューム上のファイル」へのアクセスの許可が求められた（アプリから起動したときは「“HanaLima” から…」、launchd から起動したときは「“limactl” から…」）。許可するまで、機器はゲストの USB には出るが `/dev/sda` にならなかった。私の作業環境から起動したときは出なかった（責任元がすでに許可を持っていたため）。許可はシステム設定の「プライバシーとセキュリティ」→「ファイルとフォルダ」で取り消せる。

### entitlement とプロファイル

- 開発者のサイトでは「Claim USB Accessory」という capability で、App ID ごとに有効にする。Apple への申請は要らない（Xcode のポータルの定義でも `distributionApprovalRequired: false`）。配布の種類には Developer ID も含まれる。
- 2026-11-25 に App ID `FJYY683YHH.org.izawa.HanaLima` を作ってこの capability を有効にし、Developer ID のプロビジョニングプロファイル（期限 2044-11-20、Mac の限定なし）を作った。プロファイルはリポジトリの外の `~/Library/Developer/HanaLima/` に置いている。
- 署名には次の entitlement を並べる。前の 2 つはプロファイルと照合される。
  - `com.apple.application-identifier` = `FJYY683YHH.org.izawa.HanaLima`
  - `com.apple.developer.team-identifier` = `FJYY683YHH`
  - `com.apple.developer.accessory-access.usb`
  - `com.apple.security.virtualization`

## 実験

試作は、ドライバーの実行ファイルを、バンドル ID `org.izawa.HanaLima` のアプリのバンドル（`build/usb-spike/HanaLima USB Spike.app`）の主実行ファイルにしたものである。プロファイルを `Contents/embedded.provisionprofile` に置き、Developer ID で署名した（`Prototypes/usb-passthrough-spike/make-bundle.sh`）。ドライバーは、hosted モードの `--usb-passthrough` か、Lima のもとで VM のフォルダに目印のファイル `hanalima-usb-passthrough` があるときに、xHCI のコントローラーを付け、割り当てられた機器をすべて VM に付ける。ゲストは Ubuntu LTS（`hanalima-e2e-usb`、HanaLima のドライバー、シリアルに自動ログイン）。機器は 32 GB の USB メモリ（`8564:1000`）で、利用者の写真が入っていたので、ゲストからは読み取り専用のマウントと読み込みだけを行った。

| 実験 | 結果 |
|---|---|
| 段階 0: 試作のアプリ自身が VM を動かす（hosted モード、画面あり） | 受け取りの登録に成功し、メニューでの割り当てのあと機器が届いて VM に付いた。ゲストの `lsusb` に SuperSpeed の機器として出て、usb-storage が `/dev/sda` を作った。読み取り専用でマウントでき、生のデバイスの読み込みは 104 MB/s |
| 段階 0: 「このMac」に戻す | VZ の delegate と AccessoryAccess の切断の知らせが同時に届き、ゲストの `/dev/sda` が消え、Mac で自動的にマウントし直された |
| 「このMac」に戻すときの Mac 側の流れ（`log stream` で `diskarbitrationd` を見た） | 0.35 秒ほどのうちに、ディスク全体とパーティションが新しく作られ（`created disk` が 2 回）、FSKit で調べ直されて自動でマウントされた。挿したときと同じ流れ。機器が届くたびに IORegistry の ID が変わるので、USB の機器としても認識し直している（電気的な抜き差しは無い） |
| 利用者の Alpine の VM（guest1、kernel 6.18.22-0-virt、HanaLima のドライバー）で受け取る | linux-virt にも xHCI が組み込まれていて、割り当てると SuperSpeed の機器として認識し、usb-storage と uas が読み込まれて `sda`・`sda1` ができた |
| 割り当てを「HanaLima で使用」のまま、受け取り先の ubuntu2604-test を止め、受け取り先を guest1（休止中）に替えて再開 | guest1 は再開の 3 秒後に受け取りを始め、その 1 秒後に機器が自動で付いた。どの VM のドライバーもシステムからは同じ「HanaLima」なので、割り当ては VM を替えても引き継がれる。「このMac」に戻してあれば、受け取り先を起動しても付かない（割り当て直す） |
| 「HanaLima で使用」にするときの Mac 側の流れ（同じく `diskarbitrationd`） | 2 つのボリュームのアンマウント、ディスクの取り出し（eject）、ディスク全体とパーティションの削除（`removed disk` が 2 回）の順。Finder で取り出すときと同じ流れで、そのあと機器が VM に渡る |
| E0: バンドルの `Contents/Helpers` に置いた素の実行ファイルに同じ entitlement を付ける | 起動の時点で終了させられた（SIGKILL、終了コード 137）。主実行ファイルのほうは起動した |
| E1: `LIMA_DRIVERS_PATH` を試作のバンドルの `Contents/MacOS` に向けて `limactl start`。画面なし（`video.display: none`） | 受け取りの登録に成功し、割り当てた機器が届いて VM に付き、ゲストで読めた |
| E1: ドライバーへのシンボリックリンクだけを置いたフォルダを `LIMA_DRIVERS_PATH` にする | 同じく成功した。`Bundle.main` は空だったが、entitlement はリンク先の実体で効いた |
| ドライバーが落ちたあと、VM を起動し直す | 割り当ては保たれ、受け取りを登録した直後に機器が届いた（機器はつなぎ直されて registry ID が変わった） |
| VM を止める | 機器は自動で Mac に戻り、マウントされた。止める途中で機器がもう一度届き、`attach` は VZErrorDomain 3（VM の状態が付けられない）で失敗した |
| 機器を付けたまま休止する | 休止できた（保存の途中で機器は外れ、Mac に戻った）。再開の経路では、試作が受け取りを登録し直していないので付かなかった |
| 製品と同じ置き方（`HanaLima.app/Contents/Helpers/HanaLimaDriver.app`、`org.izawa.HanaLima.driver`、ドライバー用のプロファイル）で、受け取り先の VM を launchd の仕事から起動し、受け取り先でない VM（目印なし、Alpine）も同時に動かす | 受け取り先の VM だけが機器を受け取り、ゲストで読めた。もう 1 台のドライバーには何も届かなかった。メニューの名前は「不明なアプリケーション」のまま。上の許可のダイアログが出て、許可したあとに `/dev/sda` ができた。「このMac」に戻すと Mac でマウントし直された |
| `AAUSBAccessory` をバイト列にする | `NSKeyedArchiver` で 282 バイトになり、復元すると同じ registry ID を指した。ただし、AccessoryAccess の知らせの中で復元すると、同じキューへの `dispatch_sync` で SIGTRAP になる |

## 設計（2026-11-25、Codex との対照設計）

実験の結果と制約を Codex に渡し、Claude の案は見せずに独立に設計させた。両案を突き合わせて、次のように決めた。比べた点は節の最後にまとめる。

### ドライバーの置き方と署名

- ドライバーを、アプリの中の入れ子のバンドル `HanaLima.app/Contents/Helpers/HanaLimaDriver.app` の主実行ファイル（`lima-driver-hanalima`）にする。バンドル ID は `org.izawa.HanaLima.driver` で、App ID とプロファイルを本体とは別に持つ。今の素の実行ファイルにはこの entitlement を付けられない（実験の E0）。アプリの `LIMA_DRIVERS_PATH` と hosted モードの起動は、入れ子のバンドルの `Contents/MacOS` を指す。
- 署名は、入れ子のバンドルを先に、外側のアプリを最後に行う。ドライバーの entitlement は、`com.apple.application-identifier`（`FJYY683YHH.org.izawa.HanaLima.driver`）、`com.apple.developer.team-identifier`、`com.apple.developer.accessory-access.usb`、`com.apple.security.virtualization` の 4 つ。外側のアプリは今の entitlement のまま。
- プロファイルはリポジトリの外に置き、`build-app.sh` に環境変数（`HANALIMA_DRIVER_PROFILE`）で渡して `HanaLimaDriver.app/Contents/embedded.provisionprofile` に写す。`release.sh` は、プロファイルが無い・期限切れ・App ID が合わないときに止まり、入れ子の署名と entitlement を確かめてから公証に進む。
- ad hoc の開発ビルドでは、ドライバーを virtualization だけで署名し、USB の機能は出さない。試すときは Developer ID とプロファイルで署名する。
- ターミナルの `limactl` 用に `DriverInstaller` が `<prefix>/lib/lima/` に置くものは、コピーではなく、アプリの中のドライバーへの絶対パスのシンボリックリンクにする。素のコピーは起動の時点で終了させられ、リンクなら動いた（実験の E1）。置き換えは、横に作ったリンクを rename で入れ替える。

### 受け取る VM

- HanaLima のドライバーの VM から、**受け取り先を 1 台だけ選ぶ**（「なし」か 1 台）。メニューバーで HanaLima に割り当てた機器は、すべてその VM に付く。システムが「機器ごとにアプリを選ぶ」形なので、HanaLima は「アプリから先の VM を 1 台選ぶ」だけにする。
- 選んだ VM は `~/Library/Application Support/HanaLima/` の小さな JSON に、VM のフォルダと `vz-identifier` で記録する。lima.yaml には書かない。`limactl clone` の複製や、同じ名前で作り直した VM は、識別子が違うので引き継がない。改名したら選び直す。
- ドライバーは起動のときにこの記録を読み、自分の VM と一致したときだけ受け取りを登録する。ほかの VM は今までどおり起動する。読むのは起動のときだけなので、選び直しはその VM の次の起動から効く。今の受け取り先が動いている間は、画面で選び直しを断る。
- 記録の読み書きは LimaKit に置き、アプリとドライバーで共有する。ドライバーはアプリが動いていなくても読むので、ログイン時の自動起動でも働く。

### VM の構成と流れ

- macOS 27 では、HanaLima のドライバーの VM すべてに xHCI のコントローラーを付ける。受け取り先かどうかは、受け取りの登録だけに効かせる。こうすると、選び直しで VZ の構成が変わらない。
- 休止の記録（`hanalima-state.json`）に xHCI の有無を書く。項目の無い古い記録は「無し」として、その構成で戻す。xHCI を付ける前に休止した VM も再開できるようにするためである。
- 受け取りは、VM を起動したあとと、休止から戻して再開したあとに登録する。どちらも `DriverCore.start()` の同じ場所で行う。条件は空の配列（すべての機器）。登録の時点で割り当て済みの機器と、後から届いた機器を、同じ処理で VM のキューに渡す。機器は registry ID で覚え、付けている途中のものも数える。
- 「このMac」に戻されたときや抜かれたときは、AccessoryAccess の切断と VZ の delegate の両方が届く。どちらが先でも同じ結果になるように片付ける。
- 一時停止の間は登録を保つ。止まっている間に届いた機器は、再開してから付ける。
- 停止・強制停止・休止を始めたら、新しく付けるのをやめる（実験では、止める途中に届いた機器を付けようとして VZErrorDomain 3 になった）。休止の保存に失敗して VM が動き続けるときは、受け取りを戻す。ドライバーが終われば、macOS が機器を Mac に戻す。
- 失敗しても VM は動き続ける。理由はドライバーのログと、制御ソケットの `status` に返す。`status` には、受け取り先かどうか、付いている機器の数、最後のエラーを足す。
- 試作のバイト列化の確かめは消す。

### 画面

- 受け取り先を選ぶ欄を 1 つ置く（「なし」と、HanaLima のドライバーの VM）。macOS 27 未満と、USB の entitlement の無いビルド（ad hoc）では出さない。
- 欄の横に、次の旨の説明を置く。「選んだ VM が動いている間に、メニューバーの仮想マシンアクセサリで機器を選ぶ。渡している間は Mac から使えない。Mac に戻す前に、ゲストでアンマウントする」。メニューに出る名前は「不明なアプリケーション」なので、説明にもそう書く。最初の割り当てで、Mac のリムーバブルボリュームへのアクセスの許可を求められることも書く。
- macOS 26 では AccessoryAccess を弱くリンクし、記録があっても無視して今までどおり起動する。

### 最初の一歩

画面を作る前に、製品と同じ置き方で試作を通す。2026-11-25 に、App ID `org.izawa.HanaLima.driver` に「Claim USB Accessory」を有効にして Developer ID のプロファイルを作り、`build/usb-spike/HanaLima.app` の入れ子のバンドルで確かめた（実験の表）。利用者の環境を変えないように、`/Applications` の HanaLima と `<prefix>/lib/lima/` のドライバーには触れず、`LIMA_DRIVERS_PATH` で試作を指した。ログイン時の自動起動は、`AbandonProcessGroup` を付けた launchd の仕事からの `limactl start` で代えた（付けずに仕事を外すと、配下の hostagent まで終わって VM が止まった）。

確かめていないこと: `/Applications` に入れた製品のビルドでの動き（公証を含む）、本物のログイン時の自動起動、HanaLima のアプリから起動した VM の責任元と許可のダイアログの名前、一時停止中の扱い。実装のあとに確かめる。

### 実装と確認（2026-11-25）

設計のとおりに実装した。主な場所は、受け取り先の記録とドライバーの entitlement の判定が `USBTarget`（LimaKit）、受け取りが `USBPassthrough`（ドライバー）、リンクを置くのが `DriverInstaller`、画面が概要タブの「USB 機器」の欄（`AppModel+USB`）である。署名は `build-app.sh`・`make-app.sh`・`release.sh`。試作の目印のファイルと hosted モードの `--usb-passthrough` は外した。

Codex のレビューを受けて、次を直した。受け取り先が動いている間はその VM 自身も切り替えられないようにした（外せてしまうと、ドライバーは受け取りを続けたまま別の VM を受け取り先にできた）。停止・休止の失敗に備えて、受け取りを「閉じる」のではなく「止めておく」形にした。一時停止からの再開のあとに付ける処理を、ドライバーの actor の中に移した。起動の途中で停止が始まったら受け取りを始めないようにした。`release.sh` で、プロファイルが USB の entitlement を許しているかも確かめるようにした。別の Lima のホームで動く受け取り先の扱いは、HanaLima が Lima のホームを 1 つしか扱わないので採らなかった。

Developer ID で署名した `build/HanaLima.app` のドライバーで、次を確かめた。

| 確かめたこと | 結果 |
|---|---|
| ad hoc のビルド | ドライバーに USB の entitlement が付かず、画面に欄が出ない |
| 受け取り先の VM と、そうでない VM を同時に起動 | 受け取り先のドライバーだけが受け取りを始め、`status` が `usbTarget: true`。もう 1 台は `false` で何も届かない |
| 割り当てた USB メモリ | 受け取り先の VM に付き、ゲストで読み取り専用でマウントして読めた。割り当ては覚えられていて、次の起動でも自動で付いた |
| 機器を付けたまま一時停止して再開 | 一時停止の間も 1 台と数え、再開のあとゲストから読めた（77 MB/s） |
| 「このMac」に戻す | ドライバーが外れたことを記録し（0 台）、ゲストから消え、Mac でマウントし直された |
| 機器を付けたまま VM を止める | 止める途中のエラーは出ず、機器は Mac に戻った |
| 休止して再開 | 休止の記録に `xhci=true` が入り、再開のあとで受け取りを始め直した |
| 0.18.0 のドライバーで休止し、新しいドライバーで再開 | xHCI なしの構成のまま再開できた（次の通常の起動から xHCI が付く） |
| 画面 | 概要タブに「USB 機器」の欄と「受け取り中の機器: 0 台」が出た（Debug ビルドの画面の書き出し） |
| 製品のビルド（`make-app.sh --install`、Developer ID とプロファイル、公証なし）を `/Applications` に入れ、利用者がアプリから `ubuntu2604-test`（Ubuntu 26.04）を起動 | 起動時にターミナル用のドライバーがリンクに置き換わった。メニューは「HanaLima で使用」、許可のダイアログは「“HanaLima” から…」。ゲストに `sda`（vfat）が出た |

確かめていないこと: 公証、本物のログイン時の自動起動、アプリから起動した VM と自動起動した VM のあいだで割り当てが引き継がれるか（メニューに出る名前が「HanaLima」と「不明なアプリケーション」で分かれるので、別のアプリとして扱われ、割り当て直しが要るかもしれない。アプリから起動した VM どうしでは引き継がれた）、英語の macOS でのメニューの文言（英語の説明文は推測で書いた）。本体用に最初に作ったプロファイル（App ID `org.izawa.HanaLima`）は、ドライバーを別の App ID にしたので使っていない。

### 比べた点

| 論点 | Claude の案 | Codex の案 | 決めたこと |
|---|---|---|---|
| ドライバーの置き方 | 入れ子のバンドル、別の App ID | 同じ | 同じ |
| 案 A（アプリが受け取ってドライバーへ渡す） | 採らない。自動起動のときにアプリがいない。entitlement の無いプロセスが付けられるかも分からない | 採らない（受け取ったプロセスがそのまま使う） | 採らない |
| 振り分け | VM ごとに機器（vendor・product・シリアル番号）を lima.yaml の `vmOpts.hanalima.usb` に書く | 受け取り先の VM を 1 台選ぶ | **Codex の案。** lima.yaml に書くと複製が同じ機器を取り合い、どの VM も受け取らない機器が宙に浮く。機器ごとの振り分けは今は要らない |
| 選んだ VM の記録の場所 | — | `~/.hanalima/usb-target.json` | `~/Library/Application Support/HanaLima/`。`~/.hanalima/` は MCP の場所なので |
| 選び直しと起動の競合 | — | ファイルロックで、受け取り先が動いている間の書き換えを止める | 採らない。画面で断れば足りる。ターミナルから同時に起動したときの競合は残るが、先に付けたほうが取るだけである |
| 休止と xHCI | 見落としていた | xHCI の有無を休止の記録に書き、戻すときはその構成にする。xHCI は受け取り先の VM だけに付ける | 記録に書くのは Codex の案。xHCI はすべての VM に付け、選び直しで構成が変わらないようにする |
| 一時停止、`status` の拡張、説明文、最初の一歩 | 一部だけ | 具体的に書いていた | Codex の案 |
