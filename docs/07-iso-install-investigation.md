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

## 6. 無人インストールと E2E（2026-10-26）

自動テストのために、Ubuntu Server の autoinstall で無人インストールする道を調べた。

- **直接のカーネル起動（`VZLinuxBootLoader`）は使えない。** ISO の `casper/vmlinuz` は EFI アプリケーションの中に zstd 圧縮の zboot を抱えた形式で、展開すれば VZ が起動できる arm64 の Image になる（`scripts/extract-iso-kernel.py`、Python 3.14 の zstd が要る）。カーネルは起動し、インストーラーも動くが、EFI のファームウェアが無い（`/sys/firmware/efi` が無い）ため、最後の「カーネルの設定」（`dpkg-reconfigure linux-image`、ブートローダーの組み立て）で失敗する。
- **採用した方式: EFI 経由で、カーネルの引数だけ足す。** ISO から `EFI/boot/`（shim、GRUB、MokManager）と `.disk/info`（GRUB の組み込み設定が探す目印）を取り出し、128 MiB の FAT イメージ（MBR、`diskutil eraseDisk`）に、HanaLima の `grub.cfg`（`search --file /casper/vmlinuz` で ISO を見つけ、`autoinstall --- console=tty0 console=hvc0` を付けて起動）と一緒に入れる。この FAT を ISO より前の USB として付けると、EFI はまずこれを起動し、HanaLima の `grub.cfg` が読まれる（`autoinstall` がカーネルに渡ったことで確認。GRUB の組み込み設定が `.disk/info` を探して root を決めるというのは推測で、組み込み設定の中身は未確認）。カーネルと initrd は ISO のものをそのまま使うので、展開も zstd も要らない（`InstallerAutoinstall`）。
- **無人設定（NoCloud の seed、ラベル `cidata`）** は virtio のブロックデバイスとして付ける（`/dev/vdb`。インストール先は `/dev/vda` に固定）。late-commands で `limaify.sh` と同じ cloud-init の手順を `curtin in-target` で実行し、`shutdown: poweroff` で止める。**YAML の落とし穴**: late-commands の行に `: ` を含めると（`printf 'datasource_list: [ ... ]'`）マッピングとして解釈され、cloud-init が設定を読めずに**黙って対話式になる**。各コマンドは二重引用符の文字列にする（`InstallerAutoinstall.userData`）。
- シリアルコンソール（`console=hvc0` を最後に置く）に subiquity の進み具合が出るので、`hanalima-installer-serial.log` で追える。試作ツールにはシリアルへの入力（FIFO）も足し、失敗時に「Press enter to start a shell」から中のログを読めた。
- **E2E `ISOInstallEndToEndTests`**（`HANALIMA_E2E=1 HANALIMA_E2E_ISO=<ISO> swift test --filter ISOInstallEndToEnd`）: ダミーのイメージで `limactl create` → 署名した `build/HanaLima.app` を `HANALIMA_E2E_AUTOINSTALL` で起動して無人インストール（`InstallerVM` を画面なしで使う。`swift test` のプロセスは署名されていないので VZ を使えない）→ `limactl start` → ユーザー・cloud-init（`/dev/vdb` の NoCloud）・ゲストエージェントを確認 → 削除。インストール 353 秒、全体 372 秒で通過。
- インストーラーは `/etc/cloud/cloud.cfg.d/00-subiquity-disable-cloudinit-networking.cfg`（`network: {config: disabled}`）を残す。それでも Lima の追加 NIC（vzNAT の `lima0`）にはアドレスが来た（Lima の起動スクリプトが設定する）ので、そのままにしている。
- 無人インストールは今のところ E2E 専用で、アプリの機能にはしていない（FAT イメージの作成に `hdiutil`・`diskutil`・`bsdtar` を使うので、機能にすることは可能）。

## 7. 残る課題

- **アプリ本体に `com.apple.security.virtualization` の entitlement** が要る（今は netd だけ）。VZ の画面（`VZVirtualMachineView`）はアプリのプロセスの中でしか出せない。
- インストール中の VM はアプリのプロセスで動くので、アプリを終了するとインストールも止まる。
- **VZ の画面にはクリップボードの橋渡しがない**ので、仕上げのコマンドは手入力になる。短くするか、別の方法（シリアルコンソールへの流し込み、Ubuntu の autoinstall など）を考える。
- インストール前の VM（空のディスク）を普通に起動すると、1 分の待ちのあとに失敗する。HanaLima では記録に「インストール待ち」の印を付け、起動を止めて「インストーラーを開く」に誘導する。
- Ubuntu の案内付き LVM はディスクの一部しか使わず、Lima でディスクを広げたときの growpart も効かないので、「LVM を外す」ことを案内する。
- 確かめたのは Ubuntu Server だけ。Debian・Fedora・Alpine（cloud-init の有無が違う）は未確認。
- QEMU の VM（qcow2）は対象外。VZ 専用の機能になる。
