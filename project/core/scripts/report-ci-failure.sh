#!/usr/bin/env bash
#
# マージ後の長寿命ブランチが赤かったときに Issue を起票する（同じブランチの未解決 Issue があればコメント）。
# .github/workflows/post-merge-verify.yml から呼ばれる。
#
#   環境変数: GH_REPO / BRANCH / FAILED / RUN_URL
set -euo pipefail

# shellcheck source=scripts/lib/report-issue.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/report-issue.sh"

repo="${GH_REPO:?GH_REPO が必要です}"
branch="${BRANCH:?BRANCH が必要です}"
failed="${FAILED:-（不明）}"
run_url="${RUN_URL:-}"

title="[CI] マージ後の ${branch} が赤い"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT INT TERM

cat >"$body_file" <<EOF
\`${branch}\` にマージされた状態で、**マージ後の再検証が失敗しました**
（\`.github/workflows/post-merge-verify.yml\`）。

- 失敗したゲート: **${failed}**
- 実行ログ: ${run_url}

## 考えられる原因

1. **マージゲートを迂回した**（\`gh pr merge\` の直叩き）。ゲートを通していれば赤い PR はマージされない
2. **base drift。** PR の CI は head.sha を検査しており、2 つの PR が個別に緑でもマージ後に赤くなりうる
3. **その PR では走っていないジョブがあった。** PR の最後の push より後に入ったワークフローはその PR では走らない
4. **延期していた deep 検査（test / build など）が、定期実行・昇格で初めて走って落ちた**

## やること

- \`${branch}\` を赤いまま放置しない（後続の PR が全部この赤を引き継ぐ）
- 原因の PR を特定し、**修正 PR① を dev から切って**直す（直接 push は禁止）
- 直ったらこの Issue を close する

<!-- agent-post-merge-verify branch=${branch} -->
EOF

report_issue "$repo" "$title" "$body_file" Must
