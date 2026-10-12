# shellcheck shell=bash
#
# 「CI が赤かったことを Issue で知らせる」共通部。
#
#   使い方（source して呼ぶ）:
#     . scripts/lib/report-issue.sh
#     report_issue "$repo" "$title" "$body_file" Must
#
# なぜ Issue にするか: 赤い run は Actions のタブに埋もれ、誰も見ない場所の失敗は失敗していないのと同じ。
# 罠と対処:
#   * 毎回新規作成するとノイズで読まれなくなる → 同じ表題の未解決 Issue があればコメントを足す
#   * `gh issue list --search` は部分一致 → 表題の完全一致で絞り直す
#   * gh の失敗を 0 で終えると「通知したつもり」で誰にも届かない → 失敗は必ず非 0 で返す

# shellcheck disable=SC2128
if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE}" = "${0}" ]; then
  echo "これは source して使うライブラリです（実行するものではありません）。" >&2
  exit 2
fi

report_issue() { # report_issue <repo> <title> <body-file> [ラベル…]
  local repo="${1:?repo が必要です}" title="${2:?title が必要です}" body_file="${3:?body-file が必要です}"
  shift 3
  local labels=("$@")

  if [ ! -f "$body_file" ]; then
    echo "本文のファイルがありません: ${body_file}" >&2
    return 2
  fi

  local existing=""
  existing="$(gh issue list --repo "$repo" --state open --search "\"$title\" in:title" \
    --json number,title -q ".[] | select(.title == \"$title\") | .number" | head -1)" || {
    echo "既存 Issue の検索に失敗しました（gh / 権限を確認すること）。" >&2
    return 1
  }

  if [ -n "$existing" ]; then
    echo "既存の Issue #${existing} にコメントします。"
    gh issue comment "$existing" --repo "$repo" --body-file "$body_file"
    return $?
  fi

  echo "Issue を起票します。"
  local args=(--repo "$repo" --title "$title" --body-file "$body_file")
  local l
  for l in ${labels[@]+"${labels[@]}"}; do args+=(--label "$l"); done
  gh issue create "${args[@]}"
}
