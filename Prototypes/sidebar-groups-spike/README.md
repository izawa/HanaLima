# サイドバーのグループの試作（docs/12 の段階 1 の最初）

docs/12 の 4.1 と 4.2 で「試作で確かめる」とした、`List` の中の `DisclosureGroup` の選択・開閉・名前の編集・ドラッグを確かめる。macOS 27.0.1、Xcode 27、2026-11-08。

```bash
swift run                                        # 手で触る
SPIKE_PROBE=<dir> SPIKE_PROBE_SET=1 swift run    # 合成イベントで自動操作（1〜5）
```

切り替え: `SPIKE_DRAG=move`（VM の行の `draggable` と、行とラベルの `dropDestination` を外す）、`SPIKE_NOMOVE=1`（グループに入っていない VM の `ForEach` から `onMove` を外す）、`SPIKE_ROWMENU=1`（いまの `SidebarView` と同じく、VM の行ごとに `.contextMenu` を付ける）。

自動操作は、アプリが自分のウインドウに `NSApp.postEvent` でマウスとキーのイベントを送る。アクセシビリティの許可は要らない。手順ごとにモデルの状態、表の行数、最初のレスポンダーを標準出力に書き、画像を `<dir>/step-NN.png` に保存する。サイドバーは Liquid Glass のため画像では空白に写るので、判定は標準出力で行う。

## 結果

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
