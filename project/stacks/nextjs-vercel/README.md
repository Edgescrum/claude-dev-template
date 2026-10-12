# スタック部品: nextjs-vercel（PeCo 由来）

Next.js（App Router）を Vercel にデプロイするプロジェクト向けの規則と、エージェントが開発サーバーを扱う作法。

## 何を扱うか

- App Router の規則（Server / Client の分け方・Server Action の認可・`params` の `await`・再検証・エラーは戻り値で返す）
- 環境変数（`NEXT_PUBLIC_` の意味・Sensitive 型は読み返せない・環境ごとのスコープ・取り違えの確認）
- Vercel Functions で非同期処理を `await` する規則
- デプロイの commit identity（Vercel チームのメンバーでないと preview が拒否される）
- エージェント用の開発サーバー / 本番モードサーバーのラッパーの規約名と実装要件

## いつ選ぶか

- フロントエンド兼 API に Next.js（App Router）を使い、Vercel にデプロイするとき
- Vercel 以外にデプロイする場合も App Router の節は使える。「Vercel Functions」「環境変数のスコープ」「デプロイ」の節は読み替える

## ファイル

| パス（プロジェクト内） | 中身 |
|---|---|
| `CLAUDE.section.md` | CLAUDE.md の末尾に「## スタック: nextjs-vercel」として追記する節 |
| `docs/agents/dev-server-nextjs.md` | `dev:*` / `measure:e2e` / `prod:*` の規約名と、ラッパーが満たすべき Next.js 固有の要件（唯一の置き場所） |

## CI に足すもの

拡張点 `scripts/gate-extra.d/*.sh` には何も足さない。lint / 型検査 / ビルドは CLAUDE.md の「コマンド」表
（`.github/gate-commands.env`）で `next lint` 相当・`tsc --noEmit`・`next build` を指定する。

## 雛形に含めていないもの（初期化で用意する）

- 開発サーバー / 本番モードサーバーのラッパー本体と、その自己テスト（要件は `docs/agents/dev-server-nextjs.md` §2・§4）
- `measure:e2e`（e2e の前後でソース指紋を検査するラッパー）
- 開発用ログイン（認証付き画面をブラウザ自動操作で測るため。必要な場合のみ）
