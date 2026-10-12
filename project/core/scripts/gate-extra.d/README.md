# scripts/gate-extra.d/ — スタック固有の追加検査の置き場所

ここに置いた `<id>.sh` は、PR ゲート（`.github/workflows/pr-gate.yml`）と
マージ後の再検証（`.github/workflows/post-merge-verify.yml`）が `scripts/run-gate-extras.sh` 経由で
**毎回すべて実行する**。1 つ落ちれば PR ゲートが赤くなり、マージゲートで止まる。

**スクリプトを足したら、`.github/gate-extra-checks.txt` に同じ id の行を同じ PR で足すこと。**
片方だけだと集計（`scripts/gate-summary.sh`）が `MISSING` / `UNKNOWN-ID` で落とす。

- 終了コード 0 = 合格 / それ以外 = 不合格。skip したいときも 0 で黙って抜けないこと（理由を出力する）
- 受け取る環境変数: `GATE_CONTEXT`（`pr` / `post-merge`）、`BASE_REF`、`HEAD_SHA`、
  `MERGE_REF`（PR のみ。マージ結果 `refs/pull/N/merge`。取れなかったら空 — 空なら必ず失敗させる）
- 重い検査は期待リストで `deep` にすると、毎マージの再検証では延期され、定期実行と昇格時に走る

仕組みと設計の理由は `docs/agents/commit-identity-and-ci-gate.md` の 2-11。
