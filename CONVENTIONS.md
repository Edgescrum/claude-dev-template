# 雛形の約束事（作る人・直す人向け）

この雛形は PeCo で育てた「4 エージェント × GitHub ラベル × マージゲート」の運用を、
新規プロジェクトに持ち出すためのもの。**ここに書いた約束事は、雛形のすべてのファイルが従う。**

## 1. 3 つの層

| 層 | 置き場所 | 入れ方 |
|---|---|---|
| ユーザーレベル | `agents/`・`skills/` | `install.sh` が `~/.claude/agents/`・`~/.claude/skills/` にリンクする |
| コア（どのプロジェクトにも入る） | `project/core/` | `/new-project` が新しいリポジトリにコピーする |
| スタック別の部品（要件で選ぶ） | `project/stacks/<名前>/` | `/new-project` が、要件に書かれたスタックの部品だけをコピーする |

- **スタック依存の中身は汎用化しない。** Supabase・LINE・Stripe などの規則は、それぞれの部品の中に書く。
  コアには「どの部品を使っているかはプロジェクトの CLAUDE.md を見よ」とだけ書く
- **PeCo 固有のもの（プロダクトの規則・事故の経緯の詳細・seed データ）は持ち出さない**
- ユーザーレベルのエージェントは、プロジェクトの `.claude/agents/` に同名があればそちらが優先される
  （PeCo は自分の定義を持ち続ける）

## 2. 置換変数

`/new-project` がコピー時に置き換える。ファイル名の末尾 `.tmpl` は、置換後に外す。

| 変数 | 意味 | 例 |
|---|---|---|
| `{{PROJECT_NAME}}` | プロダクト名（表示用） | Example |
| `{{GITHUB_OWNER}}` | GitHub の組織 / ユーザー | acme |
| `{{GITHUB_REPO}}` | リポジトリ名 | example-app |
| `{{PROD_URL}}` | 本番 URL | https://example.app |
| `{{STAGING_URL}}` | staging URL | https://stg.example.app |
| `{{ALLOWED_AUTHOR}}` | 許可する commit author（`名前 <email>`） | Taro Yamada <taro@example.com> |
| `{{REQUIREMENTS_DIR}}` | 要件ドキュメントの置き場所 | docs/requirements |
| `{{STACKS}}` | 採用したスタック部品の一覧（CLAUDE.md に表で入る） | supabase, nextjs-vercel |

- **スクリプトと CI はリポジトリ名を変数で持たない。** `GITHUB_REPOSITORY`（Actions）か `gh repo view --json nameWithOwner` で解決する
- **評決マーカーは固定の名前**: `<!-- agent-review verdict=<approved|changes-requested|blocked> sha=<40 桁> pr=<番号> -->`
  （PeCo の `peco-review` に相当。プロジェクト名を埋めない）

## 3. 文書の書き方

- **判定表・閾値・ジョブ名は 1 か所にだけ置き、他からは参照する。** エージェント定義には手順・禁止事項・受け渡しだけを書く
- **規則には「なぜ」を 1 行だけ添える。** 事故の経緯の長文は PeCo 側に残し、雛形には持ち出さない
- 実在する検査やスクリプトを名指しするときは、雛形の中に実体があるものだけにする

## 4. ブランチとラベル（固定）

- ブランチ: `main`（本番）/ `staging`（デモ・UAT）/ `dev`（統合）。feature ブランチは常に dev の最新から切る
- ラベル: `Must` `Should` `Could` `review-ready` `changes-requested` `approved` `blocked` `demo-ready` `uat` `merge-ready` `hotfix` `ds-debt`
