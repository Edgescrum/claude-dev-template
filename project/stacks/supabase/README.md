# スタック部品: supabase（PeCo 由来）

PostgreSQL（Supabase）を DB に使うプロジェクト向けの規則・文書・CI 検査。

## 何を扱うか

- クライアントの使い分け（ブラウザ / サーバー / middleware / service-role）
- RLS を全テーブルで有効にする規則と、service-role をシステム経路に限る規則（lint の allowlist で強制する考え方）
- `getClaims()` を使い `getSession()` をサーバーで使わない、middleware のセッション更新の作法
- 未認証で読めるテーブルに capability secret を置かない規則
- マイグレーションの採番（`supabase migration new`・UTC・逆行・3 ブランチ間の衝突・SQL 関数の後勝ち）
- 隔離 worktree でのローカル DB スタックの起動〜片づけ（`supabase stop` を直接打たない）
- 昇格 / 選択リリース時のマイグレーション確認（runbook 補足）

## いつ選ぶか

- DB に Supabase（PostgreSQL + PostgREST + RLS）を使うとき
- Supabase Auth を使うかどうかは問わない（使わない場合は CLAUDE.section の冒頭に 1 行で書く）
- アプリ側のフレームワークが Next.js でなくても選べる。ただし「クライアントの使い分け」と
  「セッションと認証」の節は `@supabase/ssr` 前提なので、別フレームワークなら読み替える

## ファイル

| パス（プロジェクト内） | 中身 |
|---|---|
| `CLAUDE.section.md` | CLAUDE.md の末尾に「## スタック: supabase」として追記する節 |
| `docs/agents/isolated-db-stack.md` | 隔離 worktree でのローカル DB スタックの作法とラッパーの要件（唯一の置き場所） |
| `docs/runbooks/release-supplement-supabase.md` | 昇格 / 選択リリース時のマイグレーション確認（`release-and-hotfix.md` から参照される） |
| `scripts/gate-extra.d/supabase-migration-versions.sh` | PR ゲートの拡張: マイグレーション version の衝突と逆行の検査 |
| `scripts/selftest-supabase-migration-versions.sh` | 上の検査の空振り検査（一時リポジトリで標本を流す） |

## CI に足すもの（拡張点 `scripts/gate-extra.d/*.sh`）

| スクリプト | 何を止めるか | 終了コード |
|---|---|---|
| `supabase-migration-versions.sh` | 同じ version・別名のマイグレーションの併存（HEAD と origin/dev・staging・main）/ 新規 version が base の最大以下（昇格 PR では免除） | 0 合格 / 1 違反 / 2 判定不能 |

前提（拡張点の約束）: リポジトリ直下で実行され、`BASE_REF` に PR の base ブランチ名が入り、
`origin/dev` `origin/staging` `origin/main` が fetch 済みであること（無い ref は衝突検査から外して note を出す）。

自己テスト `scripts/selftest-supabase-migration-versions.sh` も CI のガード自己テストに登録すること。

## 雛形に含めていないもの（初期化で用意する）

- `db:isolate` / `db:start` / `db:stop` / `db:reset` / `db-tests` / `env:localdb` / `db-target` のラッパー本体。
  要件は `docs/agents/isolated-db-stack.md` §3
- remote へのマイグレーション適用ワークフロー（push: staging / main で `supabase db push --include-all`）
- service-role の import を制限する lint 設定（`no-restricted-imports` と 2 つの許可リスト）
