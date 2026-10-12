#!/usr/bin/env bash
#
# PR の必須 CI ジョブを検査する。
#
#   使い方:
#     scripts/check-required-jobs.sh <PR番号> [<owner/repo>]              存在 + skip ポリシー
#     scripts/check-required-jobs.sh <PR番号> [<owner/repo>] --conclusive 上記 + 全件が決着して緑
#
#   環境変数:
#     REQUIRED_CHECKS_FILE        期待リスト（既定: .github/required-checks.txt）
#     REQUIRED_CHECKS_ACTUAL_FILE 実際のチェック "name<TAB>bucket" 一覧（指定すると gh を呼ばない・自己テスト用）
#     REQUIRED_CHECKS_HEAD_SHA    head SHA を外から与える（PR イベントの head.sha を渡す）
#     REQUIRED_CHECKS_TIMEOUT     ジョブ登録・完了待ちの上限秒（既定: 300）
#     REQUIRED_CHECKS_INTERVAL    再試行の間隔秒（既定: 15）
#     GATE_FIXTURE_DIR            自己テスト用の fixture ディレクトリ
#
#   終了コード: 0 = OK / 1 = 問題あり / 2 = 判定不能
#
# 何を守るか:
#   (1) 存在 — PR の最後の push より後に dev へ入ったワークフローはその PR では走らない。
#       走らないジョブは「赤くない」のではなく「存在しない」ので `gh pr checks` は exit 0 を返す。
#   (2) skip — `if:` で skip されたジョブも名前つきで一覧に出る。GitHub の required checks も
#       skip を pass 扱いするので、ここで bucket を見るしかない。
#   (3) 同じ SHA — GraphQL の rollup は push 直後に 1 つ前のコミットの緑を返すことがあるため、
#       head SHA に対して REST を直接引く。
# 限界: このジョブ自身も (1) と同じ理由で走らないことがある。
#   塞ぐのは merge-gate.sh（マージ直前に PR の外から同じ検査をやり直し、base drift 0 を要求する）。
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/gate-common.sh
. "$script_dir/lib/gate-common.sh"

pr=""
repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
conclusive=0
for arg in "$@"; do
  case "$arg" in
    --conclusive) conclusive=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) if [ -z "$pr" ]; then pr="$arg"; else repo="$arg"; fi ;;
  esac
done

if [ -z "$pr" ]; then
  echo "usage: $0 <PR番号> [<owner/repo>] [--conclusive]" >&2
  exit 2
fi
if [ -z "${REQUIRED_CHECKS_ACTUAL_FILE:-}" ] && [ -z "${GATE_FIXTURE_DIR:-}" ]; then
  repo="$(gate_resolve_repo "$repo")" || exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
expected_file="${REQUIRED_CHECKS_FILE:-.github/required-checks.txt}"
case "$expected_file" in
  /*) ;;
  *) expected_file="$repo_root/$expected_file" ;;
esac
if [ ! -f "$expected_file" ]; then
  echo "NG: 期待リスト $expected_file が見つかりません。" >&2
  exit 2
fi

# ジョブの登録には数十秒〜数分のラグがある。短すぎると「まだ作られていない」を欠落と誤検知する。
timeout="${REQUIRED_CHECKS_TIMEOUT:-300}"
interval="${REQUIRED_CHECKS_INTERVAL:-15}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/required-checks.XXXXXX")"
case "$tmp" in "" | "/" | "/*") echo "mktemp に失敗しました" >&2; exit 2 ;; esac
trap 'rm -rf "$tmp"' EXIT INT TERM

expected="$tmp/expected.tsv"
actual="$tmp/actual.tsv"
problems="$tmp/problems.txt"
self_jobs="$tmp/self-jobs.txt"

gate_read_expected "$expected_file" >"$expected"
gate_self_job_names "${MERGE_GATE_WORKFLOW:-$repo_root/.github/workflows/merge-gate.yml}" >"$self_jobs" || : >"$self_jobs"

if [ ! -s "$expected" ]; then
  # 期待リストが空だと「全部揃っている」で緑になり空振りする。
  echo "NG: 期待リスト $expected_file が空です（このチェックが空振りします）。" >&2
  exit 2
fi

head_sha="${REQUIRED_CHECKS_HEAD_SHA:-}"

fetch_actual() {
  if [ -n "${REQUIRED_CHECKS_ACTUAL_FILE:-}" ]; then
    # bucket 欠落を「0 件のチェック」に落とさない（本当の欠陥が別の理由の赤に隠れる）。
    awk -F'\t' '
      { sub(/\r$/, "") }
      NF < 2 || $2 == "" { print "NG: REQUIRED_CHECKS_ACTUAL_FILE に bucket がありません: [" $0 "]" > "/dev/stderr"; bad=1; next }
      { print $1 "\t" $2 }
      END { if (bad) exit 2 }
    ' "$REQUIRED_CHECKS_ACTUAL_FILE" >"$actual" || {
      echo "NG: REQUIRED_CHECKS_ACTUAL_FILE の書式が不正です（name<TAB>bucket が必要）。" >&2
      exit 2
    }
    return 0
  fi
  if [ -z "$head_sha" ]; then
    head_sha="$(gate_resolve_head_sha "$pr" "$repo")" || return 2
    echo "head SHA = $head_sha"
  fi
  gate_fetch_checks "$head_sha" "$repo" >"$actual" || return 1
  [ -s "$actual" ] || return 1
  return 0
}

# 戻り値: 0=問題なし / 1=確定的な問題 / 3=待てば解決するかもしれない（MISSING / PENDING のみ）
# $problems の各行は "kind<TAB>name<TAB>説明"（kind = MISSING / SKIPPED / FAILED / PENDING / UNKNOWN）
evaluate() {
  : >"$problems"
  local policy name bucket seen="$tmp/seen.txt"
  : >"$seen"

  while IFS=$'\t' read -r policy name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$name" >>"$seen"
    bucket="$(awk -F'\t' -v n="$name" '$1==n {print $2; exit}' "$actual")"
    if [ -z "$bucket" ]; then
      printf 'MISSING\t%s\tジョブが 1 度も作られていない\n' "$name" >>"$problems"
      continue
    fi
    case "$bucket" in
      pass) ;;
      skipping)
        [ "$policy" = "allow-skip" ] || \
          printf 'SKIPPED\t%s\tif: / ラベルでゲートが無効化されている（skip は pass ではない）\n' "$name" >>"$problems"
        ;;
      pending)
        [ "$conclusive" -eq 1 ] && printf 'PENDING\t%s\tまだ走っている\n' "$name" >>"$problems"
        ;;
      fail|cancel) printf 'FAILED\t%s\tbucket=%s\n' "$name" "$bucket" >>"$problems" ;;
      *) printf 'UNKNOWN\t%s\tbucket=%s\n' "$name" "$bucket" >>"$problems" ;;
    esac
  done <"$expected"

  if [ "$conclusive" -eq 1 ]; then
    # 期待リストに無いチェックでも赤ければマージしない（新しいワークフローを足すたびに
    # リストを直さなくても「赤い PR はマージされない」が守られる）。
    # ただしマージゲート自身のジョブは除く（自分が走っていることを理由に自分が通らなくなる）。
    while IFS=$'\t' read -r name bucket; do
      [ -n "$name" ] || continue
      grep -qxF -- "$name" "$seen" && continue
      grep -qxF -- "$name" "$self_jobs" && continue
      case "$bucket" in
        fail)    printf 'FAILED\t%s\t必須リスト外だが赤い\n' "$name" >>"$problems" ;;
        pending) printf 'PENDING\t%s\t必須リスト外・まだ走っている\n' "$name" >>"$problems" ;;
      esac
    done <"$actual"
  fi

  [ -s "$problems" ] || return 0
  # MISSING を即座に確定扱いにしない（登録ラグを欠落と誤検知する）。SKIPPED / FAILED は即確定。
  if awk -F'\t' '$1 != "PENDING" && $1 != "MISSING" { found=1 } END { exit found ? 0 : 1 }' "$problems"; then
    return 1
  fi
  return 3
}

elapsed=0
rc=1
while :; do
  if fetch_actual; then
    evaluate && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && break
    [ "$rc" -eq 3 ] || break
  fi
  if [ "$elapsed" -ge "$timeout" ]; then break; fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

if [ "$rc" -eq 0 ]; then
  n=$(wc -l <"$expected" | tr -d ' ')
  if [ "$conclusive" -eq 1 ]; then
    echo "OK: 必須ジョブ $n 件がすべて存在し、決着して緑です。"
  else
    echo "OK: 必須ジョブ $n 件がすべて存在します（skip ポリシー適合）。"
  fi
  exit 0
fi

echo ""
if [ ! -s "$actual" ]; then
  echo "NG: PR #$pr のチェック一覧を取得できませんでした（1 件も報告されていません）。"
  echo "    head SHA = ${head_sha:-不明}"
else
  echo "NG: PR #$pr の必須 CI ジョブに問題があります（head SHA = ${head_sha:-fixture}）。"
  echo ""
  awk -F'\t' '{ printf "    %-8s %s\n             └ %s\n", $1, $2, $3 }' "$problems"
  echo ""
  echo "  実際に登録されているチェック:"
  sort "$actual" | awk -F'\t' '{ printf "    %-10s %s\n", $2, $1 }'
fi

cat <<'MSG'

--------------------------------------------------------------------
考えられる原因:

「欠落」  そのワークフローがこの PR の最後の push より後に dev へ入った。
          → git fetch origin dev && git merge origin/dev && git push で取り込んで再判定する
「skip」  if: 条件やラベルでゲートが無効化されている。skip は pass ではない。
          正当に skip してよいジョブだけ .github/required-checks.txt で allow-skip: を明示する
「fail」  CI が赤い。マージしない。Generator に差し戻す
ジョブ名を変えた場合
          ワークフローの jobs.<id>.name と .github/required-checks.txt を同じ PR で直す

exit 0 を「検証された」と読まないこと。ジョブが存在しないことと緑であることは別の話です。
--------------------------------------------------------------------
MSG
exit 1
