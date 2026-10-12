# スタック部品: ui-figma-ds（PeCo 由来）

フロントの新規画面・レイアウト変更を、実装前に Figma（+ デザインシステム）で確定させる運用。

## 何を扱うか

- UI 確定フロー（grill → 参照収集 → 画像で発散 → 運用者の選定 → DS 当てはめで Figma 化 → 乖離裁定 → 状態チェックリスト →
  Mark as ready for dev → フロント Issue）
- Mobbin による参照収集（動線と UI 要素。画像は画像生成に渡さない・最低 1 案は参照なし・`mobbin_url` で引用）
- DS 先行原則と `ds-debt` ラベル
- Evaluator の 4 点照合と「視覚メモ」
- （任意）シェルの決定表
- SaaS のネイティブ機能を先に確かめる規則（Figma はユーザーレベルのスキル `figma-docs-first`）

## いつ選ぶか

- 画面のあるプロダクトで、Figma（Dev Mode が使えるプラン）とデザインシステム（コンポーネントライブラリ）を持つとき
- DS がまだ無い場合も選べる。その場合は DS 先行原則と 4 点照合の 1・4 を「DS ができてから有効」として扱う

## ファイル

| パス（プロジェクト内） | 中身 |
|---|---|
| `CLAUDE.section.md` | CLAUDE.md の末尾に「## スタック: ui-figma-ds」として追記する節 |
| `docs/ui-confirmation-flow.md` | UI 確定フローの唯一の置き場所（しきい値・フロー・状態・DS 先行・Figma 運用・照合・Mobbin・シェル） |
| `.claude/skills/design-variants/SKILL.md` | 発散〜翻訳を実行するプロジェクトスキル |

## 部品固有の置換変数

`/new-project` がこの部品をコピーするときに置き換える（CONVENTIONS.md の共通の置換変数に加えて）。
値が未定なら置換せずに残し、`docs/bootstrap.md` の「残っている置換変数」に載せる。

| 変数 | 意味 | 使われる場所 |
|---|---|---|
| `{{FIGMA_SCREEN_FILE_KEY}}` | 画面モック専用ファイル（Screen）の file key | `CLAUDE.section.md` / `.claude/skills/design-variants/SKILL.md` |
| `{{FIGMA_LIBRARY_FILE_KEY}}` | DS ライブラリの file key | `CLAUDE.section.md` / `.claude/skills/design-variants/SKILL.md` |

## CI に足すもの

拡張点 `scripts/gate-extra.d/*.sh` には何も足さない。フロント Issue の「Figma 宣言」の妥当性は Evaluator が検証する。
シェルを使うなら、「ページが `<main>`・外枠の余白・幅・ヘッダーを自分で書かない」をプロジェクトの lint / テストで機械的に落とす（標本を添える）。

## 初期化でやること（運用者の作業を含む）

- Figma に Screen ファイルを作り、DS ライブラリをリンクする（file key を上の 2 変数に入れる）
- DS のカタログ URL・画像生成の共通コンテキストを CLAUDE.section に記入する
- 画像生成の API キーをリポジトリ外のローカル env ファイルに置く（無ければ経路 B の自由描画で代替できる）
- Mobbin を使うなら Claude のコネクタを連携し、**連携後に新しいセッションを始める**
- `ds-debt` の定期解消ループ（週 1 のスケジュール実行）を、最初の負債が出た時点で登録する
