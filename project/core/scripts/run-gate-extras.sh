#!/usr/bin/env bash
#
# スタック固有の追加検査（scripts/gate-extra.d/*.sh）を実行して集計する。拡張点。
#
#   使い方: bash scripts/run-gate-extras.sh [--context pr|post-merge] [--deferred]
#
#   - scripts/gate-extra.d/<id>.sh を名前順にすべて実行する（1 つ落ちても残りを走らせる）
#   - 期待リストは .github/gate-extra-checks.txt（書式は .github/pr-gate-checks.txt と同じ
#     `<id> <always|deep> <ラベル>`。id はスクリプトのファイル名から .sh を除いたもの）
#   - 集計は scripts/gate-summary.sh に任せるので、他の検査と同じ規則で落ちる:
#       期待リストにあるのにスクリプトが無い → MISSING（スクリプトを消すだけで検査が消えるのを防ぐ）
#       スクリプトがあるのに期待リストに無い → UNKNOWN-ID（足し忘れを検出）
#   - --deferred: deep の項目は実行せず「延期」とする（post-merge の毎マージ用）
#
#   各スクリプトに渡す環境変数: GATE_CONTEXT（pr / post-merge）と、呼び出し元が設定した
#   BASE_REF / HEAD_SHA / MERGE_REF（PR のみ。マージ結果 refs/pull/N/merge を取れなかったら空）
#
#   終了コード: 0 = 全件通過（または拡張検査が 1 件も無い）/ 1 = 失敗あり / 2 = 設定の誤り
set -euo pipefail

export LC_ALL=C

context="pr"
deferred=0
while [ $# -gt 0 ]; do
  case "$1" in
    --context) shift; context="${1:-}" ;;
    --deferred) deferred=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$context" in pr|post-merge) ;; *) echo "--context は pr / post-merge のどちらか: '$context'" >&2; exit 2 ;; esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
extra_dir="${GATE_EXTRA_DIR:-$repo_root/scripts/gate-extra.d}"
manifest="${GATE_EXTRA_MANIFEST:-$repo_root/.github/gate-extra-checks.txt}"

scripts=()
if [ -d "$extra_dir" ]; then
  while IFS= read -r f; do scripts+=("$f"); done < <(find "$extra_dir" -maxdepth 1 -type f -name '*.sh' | sort)
fi

n_manifest=0
if [ -f "$manifest" ]; then
  n_manifest=$(awk '{ sub(/#.*/, "") } NF { n++ } END { print n+0 }' "$manifest")
fi

if [ "${#scripts[@]}" -eq 0 ] && [ "$n_manifest" -eq 0 ]; then
  echo "拡張検査はありません（scripts/gate-extra.d/ も .github/gate-extra-checks.txt の項目も空）。"
  exit 0
fi
if [ ! -f "$manifest" ]; then
  echo "::error::scripts/gate-extra.d/ にスクリプトがあるのに $manifest がありません。" >&2
  exit 2
fi
if [ "$n_manifest" -eq 0 ]; then
  echo "::error::scripts/gate-extra.d/ のスクリプトが $manifest に載っていません（同じ PR で 1 行ずつ足すこと）:" >&2
  for f in "${scripts[@]}"; do echo "  $(basename "$f" .sh)" >&2; done
  exit 1
fi

deep_ids=$(awk '{ sub(/#.*/, "") } NF >= 2 && $2 == "deep" { print $1 }' "$manifest")

outcomes=()
for f in ${scripts[@]+"${scripts[@]}"}; do
  id="$(basename "$f" .sh)"
  case "$id" in
    ""|*[!A-Za-z0-9_-]*) echo "::error::拡張検査のファイル名に使えない文字があります: $f" >&2; exit 2 ;;
  esac
  if [ "$deferred" -eq 1 ] && printf '%s\n' "$deep_ids" | grep -qxF -- "$id"; then
    echo "· $id … deep のため延期"
    outcomes+=(--outcome "$id=skipped")
    continue
  fi
  echo "::group::拡張検査 $id"
  rc=0
  GATE_CONTEXT="$context" bash "$f" || rc=$?
  echo "::endgroup::"
  if [ "$rc" -eq 0 ]; then
    echo "✓ $id"
    outcomes+=(--outcome "$id=success")
  else
    echo "✗ ${id}（exit ${rc}）"
    outcomes+=(--outcome "$id=failure")
  fi
done

summary_args=("$manifest" --title "拡張検査（${context}）")
[ "$deferred" -eq 1 ] && summary_args+=(--deferred)
bash "$script_dir/gate-summary.sh" "${summary_args[@]}" ${outcomes[@]+"${outcomes[@]}"}
