# Security Policy

[日本語](#日本語)

## Reporting a vulnerability

Please don't report security problems in public issues or discussions.

Report them privately from the repository's **Security** tab → **Report a vulnerability** ([open the form](https://github.com/izawa/HanaLima/security/advisories/new)). Only you and the maintainer can see the report.

Include, as far as you can:

- the HanaLima version (About HanaLima), the macOS version, and the Lima version (`limactl --version`)
- what an attacker can do, and from where (another process on the Mac, a guest VM, the network)
- steps to reproduce

HanaLima is maintained by one person in their spare time. I'll reply as soon as I can, usually within a week, and we can agree on when to publish once a fix is out.

## What is in scope

HanaLima itself: the app, its VM driver (`lima-driver-hanalima`), its network helper (`hanalima-netd`) and its MCP helper (`hanalima-mcp`), as published in this repository and its releases.

Problems in Lima, macOS or a guest operating system belong to those projects. If HanaLima makes such a problem worse (for example by changing a default), that is in scope.

## Supported versions

Only the latest release gets fixes.

---

## 日本語

### 脆弱性の報告

セキュリティの問題は、公開の Issue や Discussions には書かないでください。

リポジトリの **Security** タブの **Report a vulnerability** から、非公開で報告してください（[報告の画面](https://github.com/izawa/HanaLima/security/advisories/new)）。報告は、報告した人とメンテナーだけが見られます。

分かる範囲で、次のことを書いてください。

- HanaLima の版（「HanaLima について」）、macOS の版、Lima の版（`limactl --version`）
- 攻撃する側が何をできるか、どこから攻撃できるか（Mac のほかのプロセス、ゲストの VM、ネットワーク）
- 再現の手順

HanaLima は 1 人が空いた時間に作っています。返事はできるだけ早く、たいていは 1 週間以内にします。直した版を出したあと、いつ公開するかを相談して決めます。

### 対象

HanaLima 自身が対象です。このリポジトリとリリースで配っている、アプリ、VM のドライバー（`lima-driver-hanalima`）、ネットワークのヘルパー（`hanalima-netd`）、MCP のヘルパー（`hanalima-mcp`）を含みます。

Lima、macOS、ゲストの OS の問題は、それぞれのプロジェクトに報告してください。ただし、HanaLima が既定値を変えるなどして問題を大きくしている場合は、対象に含みます。

### 直す版

直すのは最新のリリースだけです。
