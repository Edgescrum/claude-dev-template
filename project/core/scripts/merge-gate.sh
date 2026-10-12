#!/usr/bin/env bash
#
# PR① を dev にマージしてよいかを、PR の外から機械的に検証する。
#
#   使い方:
#     bash scripts/merge-gate.sh <PR番号>                 検証のみ（既定）
#     bash scripts/merge-gate.sh <PR番号> --merge         全ゲート通過時に squash マージする
#     bash scripts/merge-gate.sh <PR番号> --verdict-only  評決マーカーが well-formed か
#     bash scripts/merge-gate.sh <PR番号> --verdict-only --expect blocked
#                                                        上記 + 評決が期待どおりか
#     bash scripts/merge-gate.sh <PR番号> --repo owner/repo
#
#   リポジトリは --repo → GH_REPO → GITHUB_REPOSITORY → `gh repo view` の順で解決する。
#   Orchestrator が blocked を受理するときは必ず `--expect blocked` を付ける
#   （付けないと verdict=approved のマーカーでも exit 0 になる）。
#
#   終了コード:
#     0  全ゲート通過（--merge を付けていればマージ済み）
#     1  ゲート不合格 — マージしてはいけない（差し戻し先は Generator）
#     2  判定不能（API が stale・使い方の誤り・権限不足など）— マージしてはいけない（待つか人間）
#
# なぜ必要か: branch protection が見るのは required に挙げたチェックの色だけで、
#   skip の pass 扱い / 走らなかったジョブ / base drift / 評決 / 必須リスト外の赤 を見ない。
#   手順は守らなくても止まらないので、判定をコードに落とし、検証とマージを不可分にする。
#
# 限界（これは「事故」を防ぐ仕組みで「悪意」は防がない）:
#   1. `gh pr merge` を直接叩けば迂回できる（post-merge-verify.yml が事後検知する）
#   2. ラベルも評決マーカーも同じアカウントで誰でも書ける（偽装は防げない）
#   3. CI ジョブが意味のある検査をしているかまでは保証しない
#   4. このスクリプト自身が同じ PR で緩められうる（レビューで差分を必ず見ること）
# 詳細は docs/agents/commit-identity-and-ci-gate.md の 2-6。
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/gate-common.sh
. "$script_dir/lib/gate-common.sh"

pr=""
repo_arg=""
do_merge=0
verdict_only=0
expect_verdict=""
# base の許可リストは dev だけ。自動マージが staging / main に届く経路をコードのレベルで塞ぐ。
allowed_bases="dev"

while [ $# -gt 0 ]; do
  case "$1" in
    --merge) do_merge=1 ;;
    --verdict-only) verdict_only=1 ;;
    --expect) shift; expect_verdict="${1:-}" ;;
    --repo) shift; repo_arg="${1:-}" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) pr="$1" ;;
  esac
  shift
done

if [ -z "$pr" ] || ! printf '%s' "$pr" | grep -qE '^[0-9]+$'; then
  echo "usage: $0 <PR番号> [--merge] [--verdict-only [--expect <verdict>]] [--repo owner/repo]" >&2
  exit 2
fi
case "$expect_verdict" in
  ""|approved|changes-requested|blocked) ;;
  *) echo "--expect には approved / changes-requested / blocked のいずれかを指定してください: '$expect_verdict'" >&2; exit 2 ;;
esac
if [ -n "$expect_verdict" ] && [ "$verdict_only" -eq 0 ]; then
  echo "--expect は --verdict-only と一緒に使ってください。" >&2
  exit 2
fi

if [ -n "${GATE_FIXTURE_DIR:-}" ]; then
  repo="${repo_arg:-${GH_REPO:-fixture/repo}}"
else
  repo="$(gate_resolve_repo "$repo_arg")" || exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate.XXXXXX")"
case "$tmp" in "" | "/" | "/*") echo "mktemp に失敗しました" >&2; exit 2 ;; esac
trap 'rm -rf "$tmp"' EXIT INT TERM

fail_count=0
ng() { printf '  ✗ %s\n' "$1"; shift; for l in "$@"; do printf '      %s\n' "$l"; done; fail_count=$((fail_count + 1)); }
ok() { printf '  ✓ %s\n' "$*"; }

# 評決マーカー（固定の名前。プロジェクト名を埋めない）
marker_re='<!-- agent-review verdict=(approved|changes-requested|blocked) sha=[0-9a-f]{40} pr=[0-9]+ -->'

echo "==================================================================="
echo " マージゲート: $repo PR #$pr"
echo "==================================================================="

# ---------------------------------------------------------------------------
# [1] PR のメタ情報
# ---------------------------------------------------------------------------
fx=""; rc=0; gate_fx pr.json fx || rc=$?
[ "$rc" -eq 2 ] && exit 2
if [ "$rc" -eq 0 ]; then
  cp "$fx" "$tmp/pr.json"
else
  gh api "repos/$repo/pulls/$pr" >"$tmp/pr.json" || { echo "NG: PR #$pr を取得できません。" >&2; exit 2; }
fi

state=$(jq -r '.state' <"$tmp/pr.json")
draft=$(jq -r '.draft' <"$tmp/pr.json")
base_ref=$(jq -r '.base.ref' <"$tmp/pr.json")
mergeable_state=$(jq -r '.mergeable_state // "unknown"' <"$tmp/pr.json")
labels=$(jq -r '.labels[].name' <"$tmp/pr.json")

echo ""
echo "[1] PR のメタ情報"
if [ "$state" != "open" ]; then ng "PR が open ではありません (state=$state)"; else ok "open"; fi
if [ "$draft" = "true" ]; then ng "draft PR です"; else ok "draft ではない"; fi

base_allowed=0
for b in $allowed_bases; do [ "$base_ref" = "$b" ] && base_allowed=1; done
if [ "$base_allowed" -eq 1 ]; then
  ok "base = ${base_ref}（許可されたマージ先）"
else
  ng "base = $base_ref はこのゲートの対象外です（許可: ${allowed_bases}）" \
     "PR②（dev → staging）はユーザー承認、PR③（staging → main）はユーザー専権。" \
     "自動マージが staging / main に届く経路は意図的に塞いであります。"
fi

# mergeable は「CI が通っている」ではない。ここで見るのはコンフリクトの有無だけ（CI は [5]）。
case "$mergeable_state" in
  dirty|conflicting) ng "コンフリクトしています (mergeable_state=$mergeable_state)" ;;
  *) ok "コンフリクトなし (mergeable_state=$mergeable_state)" ;;
esac

# ---------------------------------------------------------------------------
# [2] head SHA を 2 経路で確定する
# ---------------------------------------------------------------------------
echo ""
echo "[2] head SHA の確定（REST と git ls-remote の突き合わせ）"
if ! head_sha=$(gate_resolve_head_sha "$pr" "$repo"); then
  echo ""
  echo "NG: head SHA を確定できませんでした。判定を中止します。"
  exit 2
fi
ok "head = ${head_sha}（REST と git ls-remote が一致）"

# ---------------------------------------------------------------------------
# [3] base drift
# ---------------------------------------------------------------------------
# CI は head.sha を検査しており、マージ結果は検査していない。2 つの PR が個別に緑でも
# 統合後に赤くなりうる。また base を取り込めば最新のワークフローで CI が回り直すので、
# 「PR の最後の push より後に入った必須ジョブが 1 度も走っていない」窓も閉じる。
# 免除（gate_base_drift_exempt）は base の新差分が CI の結果を動かしえない場合だけ。
echo ""
echo "[3] base drift（$base_ref を取り込んでいるか）"
fx=""; rc=0; gate_fx compare.json fx || rc=$?
[ "$rc" -eq 2 ] && exit 2
if [ "$rc" -eq 0 ]; then
  cp "$fx" "$tmp/compare.json"
else
  gh api "repos/$repo/compare/$base_ref...$head_sha" >"$tmp/compare.json" 2>/dev/null || : >"$tmp/compare.json"
fi
behind=$(jq -r '.behind_by // ""' <"$tmp/compare.json" 2>/dev/null || echo "")
drift_merge_base=$(jq -r '.merge_base_commit.sha // ""' <"$tmp/compare.json" 2>/dev/null || echo "")
if [ -z "$behind" ]; then
  ng "$base_ref と head を比較できませんでした（判定不能）"
elif [ "$behind" -eq 0 ]; then
  ok "$base_ref を完全に取り込んでいる（behind_by=0）"
elif gate_base_drift_exempt "$repo" "$drift_merge_base" "$base_ref" >"$tmp/drift.txt" 2>&1; then
  ok "$base_ref が $behind コミット進んでいますが、免除します"
  sed 's/^/      /' "$tmp/drift.txt"
  printf '      %s\n' "免除できるのは ${GATE_DRIFT_SAFE_DESC} だけです。"
else
  ng "$base_ref が $behind コミット進んでいます（behind_by=${behind}）" \
     "CI は head.sha しか検査しないため、マージ結果は一度も検証されていません。" \
     "免除の判定結果:"
  sed 's/^/      /' "$tmp/drift.txt"
  printf '      %s\n' \
    "取り込んでから再判定してください:" \
    "  git fetch origin $base_ref && git merge origin/$base_ref && git push"
fi

# ---------------------------------------------------------------------------
# [4] Evaluator の評決 / docs-only
# ---------------------------------------------------------------------------
# 同一アカウントの self-review は GitHub に拒否されるので reviewDecision は常に null。
# 「Approve された」を不在ではなく存在で表すため、
#   (a) `approved` ラベルがあること
#   (b) 最新の評決マーカーが verdict=approved かつ sha が現在の head と一致すること
# を要求する。(b) があると Approve 後に push されたコミットが素通りしない。
echo ""
echo "[4] Evaluator の評決 / docs-only の検証"

fx=""; rc=0; gate_fx comments.tsv fx || rc=$?
[ "$rc" -eq 2 ] && exit 2
if [ "$rc" -eq 0 ]; then
  cp "$fx" "$tmp/comments.tsv"
else
  gh api --paginate "repos/$repo/issues/$pr/comments?per_page=100" \
    -q '.[] | [(.id|tostring), .created_at, .body] | @tsv' >"$tmp/comments.tsv" 2>/dev/null || : >"$tmp/comments.tsv"
fi

# 最後に投稿されたマーカーが「現在の評決」（コメントは id 昇順で返る）。
last_line=$(grep -nE "$marker_re" "$tmp/comments.tsv" | tail -1 | cut -d: -f1 || true)
verdict=""; verdict_sha=""; verdict_pr=""
if [ -n "$last_line" ]; then
  marker=$(sed -n "${last_line}p" "$tmp/comments.tsv" | grep -oE "$marker_re" | tail -1)
  verdict=$(printf '%s' "$marker" | sed -E 's/.*verdict=([a-z-]+).*/\1/')
  verdict_sha=$(printf '%s' "$marker" | sed -E 's/.*sha=([0-9a-f]{40}).*/\1/')
  verdict_pr=$(printf '%s' "$marker" | sed -E 's/.*pr=([0-9]+).*/\1/')
  sed -n "${last_line}p" "$tmp/comments.tsv" | cut -f3- | sed 's/\\n/\n/g' >"$tmp/verdict-body.txt"
fi

if [ "$verdict_only" -eq 1 ]; then
  if [ -z "$verdict" ]; then
    echo "  ✗ 評決マーカーが 1 件もありません。"
    echo "      Evaluator はレビュー本文に次の 1 行を含めること:"
    echo "        <!-- agent-review verdict=approved|changes-requested|blocked sha=<40桁> pr=$pr -->"
    exit 1
  fi
  echo "  verdict=$verdict sha=$verdict_sha pr=$verdict_pr"
  if [ "$verdict_pr" != "$pr" ]; then
    echo "  ✗ マーカーの pr=$verdict_pr が対象 PR #$pr と一致しません（他 PR のコピペ）。"
    exit 1
  fi
  if [ -n "$expect_verdict" ] && [ "$verdict" != "$expect_verdict" ]; then
    echo "  ✗ 期待した評決は $expect_verdict ですが、最新の評決は $verdict です。"
    exit 1
  fi
  if [ "$verdict" = "blocked" ]; then
    # blocked は「試さずに諦めた」経路になりやすいので、証跡の形を機械で確かめる。
    # 限界: 証跡は自己申告。潰せるのは「何も書かずに blocked を返す」形だけ。
    ev="$tmp/evidence.txt"
    awk '/<!-- agent-blocked-evidence/{f=1;next} /-->/{f=0} f' "$tmp/verdict-body.txt" >"$ev"
    if [ ! -s "$ev" ]; then
      echo "  ✗ blocked なのに <!-- agent-blocked-evidence ... --> ブロックがありません。"
      exit 1
    fi
    reason=$(grep -oE '^reason=[a-z0-9-]+' "$ev" | head -1 | cut -d= -f2 || true)
    n_ev=$(grep -c '^evidence=' "$ev" || true)
    if [ -z "$reason" ]; then echo "  ✗ 証跡に reason= がありません。"; exit 1; fi
    if [ "${n_ev:-0}" -lt 1 ]; then echo "  ✗ 証跡に evidence= が 1 件もありません。"; exit 1; fi
    echo "  ✓ blocked の証跡が形式を満たしています（reason=${reason}）"
  fi
  exit 0
fi

has_label() { printf '%s\n' "$labels" | grep -qxF -- "$1"; }

# docs-only: ラベルは申告。ゲートが実ファイル一覧を検証する。
# 申告が実ファイルと矛盾したら approved が揃っていても止める（ラベルを無意味にしないため）。
docs_only_ok=0
changed_files=""
if has_label docs-only; then
  echo "  docs-only ラベルあり — 変更ファイルを取得して検証します（ラベルは申告にすぎない）"
  fx=""; rc=0; gate_fx files.tsv fx || rc=$?
  [ "$rc" -eq 2 ] && exit 2
  if [ "$rc" -eq 0 ]; then
    cp "$fx" "$tmp/files.tsv"
  elif ! gate_fetch_pr_files "$pr" "$repo" >"$tmp/files.tsv"; then
    echo ""
    echo "NG: PR #$pr の変更ファイル一覧を取得できませんでした。docs-only の判定を中止します。"
    exit 2
  fi
  changed_files=$(jq -r '.changed_files // ""' <"$tmp/pr.json")
  if docs_problems=$(gate_docs_only_verify "$tmp/files.tsv" "$changed_files"); then
    docs_only_ok=1
    ok "docs-only: 変更 ${changed_files} 件すべてが許可リスト内（${GATE_DOCS_ONLY_ALLOWLIST_DESC}）"
  else
    ng "docs-only ラベルが付いていますが、ゲートの検証に通りませんでした"
    printf '%s\n' "$docs_problems" | sed 's/^/      /'
    printf '      %s\n' \
      "許可リスト: ${GATE_DOCS_ONLY_ALLOWLIST_DESC}" \
      "この PR は通常どおり Generator / Evaluator のフローが必要です。"
  fi
fi

if [ "$docs_only_ok" -eq 1 ]; then
  ok "docs-only 経路: approved ラベルと評決マーカーは要求しません"
elif has_label approved; then
  ok "ラベル approved あり"
else
  ng "ラベル approved がありません" \
     "「ラベルが無い」を Approve と読んではいけません（未レビューの PR と区別できない）。"
fi
for bad in review-ready changes-requested blocked; do
  has_label "$bad" && ng "ラベル $bad が付いたままです"
done

if [ "$docs_only_ok" -eq 1 ]; then
  # マーカーが無いのが通常形。ただしあるなら読む（未解決の差し戻しを docs-only で持ち越させない）。
  if [ -n "$verdict" ] && [ "$verdict" != "approved" ]; then
    ng "docs-only ですが、未解決の評決が残っています (verdict=$verdict)" \
       "評決を出し直すか、その評決が対象にしていた変更が残っていないことを確認してください。"
  fi
elif [ -z "$verdict" ]; then
  ng "評決マーカーを含むレビューコメントがありません" \
     "Evaluator はレビュー本文に次の 1 行を含めること:" \
     "  <!-- agent-review verdict=approved sha=<検証した head の 40 桁 SHA> pr=$pr -->"
elif [ "$verdict" != "approved" ]; then
  ng "最新の評決が approved ではありません (verdict=$verdict)"
elif [ "$verdict_pr" != "$pr" ]; then
  ng "マーカーの pr=$verdict_pr が対象 PR #$pr と一致しません（他 PR からのコピペ）"
elif [ "$verdict_sha" != "$head_sha" ]; then
  ng "レビュー対象の SHA が現在の head と違います" \
     "レビューされた SHA : $verdict_sha" \
     "現在の head        : $head_sha" \
     "Approve の後に push されたコミットは未レビューです。再レビューしてください。"
else
  ok "評決 approved / 対象 SHA が現在の head と一致"
fi

# ---------------------------------------------------------------------------
# [5] 必須 CI ジョブ + 赤いチェックが 1 つも無いこと
# ---------------------------------------------------------------------------
echo ""
echo "[5] 必須 CI ジョブ（存在 + skip ポリシー + 決着 + 緑）"
set +e
REQUIRED_CHECKS_HEAD_SHA="$head_sha" \
  bash "$script_dir/check-required-jobs.sh" "$pr" "$repo" --conclusive 2>&1 | sed 's/^/  /'
checks_rc=${PIPESTATUS[0]}
set -e
if [ "$checks_rc" -eq 0 ]; then
  ok "必須 CI ジョブがすべて存在し、決着して緑"
else
  ng "必須 CI ジョブの検査に失敗しました（上のログを参照）"
fi

# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
if [ "$fail_count" -ne 0 ]; then
  echo " 判定: NG（$fail_count 件）— マージしません"
  echo "==================================================================="
  exit 1
fi
echo " 判定: OK — 全ゲート通過"
echo "==================================================================="

if [ "$do_merge" -eq 0 ]; then
  echo "（--merge が付いていないのでマージはしません）"
  exit 0
fi

# マージした事実を PR に残す。post-merge-verify.yml がこのマーカーで迂回マージを事後検知する。
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$repo}/actions/runs/${GITHUB_RUN_ID:-local}"
if [ "$docs_only_ok" -eq 1 ]; then
  route="docs-only（ゲートが変更 ${changed_files} 件を検証。Evaluator の評決は要求していない）"
else
  route="Evaluator の評決（approved ラベル + head 一致の評決マーカー）"
fi
gh pr comment "$pr" --repo "$repo" --body "$(cat <<EOF
<!-- agent-merge-gate verdict=passed sha=$head_sha pr=$pr -->
\`scripts/merge-gate.sh\` の全ゲートを通過したのでマージします。

- head: \`$head_sha\`
- base: \`$base_ref\`
- 承認の経路: $route
- 実行: $run_url

このゲートの限界は \`docs/agents/commit-identity-and-ci-gate.md\` の 2-6 を参照。
EOF
)"

echo "マージします: PR #$pr → $base_ref"
gh pr merge "$pr" --repo "$repo" --squash --delete-branch
echo "マージしました。"
