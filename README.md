# Claude Code 開発運用テンプレート（PeCo 由来）

PeCo で育てた「4 エージェント × GitHub ラベル × マージゲート」の運用を、新しいプロジェクトで
初日から使うためのテンプレート。Claude Code のユーザーレベル（`~/.claude`）に入れて使う。

## できること

| 入口 | 何をするか |
|---|---|
| `/new-project`（スキル） | 要件を確認し、雛形（コア + 選んだスタック部品）を新しいリポジトリにコピーして置換変数を埋める |
| `planner` エージェントの Phase 0 | ブランチ・ラベル・ローカル環境・外部サービス・歩くスケルトン・ブランチ保護・運用基盤を、実行して受信側で検証しながら整える |
| Phase D（`ui-figma-ds` 部品） | grill でデータ契約まで決め、中核の動線だけモック化して DS の土台と Figma プロトタイプを作る。実装は Figma を待たない部分から並行で始める |
| `orchestrator` / `generator` / `evaluator` | Sprint を PR① → マージゲート → PR② → PR③ の流れで回す |

## インストール

```bash
git clone https://github.com/Edgescrum/claude-dev-template.git ~/dev/claude-dev-template
cd ~/dev/claude-dev-template
./install.sh --dry-run   # 何をするか確認
./install.sh             # ~/.claude/agents と ~/.claude/skills にリンクを張る
```

前提: `git`・`gh`（GitHub CLI・ログイン済み）・`python3`。生成したプロジェクトの CI は GitHub Actions を使う。

- リンクなので、このリポジトリを更新すれば次のセッションから反映される
- 既存の実ファイルは上書きせず、衝突として報告する（exit 2）
- プロジェクトの `.claude/agents/` に同名の定義があれば、そちらが優先される。PeCo は自前の定義を使い続ける
- 外すときは `./install.sh --uninstall`

## 構成

```
agents/                     ユーザーレベルのエージェント定義（汎用）
skills/new-project/         /new-project スキルとコピー用スクリプト
project/core/               どのプロジェクトにも入る雛形（CLAUDE.md・docs・CI・スクリプト）
project/stacks/<名前>/      スタック別の部品（要件で選ぶ）
CONVENTIONS.md              雛形を作る・直すときの約束事（置換変数・層・書き方）
```

スタック部品の一覧は `python3 skills/new-project/new-project.py --list-stacks` で見られる。

## 更新の流れ

- PeCo で運用ルールが変わったら、汎用的な部分をここに反映する（PeCo 固有の事情は持ち込まない）
- 新しいスタックを使ったプロジェクトが出たら、その規則を `project/stacks/<名前>/` に部品として足す
- 生成済みのプロジェクトには自動では反映されない。必要なら差分を PR で取り込む

## 由来

PeCo（2026-04〜）の運用。設計判断の経緯は PeCo リポジトリの `docs/agents/`・`docs/runbooks/`・
`docs/v2/requirements/25_design-system.md` にある。

## まだ雛形に入れていないもの

PeCo にはあるが、汎用化が済んでいないもの。必要になったプロジェクトから順に足す。

| もの | PeCo での役割 | 入れる先の候補 |
|---|---|---|
| dev サーバー・DB スタックのラッパー（`dev:start` / `db:start` など） | ポート・PID・素性の記録と検査 | `stacks/nextjs-vercel` / `stacks/supabase`（今は要件の表だけ） |
| ミューテーションの共通ランナー | 陰性対照・着弾確認を機械化 | core（今は `docs/verification-tiers.md` に要件だけ） |
| ゲート構成の整合検査・ブランチ保護の照合 | ワークフローと必須ジョブ一覧のずれ検知 | core |
| `docs/agents` の機械検査（参照パスの実在など） | エージェント定義の参照切れ検知 | core |
| SQL 関数の後勝ち検査 | 別ブランチの同名関数の上書き検知 | `stacks/supabase`（今は手順書の 1 行コマンド） |
