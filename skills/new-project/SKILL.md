---
name: new-project
description: 新しいプロジェクトを、PeCo 由来の Claude Code 開発運用テンプレート（4 エージェント・ラベル・マージゲート・検証 Tier・本番への出し方 5 経路）で立ち上げる。「新しいプロジェクトを作りたい」「新規リポジトリをこの運用で始めたい」「テンプレートを適用して」と言われたら使う。雛形のコピーと置換変数の記入までを行い、続きは planner の Phase 0 に引き継ぐ。
---

# new-project — 運用テンプレートで新規プロジェクトを始める

雛形の正は、このスキルの実体があるリポジトリ（`claude-dev-template`）。コピーは同梱の
`new-project.py` が行い、**既存ファイルは上書きしない**。初期化の残り（ブランチ・ラベル・
外部サービス・歩くスケルトン・ブランチ保護）は planner の **Phase 0** が受け持つ。

## 手順

### 1. 要件を確認する

- 要件ドキュメントの場所を運用者に確認し、読む
- **技術スタックと環境構成**（ホスティング・DB・認証・決済・外部連携・監視）が決まっているかを確かめる。
  決まっていなければ、ここで止めて論点を一覧で返す（**スタックは Claude が選ばない**）

### 2. スタック部品を選ぶ

```bash
TEMPLATE="$(python3 -c 'import os;print(os.path.dirname(os.path.realpath(os.path.expanduser("~/.claude/skills/new-project/SKILL.md"))))')"
python3 "$TEMPLATE/new-project.py" --list-stacks
```

要件に書かれたスタックに合う部品だけを選ぶ。どれにも当てはまらないスタックは、部品なしで進めて
CLAUDE.md の「スタック」節に手で書く（後で部品として雛形に足す候補として運用者に伝える）。

### 3. 値を集める（運用者に確認する）

| 値 | 例 | 注意 |
|---|---|---|
| プロダクト名 | Example | 表示用 |
| GitHub の組織 / リポジトリ名 | acme / example-app | リポジトリ作成は Phase 0-2 |
| 本番 / staging の URL | https://example.app / https://stg.example.app | 未定なら `TBD` と書いて後で直す |
| 許可する commit author | `名前 <email>` | **`git var GIT_AUTHOR_IDENT` の出力を使う。会話中の email から推測しない** |
| 要件ディレクトリ | docs/requirements | |

### 4. 空のリポジトリを用意してコピーする

```bash
# 例: GitHub に空のリポジトリを作ってから clone する（作成は運用者の承認を得てから）
gh repo create <owner>/<repo> --private --clone && cd <repo>

python3 "$TEMPLATE/new-project.py" --target . \
  --name "<プロダクト名>" --owner "<owner>" --repo "<repo>" \
  --prod-url "<本番URL>" --staging-url "<stagingURL>" \
  --author "$(git var GIT_AUTHOR_IDENT | sed 's/>.*/>/')" \
  --requirements-dir docs/requirements --stacks "<部品,部品>" --dry-run   # まず確認
# 問題がなければ --dry-run を外して実行
```

- 終了コード 2 は「上書きしそうなので止めた」。対象ディレクトリを確かめる
- 埋まらなかった `{{...}}` は `docs/bootstrap.md` に記録される

### 5. 公式ジェネレーターの出力を足す（必要なら）

要件で決まったフレームワークの公式ジェネレーター（例: Next.js なら `create-next-app`）を、
**出力に手を加えずに**実行する。生成物が雛形のファイルと衝突したら、雛形側を正とし、衝突の内容を運用者に報告する。
`.github/gate-commands.env` のコマンドを、そのスタックの実際のコマンドに合わせる。

### 6. planner の Phase 0 に引き継ぐ

初回コミットを作る前に、planner を呼んで Phase 0 を **0-3 から**進めてもらう
（初回コミット → dev / staging とラベル → ローカル環境 → 外部サービス → 歩くスケルトン → ブランチ保護 → 運用基盤）。
運用者にしかできない作業で planner が止まったら、そのチェックリストを運用者に渡す。

## やってはいけないこと

- スタックを Claude が選ぶ / 要件に無い部品を足す
- 既存のリポジトリに上書きでコピーする（このスキルは新規プロジェクト専用）
- 鍵・トークンを雛形・リポジトリ・Issue・会話のログに書く
- ブランチ保護を歩くスケルトンより先に設定する（必須ジョブは一度走らないと指定できない）
