# スタック部品: line-liff（PeCo 由来）

LINE 公式アカウントを入口に、LIFF・LINE ログイン・Messaging API を使うプロジェクト向けの規則と教訓。

## 何を扱うか

- LIFF の認証（PKCE の verifier がアプリ内ブラウザで失われる問題への対策・`redirectUri` のサニタイズ・
  失敗時の着地・callback の冪等化・本番で常設するクライアント診断）
- ログインの位置（「先にログイン」を既定にする理由）・友だち追加オプション・スコープ
- Messaging API の料金構造（応答だけ無料）・追加購入できないプランで上限に達すると止まること・送信枠の監視とブレーカー
- 事業者側への通知を既定で日次のまとめにし、リアルタイムは opt-in + まとめ + 上限にする方針
- Flex Message の構成はプロジェクトの要件が規約であること
- webhook の署名検証と冪等処理

## いつ選ぶか

- 利用者の入口が LINE（公式アカウント・LIFF）で、認証を LINE ログインで行うとき
- LINE で通知（push）を送るとき（LIFF を使わず Messaging API だけでも選べる。その場合は認証の節を外す）

## ファイル

| パス（プロジェクト内） | 中身 |
|---|---|
| `CLAUDE.section.md` | CLAUDE.md の末尾に「## スタック: line-liff」として追記する節 |
| `docs/line-liff.md` | 認証の対策・送信枠・通知方針・Flex の規約の詳説（唯一の置き場所） |

## CI に足すもの

拡張点 `scripts/gate-extra.d/*.sh` には何も足さない。`liff.login()` の直接呼び出しの禁止は、
プロジェクトの lint 設定（`no-restricted-syntax` 等）に入れ、標本（直接呼び出しを書いたファイルが lint で落ちること）を添える。

## 初期化でやること

- LINE ログイン / Messaging API のチャネルを本番と stg で分けて作る（運用者の作業）
- Messaging API のプラン・月の上限・**上限を超えたら何が起きるか**を公式で確かめ、`docs/bootstrap.md` の上限表に書く
- 友だち追加オプション（normal / aggressive）を決めて ADR に残す
- 送信枠の日次取得と閾値警告を、運用基盤（`observability` 部品を採用していればその通知チャンネル）に繋ぐ
