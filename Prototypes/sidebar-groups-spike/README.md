# サイドバーのグループの試作（docs/12 の段階 1 の最初）

docs/12 の 4.1 と 4.2 で「試作で確かめる」とした、`List` の中の `DisclosureGroup` の選択・開閉・名前の編集・ドラッグを確かめる。macOS 27.0.1、Xcode 27、2026-11-08。

試作は 2 つある。既定は AppKit 版（`OutlineSidebar.swift`、サイドバー全体を 1 つの `NSOutlineView` で作る）。`SPIKE_IMPL=swiftui` で最初の SwiftUI 版（`List` と `DisclosureGroup`）になる。

```bash
swift run                                        # 手で触る（AppKit 版）
SPIKE_IMPL=swiftui swift run                     # SwiftUI 版
SPIKE_PROBE=<dir> SPIKE_PROBE_SET=B swift run    # AppKit 版のドロップの判定（偽のドラッグ情報で validateDrop・acceptDrop を呼ぶ）
SPIKE_PROBE=<dir> SPIKE_PROBE_SET=A swift run    # AppKit 版を合成イベントで操作（ドラッグは始まらない回がある）
SPIKE_PROBE=<dir> SPIKE_PROBE_SET=1 swift run    # 合成イベントで自動操作（1〜5）
```

切り替え: `SPIKE_DRAG=move`（VM の行の `draggable` と、行とラベルの `dropDestination` を外す）、`SPIKE_NOMOVE=1`（グループに入っていない VM の `ForEach` から `onMove` を外す）、`SPIKE_ROWMENU=1`（いまの `SidebarView` と同じく、VM の行ごとに `.contextMenu` を付ける）。

自動操作は、アプリが自分のウインドウに `NSApp.postEvent` でマウスとキーのイベントを送る。アクセシビリティの許可は要らない。手順ごとにモデルの状態、表の行数、最初のレスポンダーを標準出力に書き、画像を `<dir>/step-NN.png` に保存する。サイドバーは Liquid Glass のため画像では空白に写るので、判定は標準出力で行う。

## SwiftUI 版の結果

SwiftUI の `List` は `SwiftUIOutlineListView`（`NSOutlineView` の派生）で、セクションの見出しが level 0、グループが level 1、グループの中の VM が level 2、どのグループにも入っていない VM が level 1 の行になる。モデルから作った行の並びと、表の行数・順番は一致した。

| 確かめたこと | 結果 |
|---|---|
| グループの名前のクリック（ラベルに `.tag`） | グループを選ぶ |
| 開閉三角のクリック | 開閉だけ。選択は変わらない |
| グループの中の VM を選んだままグループを閉じる | モデルの選択は VM のまま残る（表の選択は -1）。開くと表の選択も戻る |
| ↓（グループを選んだ状態） | 最初の VM へ移る |
| ←・→（グループを選んだ状態） | 閉じる・開く |
| グループのダブルクリック | `contextMenu(forSelectionType:primaryAction:)` の `primaryAction` が呼ばれる。そこで編集を始めると `TextField` がフォーカスを取り、名前全体が選ばれる。入力して Return で確定する |
| ダブルクリックで、VM の行ごとに `.contextMenu` を付けた場合（`SPIKE_ROWMENU=1`） | グループでも VM でも `primaryAction` が呼ばれる。右クリックでどちらのメニューが出るかは、メニューが開くと操作が止まるので確かめていない |
| VM をグループの行へドロップ（開いた・閉じた・空のグループ） | そのグループの末尾に入る（ラベルの `dropDestination`） |
| VM を、別のグループの VM の行・グループに入っていない VM の行の中央へドロップ | その VM の前に入る（行の `dropDestination`）。グループの外への移動と、別のグループの途中への挿入はこれで行う |
| 同じグループの中で、行の境目へドラッグ | `onMove` で並べ替わる。行の `dropDestination` と両立する |
| グループの行を別のグループの上の境目へドラッグ | 外側の `ForEach` の `onMove` でグループが並べ替わる |
| `ForEach` の `dropDestination(for:action:)`（挿入位置を受け取る形） | **働かない**。`onMove` を外しても、グループの外からのドロップを受けなかった |

グループに入っていない VM の並びの末尾には、ドロップで置けない（最後の VM の行に落とすとその前に入る）。グループから外すだけならコンテキストメニューの「グループから外す」で足り、末尾へは境目へのドラッグ（`onMove`）で動かせる。

起動直後に一度、`WARNING: Application performed a reentrant operation in its NSTableView delegate.` が出た。SwiftUI の内部の警告で、動作には影響しなかった。

合成イベントでは、ドラッグ中の見た目（挿入位置の線、ドロップ先の強調）は確かめられない。手で触って確かめる。

## AppKit 版にした理由と結果

SwiftUI 版を手で触ると、同じグループの中の並べ替え（`onMove`）では挿入線が出るのに、別のグループやグループの外へのドラッグ（行の `dropDestination`）では線が出ず、VM の行に重ねると緑の十字（コピー）が出た（2026-11-08 ユーザーの確認）。挿入位置を受け取る `ForEach.dropDestination` は働かず、行の `dropDestination` はカーソルを選べないので、SwiftUI のままでは直せない。Finder やメールと同じく `NSOutlineView` を直接使うと、`validateDrop` で、ドロップの位置の付け替え（`setDropItem(_:dropChildIndex:)`）と、操作（`.move` は線か強調、`.copy` は緑の十字、空は不可）を決められる。

ドロップの規則と、セット B で確かめた判定:

| ドラッグ | ドロップ先 | 判定 | 結果 |
|---|---|---|---|
| VM | 行と行のあいだ（どの階層でも） | move（線） | その位置へ |
| VM | グループに入っていない VM の末尾、セクションのあいだ（いちばん下） | move（線。末尾へ付け替え） | 末尾へ |
| VM | グループの行の上 | move（グループの強調） | そのグループの末尾へ |
| VM | 自分のいるグループの行の上 | 不可 | 何も起きない |
| VM | グループの中の VM の行の上 | move（その VM の前の線へ付け替え） | その VM の前へ |
| VM | グループに入っていない VM の行の上 | copy（緑の十字） | 2 台で新しいグループを作り、名前の編集欄を開く |
| VM | グループとグループのあいだ | move（開いたグループのあとならその末尾、ほかはグループに入っていない VM の先頭へ付け替え） | その位置へ |
| VM | 自分の上、ストレージのセクション | 不可 | 何も起きない |
| グループ | グループとグループのあいだ | move（線） | 並べ替え |
| グループ | ほかのグループの行の上 | 不可（入れ子は作らない） | 何も起きない |
| グループ | グループに入っていない VM のあいだ | move（グループの末尾へ付け替え） | 最後のグループへ |

ほかに確かめたこと（セット A）: グループの名前のクリックで選択、開閉三角で開閉（選択は変わらない）、ダブルクリックで名前の編集欄が開く（`doubleAction` の中で編集を始めるとすぐ閉じるので、次のループで始める）、「＋」の「新規グループ」で「新規グループ」（重なれば番号付き）を作って編集欄を開き、入力して Return で確定。VM の行は `NSHostingView` で SwiftUI の行を載せている。

合成イベントでは `NSOutlineView` のドラッグが始まらない回がある（本物のマウスボタンの状態を見ているとみられる）。始まった回では、マウスの位置に応じて「グループの先頭へ挿入」と「グループの上」の判定が切り替わり、規則どおりの付け替えになった。線・強調・カーソルの見た目と、サイドバーの Liquid Glass の見た目は手で確かめる。

右クリック（セット M）: `NSHostingView` で載せた行に SwiftUI の `.contextMenu` を付けると、右クリックでそのメニューが開いた（`NSOutlineView` の `menu` より先に働く）。AppKit のセルの行（グループ）では `NSOutlineView` の `menu` が開く。HanaLima の VM のメニュー（`InstanceActionsMenu`、ツールバーと共有）は、そのまま行に載せて使える。ただし、右クリックした行を囲む線（`clickedRow` の表示）は出ない。
