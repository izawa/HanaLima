# インストーラーの ISO から Lima の VM を作る（試作の結果）

調査日: 2026-10-26 / 環境: macOS 27.0.1 (Apple Silicon), Lima 2.2.1, Ubuntu Server 26.04 LTS (arm64)

## 1. 目的

Lima が起動できるのは cloud-init 対応のクラウドイメージだけで、対話式のインストーラー（ISO）からは VM を作れない。一方で、Lima の VM のファイルは `~/.lima/<名前>/` にあるただのファイルなので、**ディスクに Lima の外から OS を書き込み、あとは Lima に任せる**ことができるはずだと考え、確かめた。試作は `Prototypes/vz-installer/`。

## 2. 結論

**できた。** 手順は 3 段階で、Lima から逸脱するのは真ん中だけ。

1. `limactl create` に 1 MiB のダミーの raw イメージを渡す。Lima は指定した大きさの空の `disk`（スパース）と `lima.yaml` を作る。
2. HanaLima（試作では小さなコマンド）が Virtualization.framework で VM を起動し、Lima の `disk` にインストーラーの ISO から OS を入れる。EFI の変数ストアは Lima と同じ `vz-efi`、機械の識別子も Lima の `vz-identifier` を使う。
3. インストールした OS で仕上げのスクリプト（`limaify.sh`）を 1 回実行して電源を切る。以後は `limactl start` で、Lima の cloud-init（`cidata.iso`、NoCloud）がユーザー・鍵・ゲストエージェント・共有・プロビジョニングを仕込み、普通の Lima の VM になる。

Ubuntu Server 26.04 で、`limactl start` の 1 回目は約 7 秒で READY。ユーザー `izawa`（uid 501）、ゲストエージェント、ホームの virtiofs 共有、`host.lima.internal`、ホスト名 `lima-<名前>` のすべてが整った。2 回目の起動も約 4 秒で問題なし。

## 3. 確かめた事実

| 事実 | 確認 |
|---|---|
| `limactl create` はローカルの raw ファイルを `images` として受け付け、作成時に `disk` を作る。キャッシュには残らない | 1 MiB のダミーで作成、`disk` は 20 GiB（使用量 1 MB） |
| `limactl start` は既存の `disk` と `vz-efi` をそのまま使う | 起動の前後で inode が同じ |
| ダミーのイメージのファイルを消しても `start`・`edit`・`list`・`clone` は動く（`create` だけが必要とする） | ファイルを退避して起動・`edit --set .cpus`・一覧・`clone` |
| VZ は USB の記憶装置として付けた ISO から EFI 起動する | GRUB のメニューが出た |
| インストーラーが書いた EFI の起動エントリは共有した `vz-efi` に残り、**ISO を付けたままでもディスクから起動する** | 再起動後にインストールした Ubuntu が起動。Lima で起動後の `efibootmgr` でも `BootCurrent` は `Boot0003* Ubuntu`（`\EFI\ubuntu\shimaa64.efi`）で、`BootOrder` の先頭。Ubuntu は取り外し用の `\EFI\BOOT\BOOTAA64.EFI` も置くので、エントリがなくても起動はできる見込み |
| Lima の `vz-identifier` は `VZGenericMachineIdentifier(dataRepresentation:)` でそのまま読める | 試作で読み込み |
| Ubuntu のインストーラーが入れる cloud-init は、Lima の `cidata.iso`（NoCloud、`/dev/vdb`）を読んだ | `cloud-init status: done`、datasource は NoCloud |

## 4. 仕上げのスクリプト（limaify.sh）

インストールした OS に対して、root で 1 回だけ実行する。

- cloud-init と openssh-server を入れる（apt・dnf・apk・pacman を見分ける。Ubuntu Server では両方とも入っていた）。
- インストーラーが残した cloud-init の設定（`/etc/cloud/cloud-init.disabled`、`99-installer.cfg`、`90-installer-network.cfg`）を消し、`datasource_list: [NoCloud, None]` を置き、`cloud-init clean --logs` で「次が初回」にする。
- cloud-init が入手できない OS では、Lima のユーザー（uid 501）と公開鍵、sudo、sshd だけを用意する代替に落とす（Lima は SSH で起動完了と見なすので起動とコンソールは使えるが、ゲストエージェントがないので共有やポート転送は「DEGRADED」になる。未確認）。

スクリプトは、小さな ISO（ラベル `HANALIMA`、中身はスクリプト・Lima の公開鍵・ユーザー名）として VM に付け、`sudo mount -L HANALIMA /mnt && sudo sh /mnt/limaify.sh` で実行する。

## 5. アプリでの往復（2026-10-26）

試作のあと、同じ流れをアプリに組み込んだ（作成画面の「インストーラーの ISO」、「インストール待ち」の印と起動の抑止、インストールのウインドウ、仕上げの ISO の自動生成、「インストール完了」で Lima に引き渡し）。Ubuntu Server 26.04 で、ウインドウの「インストーラーを開く」→ インストール → 仕上げのコマンド → 「電源を切る（要求）」（ACPI、Ubuntu は正常に停止した）→ 「インストール完了」→ Lima で起動、までを通し、ユーザー `izawa`、cloud-init、ゲストエージェント、ホームの共有がそろうことを確かめた。印は Lima の起動が成功した時点で消す（仕上げを忘れた VM でも「インストーラーを開く」が残る）。

## 6. 残る課題

- **アプリ本体に `com.apple.security.virtualization` の entitlement** が要る（今は netd だけ）。VZ の画面（`VZVirtualMachineView`）はアプリのプロセスの中でしか出せない。
- インストール中の VM はアプリのプロセスで動くので、アプリを終了するとインストールも止まる。
- **VZ の画面にはクリップボードの橋渡しがない**ので、仕上げのコマンドは手入力になる。短くするか、別の方法（シリアルコンソールへの流し込み、Ubuntu の autoinstall など）を考える。
- インストール前の VM（空のディスク）を普通に起動すると、1 分の待ちのあとに失敗する。HanaLima では記録に「インストール待ち」の印を付け、起動を止めて「インストーラーを開く」に誘導する。
- Ubuntu の案内付き LVM はディスクの一部しか使わず、Lima でディスクを広げたときの growpart も効かないので、「LVM を外す」ことを案内する。
- 確かめたのは Ubuntu Server だけ。Debian・Fedora・Alpine（cloud-init の有無が違う）は未確認。
- QEMU の VM（qcow2）は対象外。VZ 専用の機能になる。
