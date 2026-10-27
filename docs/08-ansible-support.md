# Ansible による構成管理をどう支えるか（検討メモ）

検討日: 2026-10-27 / 環境: macOS 27.0.1 (Apple Silicon), Lima 2.2.1, ansible-core 2.21.5（pip、pyenv の Python 3.14）

## 1. ねらい

プロビジョニング（起動のたびに走るシェルスクリプト）だけでは手に余る構成を、Ansible の Playbook に任せたい。方針は **HanaLima 側の変更は小さく、柔軟性は大きく**。Playbook の編集や Galaxy、Vault などは HanaLima では扱わず、ユーザーが普段どおりに書いたものをそのまま使えるようにする。

## 2. Lima の `mode: ansible` は使わない

Lima にはプロビジョニングの `mode: ansible`（`playbook:` を指定し、ホストの `ansible-playbook` を起動後に実行する）があるが、Lima 2.2.1 のテンプレートに **「非推奨。起動後にホストから `ansible-playbook` を直接呼ぶか、ゲストの中で ansible を動かすこと」** と書かれている。HanaLima もその指示どおり、ホストから直接呼ぶ。`lima.yaml` には何も書かないので、HanaLima なしでも VM はそのまま動く。

## 3. 設計

**ホスト側だけで完結する。** ゲストに Ansible を入れない（コントロールノードは Mac）。

1. **インベントリを HanaLima が作る。** `~/Library/Application Support/HanaLima/ansible/<VM 名>.ini`:
   ```
   lima-<VM 名> ansible_ssh_common_args='-F /Users/<me>/.lima/<VM 名>/ssh.config'
   ```
   Lima の `ssh.config` がホスト名 `lima-<VM 名>`、ポート、鍵、ユーザーを持つので、これだけで届く。VM を起動するたび（ポートが変わりうる）に書き直す。
2. **`ansible-playbook` の有無は、実行して確かめる**（`ansible-playbook --version`）。パスだけ見ると、Intel 版の残骸（この Mac には `/usr/local/bin/ansible-playbook` 8.4.0 があり、「bad CPU type」で落ちる）を拾ってしまう。候補は `/opt/homebrew/bin`、`~/.pyenv/shims`（pip。Finder から起動したアプリの PATH には無い）、`~/.local/bin`（pipx・uv）、`/usr/local/bin`。設定画面で場所を指定できるようにもする。無ければ `brew install ansible` か `pip install ansible` を案内する。
3. **実行は「今すぐ実行」と同じ出力エンジン（`ScriptRun`）で。** `ansible-playbook -i <インベントリ> --limit lima-<VM 名> <playbook>` を、作業ディレクトリ＝Playbook のあるフォルダ（`roles/`、`group_vars/` が相対パスで解決される）、`ANSIBLE_FORCE_COLOR` なし、`ANSIBLE_HOST_KEY_CHECKING=False` は不要（`ssh.config` が `StrictHostKeyChecking=no` を持つ）で起動し、出力をシートに流す。中止は SIGINT。
4. **VM ごとの記録に残す**（`hanalima-vm.json` の `ansible: {playbook, extraArgs, lastRunAt}`）。概要タブか設定タブに「Playbook: …」「前回: …」「実行」「もう一度」を置く。Playbook は VM のフォルダの外（ユーザーのリポジトリ）にあるので、パスだけを持つ。
5. **ゲストの前提は Python 3 だけ。** Ubuntu・Debian・Fedora は既定で入っている。Alpine は入っていないので、「基本ツール一式」のような例に `python3` を足すか、Playbook の最初に `raw: apk add python3` を置く（ユーザーの判断）。

## 4. やらないこと

- ゲストの中で Ansible を動かす（`ansible-pull`）。コントロールノードが 2 つになり、Playbook の置き場所も分かれる。
- Playbook の編集画面、Galaxy のインストール、Vault のパスワード入力。すべて普段のターミナルで行う。
- 「起動のたびに Playbook を実行」。Lima のプロビジョニングとちがって時間がかかり、Lima 自身が非推奨にした使い方でもある。必要なら「次の起動で 1 回」（ワンショットの仕組み）に Playbook の実行を載せられるが、まずは手動の「実行」だけにする。

## 5. HanaLima 側の変更の見積もり

- インベントリの生成: 20 行。
- `ansible-playbook` の検出: 30 行。
- 実行と出力: `ScriptRun` をそのまま使う（`LimaClient` ではなく `ProcessRunner` で任意のコマンドを流す口を足す）。
- 記録と UI: 100 行前後。
- 単体テスト: インベントリの文字列、検出の優先順位。E2E: Alpine 以外の 1 台に、`ping` モジュールと `apt`/`dnf` の 1 タスクの Playbook。

合わせて 1 日程度。前提の「今すぐ実行」（出力エンジン）は 2026-10-27 に実装した。

## 6. 実機確認（2026-10-27）

`hanalima-e2e-isoflow`（Ubuntu 26.04）に対して、上の 1 行だけのインベントリで `ansible-playbook` を実行した。

- `ping`、`setup`（facts）、`become: true` の `copy`（`/etc` への書き込み）がそのまま通った。Lima がユーザーにパスワード無しの sudo を与えているので、`become` に設定は要らない。2.3 秒。2 回目は `changed=0`。
- Lima の `ssh.config` には `StrictHostKeyChecking no`、`UserKnownHostsFile /dev/null`、`User`、`IdentityFile`、`ControlPath` が入っているので、`ANSIBLE_HOST_KEY_CHECKING` などの環境変数も不要。HanaLima が足すのはインベントリの 1 行だけ。
- `ansible-core 2.21` は `ansible_distribution` のような変数の直接参照に非推奨の警告を出す（`ansible_facts["distribution"]` を使う）。Playbook 側の話で、HanaLima には関係しない。

## 7. Ansible の実装に依存しない形

**状況（2026-10-27）**: 段階 1 と 3 を実装した（`Ansible`、`AppModel+Ansible`、設定タブの「Ansible」、設定ウインドウの場所の指定。E2E は `AnsibleEndToEndTests`）。段階 2（起動後の自動実行）は作っていない。


Ansible が変わっても HanaLima の変更が要らないように、触るのは次の 3 点だけに限る。どれも Ansible が長く約束している外側のインターフェースで、モジュールや collection、Python の API には触れない。

| HanaLima が使うもの | 安定している理由 |
|---|---|
| INI 形式のインベントリの 1 行（`<ホスト> ansible_ssh_common_args='-F …'`） | 1.x からある書式。`ansible_ssh_common_args` も 2.0 から |
| `ansible-playbook -i <inv> [--limit] <playbook>` の起動と終了コード、標準出力 | CLI の基本。終了コードは 0＝成功、それ以外＝失敗 |
| ユーザーが置いた `ansible.cfg`（作業ディレクトリ＝Playbook のフォルダ） | 設定はすべてユーザーのもの。HanaLima は環境変数を足さない |

やらないこと（依存が深くなるもの）: JSON コールバックで出力を構造化する（コールバックのプラグイン名や出力形式は版で変わる）、Python の API を呼ぶ、collection を同梱する、Playbook のテンプレートを生成する。出力は「今すぐ実行」と同じく、そのまま文字で流す（色は `ANSIBLE_FORCE_COLOR` を付けなければ出ない）。

### 段階案

1. **最小（半日）**: 設定タブの「プロビジョニング」の下に「Ansible」の節。Playbook のファイルを選ぶ → 「実行」で `ansible-playbook -i <自動生成のインベントリ> <playbook>` を Playbook のフォルダで起動し、出力をシートに流す。`ansible-playbook` の検出と場所の設定。記録（`hanalima-vm.json` の `ansible.playbook`、`lastRunAt`）。
2. **起動後に自動で実行（＋半日）**: 記録に `runAfterStart: true` を持ち、`limactl start` が READY になったら HanaLima が 1 を実行する（Lima の非推奨の `mode: ansible` の代わり。HanaLima が動いているときだけ）。「一度だけ」と組み合わせるなら、Playbook 側で冪等に書くのが Ansible の流儀なので、印は付けない。
3. **複数 VM（＋半日）**: インベントリを 1 ファイルにまとめ（`[hanalima]` グループに全 VM、VM ごとに `--limit`）、ユーザーが自分の `ansible-playbook` から `-i ~/Library/Application Support/HanaLima/ansible/inventory.ini` で HanaLima の VM を全部まとめて扱えるようにする。HanaLima を経由しない使い方への入口で、追加のコードはインベントリの書き出しだけ。

段階 1 と 3 だけでも十分で、3 は「HanaLima に依存しない」方向（ターミナルから使う）を開く。

### 注意

- pyenv の shim（`~/.pyenv/shims/ansible-playbook`）は、作業ディレクトリの `.python-version` が指す Python を使う。HanaLima は Playbook のフォルダで実行するので、そこに ansible の無い Python を指す `.python-version` があると `pyenv: ansible-playbook: command not found` で失敗する（検出は通る）。shim を解決して回避するのは Ansible 側の実装への依存になるので、しない。設定タブの注記に書いた。
- インベントリには停止中の VM も載る。ターミナルから `--limit` なしで実行すると、停止中の VM は `unreachable` になる（ファイルの冒頭にコメントで書いた）。
- 設定で指定した場所が動かないときは、通常の場所から探したものを使い、設定タブに注意を出す。
