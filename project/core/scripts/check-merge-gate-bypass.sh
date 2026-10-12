#!/usr/bin/env bash
#
# マージゲートを通さずに dev へマージされた PR を事後に検知して Issue を起票する。
# .github/workflows/post-merge-verify.yml から呼ばれる。
#
#   環境変数: GH_REPO / BRANCH / BEFORE_SHA / AFTER_SHA / RUN_URL
#
# 仕組み: scripts/merge-gate.sh はマージ直前に PR へ
#   <!-- agent-merge-gate verdict=passed sha=<head> pr=<n> -->
# を残す。push で増えたコミットに紐づく PR を引き、このマーカーが無ければ「迂回」と判定する。
#
# 限界（監査であって強制ではない）:
#   * 止められない（マージは終わっている）。できるのは記録に残すことだけ
#   * マーカーは PR にコメントできれば誰でも作れる（防げるのは通し忘れという事故だけ）
#   * ユーザーが UI から意図的にマージした場合も検知される（その場合は Issue を close してよい）
#   * このジョブは落とさない（赤くないのに CI を赤くすると、本当に赤いときの信号が薄れる）
set -euo pipefail

# shellcheck source=scripts/lib/report-issue.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/report-issue.sh"

repo="${GH_REPO:?GH_REPO が必要です}"
branch="${BRANCH:?BRANCH が必要です}"
before="${BEFORE_SHA:-}"
after="${AFTER_SHA:-}"
run_url="${RUN_URL:-}"

# PR① のマージ先は dev だけ。staging / main はユーザーがマージするのが正しいので対象外。
if [ "$branch" != "dev" ]; then
  echo "branch=$branch はマージゲートの対象外（PR② / PR③ はユーザーがマージする）。何もしません。"
  exit 0
fi

zero="0000000000000000000000000000000000000000"
if [ -z "$before" ] || [ "$before" = "$zero" ] || [ -z "$after" ]; then
  echo "push の前後 SHA が取れないため判定しません（before=$before after=${after}）。"
  exit 0
fi

commits="$(gh api "repos/$repo/compare/$before...$after" -q '.commits[].sha' 2>/dev/null || true)"
if [ -z "$commits" ]; then
  echo "新しいコミットがありません。"
  exit 0
fi

bypassed=""
for sha in $commits; do
  pr="$(gh api "repos/$repo/commits/$sha/pulls" \
        -q '.[] | select(.merged_at != null) | .number' 2>/dev/null | head -1 || true)"
  if [ -z "$pr" ]; then
    bypassed="$bypassed
- \`$sha\` … **PR に紐づかない直接 push**（禁止されている）"
    continue
  fi
  if gh api --paginate "repos/$repo/issues/$pr/comments?per_page=100" -q '.[].body' 2>/dev/null \
       | grep -q '<!-- agent-merge-gate verdict=passed'; then
    echo "PR #$pr … マージゲートのマーカーあり"
  else
    bypassed="$bypassed
- #$pr … **マージゲートのマーカーが無い**（\`gh pr merge\` で直接マージされた可能性）"
  fi
done

if [ -z "$bypassed" ]; then
  echo "OK: 迂回は検出されませんでした。"
  exit 0
fi

echo "迂回を検出しました:$bypassed"

title="[Ops] マージゲートを通さずに dev にマージされた変更がある"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT INT TERM

cat >"$body_file" <<EOF
\`dev\` への push（\`${before:0:8}\` → \`${after:0:8}\`）に、
**\`.github/workflows/merge-gate.yml\` を通していない変更**が含まれています。
$bypassed

- 実行ログ: ${run_url}

## なぜ気にするのか

branch protection が止めるのは required に挙げたチェックの色だけで、
skip されたジョブ・1 度も走らなかったジョブ・base drift・評決・必須リスト外の赤は止めません。
それらを見ているのはマージゲートだけで、\`gh pr merge\` の直叩きで迂回できます。

## やること

- 意図的なマージ（ユーザーが UI から実行した等）なら、この Issue を close する
- エージェントが手順を飛ばした場合は、Orchestrator の定義（マージはマージゲート経由のみ）を再確認する
- マージされた変更が実際に緑だったかは、同じ run の verify ジョブの結果を見る

詳細と限界: \`docs/agents/commit-identity-and-ci-gate.md\` の 2-5 / 2-6

<!-- agent-merge-gate-bypass branch=dev -->
EOF

# 起票に失敗してもジョブは落とさない（上の限界を参照）。失敗はログに残す。
report_issue "$repo" "$title" "$body_file" Should || echo "::warning::迂回の Issue を起票できませんでした。"
exit 0
