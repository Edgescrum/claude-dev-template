#!/usr/bin/env bash
#
# 統合ジョブの各ステップの結果を集計し、1 つでも失敗していたらジョブを落とす。
#
#   使い方:
#     bash scripts/gate-summary.sh <manifest> \
#       --outcome <id>=<outcome> [--outcome ...] [--deferred] [--title <見出し>]
#
#   outcome は GitHub Actions の steps.<id>.outcome（success / failure / cancelled / skipped）に加え、
#   scripts/run-gate-command.sh が「コマンド未設定」を表す `unconfigured` を受け付ける。
#
#   終了コード:
#     0  manifest の全項目が success（または許容された延期 / 未設定）
#     1  1 件以上が失敗 / 欠落 / 想定外の skip
#     2  使い方の誤り・manifest が壊れている（空振りなので緑にしない）
#
# なぜ要るか: 検査を 1 ジョブにまとめて各ステップを continue-on-error で全部走らせる以上、
#   最後に必ず落とす番人が要る（課金はジョブ単位で 1 分切り上げなので、統合は安い）。
#
# 「緑に見えて実は検証していない」を作らない不変条件:
#   (1) manifest の id が 1 つでも渡ってこなければ落とす（ステップを消すだけで検査が消えるのを防ぐ）
#   (2) manifest に無い id が渡ってきても落とす（集計とステップの片方だけの追加を検出）
#   (3) skipped は既定で失敗。`deep` 項目を --deferred 付きで呼んだときだけ「延期」として許容
#   (4) success / 許容された skipped / unconfigured 以外はすべて失敗
#   (5) unconfigured（.github/gate-commands.env で明示的に空にしたコマンド）は失敗にしないが、
#       pass とも書かない。表と ::warning:: に「未設定（未検証）」として必ず出す
set -euo pipefail

export LC_ALL=C

manifest=""
deferred=0
title=""
outcomes_raw=()

while [ $# -gt 0 ]; do
  case "$1" in
    --outcome) shift; outcomes_raw+=("${1:-}") ;;
    --deferred) deferred=1 ;;
    --title) shift; title="${1:-}" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) if [ -z "$manifest" ]; then manifest="$1"; else echo "引数が多すぎます: $1" >&2; exit 2; fi ;;
  esac
  shift
done

if [ -z "$manifest" ]; then
  echo "usage: $0 <manifest> --outcome <id>=<outcome> [...] [--deferred] [--title <見出し>]" >&2
  exit 2
fi
if [ ! -f "$manifest" ]; then
  echo "NG: manifest が見つかりません: $manifest" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-summary.XXXXXX")"
case "$tmp" in "" | "/" | "/*") echo "mktemp に失敗しました" >&2; exit 2 ;; esac
trap 'rm -rf "$tmp"' EXIT INT TERM

# manifest 形式: `<id> <flags> <ラベル…>`（`#` 以降はコメント / 空行は無視）
#   flags: always … 常に実行される / deep … --deferred 指定時に限り skipped を許容
awk '
  { sub(/#.*/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
  $0 == "" { next }
  NF < 3 { print "NG: manifest の行が不正です（<id> <flags> <ラベル> が必要）: " $0 > "/dev/stderr"; bad = 1; next }
  {
    id = $1; flags = $2
    if (id in seen) { print "NG: manifest に id が重複しています: " id > "/dev/stderr"; bad = 1; next }
    seen[id] = 1
    if (flags != "always" && flags != "deep") {
      print "NG: manifest の flags は always / deep のみです: " id " " flags > "/dev/stderr"; bad = 1; next
    }
    label = $0
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", label)
    print id "\t" flags "\t" label
  }
  END { if (bad) exit 2 }
' "$manifest" >"$tmp/manifest.tsv" || exit 2

if [ ! -s "$tmp/manifest.tsv" ]; then
  echo "NG: manifest $manifest に項目が 1 件もありません（集計が空振りします）。" >&2
  exit 2
fi

: >"$tmp/given.tsv"
for kv in ${outcomes_raw+"${outcomes_raw[@]}"}; do
  case "$kv" in
    *=*) ;;
    *) echo "NG: --outcome は <id>=<outcome> 形式で指定してください: '$kv'" >&2; exit 2 ;;
  esac
  id="${kv%%=*}"
  val="${kv#*=}"
  if [ -z "$id" ]; then echo "NG: --outcome の id が空です: '$kv'" >&2; exit 2; fi
  if awk -F'\t' -v n="$id" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$tmp/given.tsv"; then
    echo "NG: --outcome に id が重複しています: $id" >&2
    exit 2
  fi
  printf '%s\t%s\n' "$id" "$val" >>"$tmp/given.tsv"
done

heading="${title:-ゲートの結果}"
{
  echo "## $heading"
  echo ""
  echo "| 検査 | 結果 |"
  echo "|---|---|"
} >"$tmp/summary.md"

failed=""
deferred_list=""
unconfigured_list=""

while IFS=$'\t' read -r id flags label; do
  [ -n "$id" ] || continue
  outcome="$(awk -F'\t' -v n="$id" '$1 == n { print $2; exit }' "$tmp/given.tsv")"
  if [ -z "$outcome" ]; then
    # (1) 空を「問題なし」と読まない。
    verdict="MISSING"
    failed="$failed $id(MISSING)"
  else
    case "$outcome" in
      success) verdict="success" ;;
      unconfigured)
        verdict="SKIPPED（未設定・未検証）"
        unconfigured_list="$unconfigured_list $id"
        ;;
      skipped)
        if [ "$flags" = "deep" ] && [ "$deferred" -eq 1 ]; then
          verdict="skipped（延期）"
          deferred_list="$deferred_list $id"
        else
          verdict="SKIPPED"
          failed="$failed $id(SKIPPED)"
        fi
        ;;
      *) verdict="$outcome"; failed="$failed $id($outcome)" ;;
    esac
  fi
  printf '  %-26s %-16s %s\n' "$id" "$verdict" "$label"
  printf '| %s（%s） | %s |\n' "$label" "$id" "$verdict" >>"$tmp/summary.md"
done <"$tmp/manifest.tsv"

# (2) manifest に無い id
while IFS=$'\t' read -r id _outcome; do
  [ -n "$id" ] || continue
  if ! awk -F'\t' -v n="$id" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$tmp/manifest.tsv"; then
    echo "  ✗ manifest $manifest に無い id が渡されました: $id"
    printf '| （manifest に無い） | %s |\n' "$id" >>"$tmp/summary.md"
    failed="$failed $id(UNKNOWN-ID)"
  fi
done <"$tmp/given.tsv"

failed="$(printf '%s' "$failed" | xargs || true)"
deferred_list="$(printf '%s' "$deferred_list" | xargs || true)"
unconfigured_list="$(printf '%s' "$unconfigured_list" | xargs || true)"

if [ -n "$deferred_list" ]; then
  {
    echo ""
    echo "> 延期（--deferred 指定）: $deferred_list"
    echo "> これらは定期実行と staging / main への昇格時に検証されます。"
  } >>"$tmp/summary.md"
  echo "  （延期: $deferred_list — 定期実行と昇格時に検証されます）"
fi
if [ -n "$unconfigured_list" ]; then
  {
    echo ""
    echo "> ⚠️ 未設定のため検証していない: $unconfigured_list"
    echo "> .github/gate-commands.env で空にしてあるコマンドです。**合格ではありません。**"
  } >>"$tmp/summary.md"
  echo "::warning::未設定のため検証していない項目があります: ${unconfigured_list}（.github/gate-commands.env）"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$tmp/summary.md" >>"$GITHUB_STEP_SUMMARY"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "failed=$failed" >>"$GITHUB_OUTPUT"; fi

if [ -n "$failed" ]; then
  echo ""
  echo "::error::ゲートが不合格です: $failed"
  echo "NG: $failed"
  exit 1
fi

n_total=$(wc -l <"$tmp/manifest.tsv" | tr -d ' ')
echo ""
if [ -n "$unconfigured_list" ]; then
  echo "OK（ただし未検証あり）: $n_total 件中、未設定 $(printf '%s' "$unconfigured_list" | wc -w | tr -d ' ') 件を除いて通過しました。"
else
  echo "OK: $n_total 件の検査がすべて通過しました。"
fi
