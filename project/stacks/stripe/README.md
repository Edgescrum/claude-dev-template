# スタック部品: stripe（PeCo 由来）

Stripe で課金するプロジェクト向けの規則と、昇格時の webhook 購読の突き合わせ手順。

## 何を扱うか

- test / live の分離と鍵の取り違えの防止
- webhook の署名検証・冪等処理・処理イベント一覧（manifest）とコードの一致
- 購読イベントの突き合わせ（購読漏れはエラーを出さずに金銭的な実害を生む）
- クライアントの金額を信じない・支払いの確定は webhook で
- 期間末解約のパターン

## いつ選ぶか

- 課金（サブスクリプション・単発決済）に Stripe を使うとき

## ファイル

| パス（プロジェクト内） | 中身 |
|---|---|
| `CLAUDE.section.md` | CLAUDE.md の末尾に「## スタック: stripe」として追記する節 |
| `docs/runbooks/release-supplement-stripe.md` | 昇格 / 選択リリース時の購読イベントの突き合わせ（`release-and-hotfix.md` から参照される） |

## CI に足すもの

拡張点 `scripts/gate-extra.d/*.sh` には何も足さない（Stripe 側の設定の読み取りには鍵が要るため CI では走らせない）。
manifest とコードの `case` の一致は、プロジェクトの単体テストとして置く。

## 初期化でやること

- test / live のアカウント設定と、endpoint を stg / 本番で作る（運用者の作業）
- 価格の正の置き場所を決めて CLAUDE.section に書く
- 解約後のデータの扱いを要件ドキュメントで決め、CLAUDE.section に 1 行で書く
