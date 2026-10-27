# Ansible による構成管理をどう支えるか（検討メモ）

検討日: 2026-10-27 / 環境: macOS 27.0.1 (Apple Silicon), Lima 2.2.1, Ansible 14.5.0（Homebrew）

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
2. **`ansible-playbook` の有無は、実行して確かめる**（`ansible-playbook --version`）。パスだけ見ると、Intel 版の残骸（この Mac には `/usr/local/bin/ansible-playbook` 8.4.0 があり、「bad CPU type」で落ちる）を拾ってしまう。候補は `/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`（pipx・uv）。無ければ `brew install ansible` を案内する。
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
