---
name: figma-docs-first
description: Figma の使い方・機能・運用設計の質問に答える前に、公式ヘルプ(help.figma.com)とリリースノートで「ネイティブ機能で解決できないか」を必ず確認するスキル。Figma 上の運用ルール・ステータス管理・ハンドオフ・命名規約などを提案しそうになったとき、Figma で○○はできるかと聞かれたとき、Figma を使うワークフローを設計するときに必ず使う。
---

# figma-docs-first — 規約を発明する前にネイティブ機能を引く

## なぜこのスキルがあるか(実例)

2026-10-06、UI 確定フローの設計で「確定したフレームは『✅ 確定』セクションへ移動する」という
**擬似ステータス規約を発明**してしまった。Figma には **Mark as ready for dev**(Dev Mode の
ネイティブなステータス管理・差分追跡・REST API の `devStatus`)が既にあり、運用者の指摘で
差し替えになった。知識カットオフ以降も Figma の機能追加は速い。**記憶で答えない。**

## 手順

1. **どの製品圏の話かを判定する**(Figma は複合製品。探す場所を間違えると見つからない):

   | 製品 | 守備範囲 |
   |---|---|
   | Figma Design | デザイン・プロトタイプ・ライブラリ・Variables・branching |
   | Dev Mode | 実装ハンドオフ・ready for dev・Code Connect・dev resources |
   | Figma Make / Weave / Motion / AI | 生成系(コード生成・画像/動画・アニメーション) |
   | FigJam / Slides / Draw / Sites / Buzz | ホワイトボード・スライド・ベクター・サイト・アセット量産 |
   | Developer docs(figma.com/developers) | REST API・プラグイン API・自動化可否 |

2. **二段検索**(最大の失敗モードは「自分の語彙と Figma の正式名称の不一致」):
   - 一段目: **一般 Web 検索で正式な機能名を発見する**。`Figma <やりたいことを平易な英語で> feature`
     等。コミュニティ記事・ブログは「ニーズ → 機能名」の翻訳辞書として使う
   - 二段目: 発見した機能名で **help.figma.com を引いて仕様・プラン条件を検証**する
     (`site:help.figma.com <機能名>`)。新しすぎてヘルプに無い場合は
     `figma.com/release-notes`(What's New)と公式ブログで確認
3. **ネイティブ機能を第一候補にする**。独自規約(命名・セクション移動・絵文字マーク等)を
   提案してよいのは「該当するネイティブ機能が存在しない」と確認できたときだけで、
   その場合も回答に「ネイティブには無いことを確認済み」と明記する。
   **検索が不調で有無を確認しきれなかったときは、規約を発明せず「確認しきれなかった」と宣言する**
4. **プラン条件を必ず確認する**。機能がどのプランから使えるか(Starter / Professional /
   Organization / Enterprise)をヘルプページで確認して答える
5. **自動化の観点を添える**: フローに組み込む機能は `figma.com/developers` で API から
   読み書きできるか(例: `devStatus`・dev resources・Variables)も確認する
6. 回答には**機能の正式名称とヘルプページの URL** を添える

## 利用者の前提

- **Figma のプランと DS の状態は、プロジェクトの CLAUDE.md（`ui-figma-ds` 部品の節）かメモリに書かれたものを使う。**
  書かれていなければ運用者に確認する（プランで使える機能が大きく変わるため、推測で答えない）
- DS のライブラリ・Code Connect・Variables の運用は、プロジェクトの `docs/ui-confirmation-flow.md` に従う

## 適用対象外

- Figma MCP プラグインのツール操作手順(それは figma プラグインの各スキルが正。
  `figma-use` 等を先にロードするルールはそのまま)
- 一般的なデザイン論(このスキルは「Figma に機能があるか」の確認専用)
