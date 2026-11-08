# vz-save-restore-test

Virtualization.framework の `saveMachineStateTo` と `restoreMachineStateFrom` が通るかを確かめる最小のプログラム（docs/11 の 3.3）。
EFI と 1 台のディスクだけの VM を起動し、15 秒後に一時停止して保存する。`RESTORE=1` を付けると、保存した状態から復元して再開し、10 秒後の状態を出す。

```bash
cd Prototypes/vz-save-restore-test
swiftc -O main.swift -o savetest
codesign --force --sign - --entitlements ../../Resources/HanaLima.entitlements savetest
cp -c ~/.lima/<停止中の Linux VM>/disk ./disk   # APFS のクローン。元の VM は使わない
./savetest disk "$PWD"                           # 保存先は ./state.vzsave（SAVE=<パス> で変えられる）
RESTORE=1 ./savetest disk "$PWD"                 # 同じ引数で復元する（efi と machine-id を使い回す）
```

`vsock entropy balloon serial net` を引数に足すと、そのデバイスも付ける（ネットワークの MAC は固定、シリアルの出力は `serial.log`）。
VM が止まると `delegate:` の行を出す。

2026-11-08 の結果:

- 画面のロック中は「permission denied」（VZErrorDomain 11）で失敗する。Secure Enclave の鍵の作成が `errSecInteractionNotAllowed` になる。
- ロックを解くと、最初の保存でキーチェーンのパスワードを求めるダイアログが出る。「常に許可」のあとは通る。
- ディスクだけの構成は保存・復元・再開まで通る。デバイスを足すと、ゲストが 15 秒以内に自分で電源を切ることが多い（理由は未調査）。

終わったら `disk`・`efi`・`machine-id`・`serial.log`・`state.vzsave`・`savetest` を消す。
