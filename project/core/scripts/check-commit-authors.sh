#!/usr/bin/env bash
#
# PR に含まれる全コミットの author / committer の email が許可リストにあるかを検証する。
#
#   使い方: scripts/check-commit-authors.sh <base ref> [<head ref>]
#           例) scripts/check-commit-authors.sh origin/dev
#               scripts/check-commit-authors.sh origin/dev HEAD
#
#   ALLOWLIST_FILE=<path> で許可リストの場所を差し替えられる
#   （既定: .github/allowed-commit-authors.txt。相対パスはリポジトリルート基準）。
#
#   終了コード: 0 = 全件許可 / 1 = 許可外のコミットあり / 2 = 使い方・設定の誤り
#
# なぜ「全コミット」か: squash マージ後の dev のコミットは author が正しくなるため、
#   問題が見えるのは feature ブランチだけ。HEAD だけ見ると途中のコミットがすり抜ける。
#   別 email のコミットは GitHub 上で別アカウント扱いになり、デプロイ連携などが拒否されうる。
set -euo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
esac

base="${1:-}"
head_ref="${2:-HEAD}"

if [ -z "$base" ]; then
  echo "usage: $0 <base ref> [<head ref>]" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
allowlist="${ALLOWLIST_FILE:-.github/allowed-commit-authors.txt}"
case "$allowlist" in
  /*) ;;
  *) allowlist="$repo_root/$allowlist" ;;
esac

if [ ! -f "$allowlist" ]; then
  echo "NG: 許可リスト $allowlist が見つかりません。" >&2
  exit 2
fi

for ref in "$base" "$head_ref"; do
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "NG: ref '$ref' が解決できません。fetch 漏れ（浅いクローン）ではありませんか。" >&2
    exit 2
  fi
done

# --- 許可リストの読み込み -------------------------------------------------
# case のパターンとして使うため、`*` 以外のグロブ特殊文字はエスケープする（`[bot]` を文字クラスにしない）。
escape_glob() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/?/\\?/g'
}

author_pats=""
committer_pats=""
first_author=""
section="authors"
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%%#*}"
  # `名前 <email>` 形式の行は <...> の中だけを使う（git の identity をそのまま貼れるように）。
  case "$line" in
    *"<"*">"*) line="${line#*<}"; line="${line%%>*}" ;;
  esac
  # email に空白は含まれないので、空白を全部落として正規化する
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -n "$line" ] || continue
  case "$line" in
    "[authors]") section="authors"; continue ;;
    "[committers]") section="committers"; continue ;;
    "["*)
      echo "NG: $allowlist:$lineno 不明なセクション '$line'（[authors] / [committers] のみ）" >&2
      exit 2
      ;;
  esac
  case "$line" in
    *"{{"*) echo "NG: $allowlist:$lineno 置換されていないプレースホルダがあります: '$line'" >&2; exit 2 ;;
  esac
  pat="$(escape_glob "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')")"
  if [ "$section" = "authors" ]; then
    author_pats="$author_pats $pat"
    [ -n "$first_author" ] || first_author="$line"
  else
    committer_pats="$committer_pats $pat"
  fi
done <"$allowlist"

if [ -z "$(printf '%s' "$author_pats" | tr -d '[:space:]')" ]; then
  echo "NG: $allowlist の [authors] が空です。" >&2
  exit 2
fi

# email がパターン群のいずれかに一致するか（$2 は意図的に非クォートで単語分割する）
is_allowed() {
  _email="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for _pat in $2; do
    # shellcheck disable=SC2254 # グロブとして評価させるため意図的に非クォート
    case "$_email" in $_pat) return 0 ;; esac
  done
  return 1
}

# --- 検査 -----------------------------------------------------------------
range="$base..$head_ref"
total="$(git rev-list --count "$range")"
echo "検査対象: $range （$total commits）"
echo "許可リスト: ${allowlist#"$repo_root"/}"

if [ "$total" -eq 0 ]; then
  echo "OK: 検査対象のコミットがありません。"
  exit 0
fi

failed=0
report=""
US="$(printf '\037')"

while IFS="$US" read -r sha an ae cn ce subject; do
  [ -n "$sha" ] || continue
  short="$(printf '%s' "$sha" | cut -c1-8)"
  bad=""
  if ! is_allowed "$ae" "$author_pats"; then
    bad="$bad    author    $an <$ae>   <== 許可リストにありません
"
  fi
  if ! is_allowed "$ce" "$author_pats $committer_pats"; then
    bad="$bad    committer $cn <$ce>   <== 許可リストにありません
"
  fi
  if [ -n "$bad" ]; then
    failed=$((failed + 1))
    report="$report  commit $short  $subject
$bad"
    echo "::error::commit $short の author/committer が許可リストにありません: author=<$ae> committer=<$ce>"
  fi
done < <(git log --format="%H${US}%an${US}%ae${US}%cn${US}%ce${US}%s" "$range")

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "NG: 許可されていない author / committer のコミットが $failed 件あります。"
  echo ""
  printf '%s' "$report"
  cat <<MSG
--------------------------------------------------------------------
1) git に identity を自分で指定していないか（-c user.email= / --author= / GIT_AUTHOR_EMAIL= は禁止）
     env | grep -E '^(GIT_|EMAIL=)' || echo 'なし'
     git var GIT_AUTHOR_IDENT
   期待する email: ${first_author}
   ※ エージェントのコンテキストに出てくる「ユーザーの email」は git の identity ではない

2) 既に作ってしまったコミットを直す
   - 直近 1 件:   git commit --amend --reset-author --no-edit
   - 全部:       git rebase --exec 'git commit --amend --reset-author --no-edit -q' $base
   - push 済み:  git push --force-with-lease

3) その email が正当なメンバーのものなら .github/allowed-commit-authors.txt に追記して PR に含める

詳細: docs/agents/commit-identity-and-ci-gate.md の「1. コミット identity」
--------------------------------------------------------------------
MSG
  exit 1
fi

echo "OK: 全 $total コミットの author / committer が許可リスト内です。"
