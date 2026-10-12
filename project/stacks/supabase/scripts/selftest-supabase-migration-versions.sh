#!/usr/bin/env bash
# scripts/gate-extra.d/supabase-migration-versions.sh の空振り検査。
# 一時リポジトリを作って標本を流す。リポジトリの実ファイルには一切書き込まない。
#
#   [1] 衝突の標本 → 落ちる（exit 1）
#   [2] 逆行の標本 → 落ちる（exit 1）
#   [3] 昇格 PR では逆行を免除する → 通る（exit 0）
#   [4] 正常な新規 → 通る（exit 0）
#   [5] base が読めない → 判定不能（exit 2）
#   [6] 衝突の判定を潰した写しでは [1] が通ってしまう（＝[1] の赤はガード由来）
#   [7] 逆行の判定を潰した写しでは [2] が通ってしまう（＝[2] の赤はガード由来）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
target="$here/gate-extra.d/supabase-migration-versions.sh"
[ -f "$target" ] || { echo "selftest: 対象が見つかりません: $target" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

run_case() { # name expected script base
  local name="$1" expected="$2" script="$3" base="$4" got
  ( cd "$work/repo" && BASE_REF="$base" bash "$script" >"$work/out.txt" 2>&1 ); got=$?
  if [ "$got" = "$expected" ]; then
    echo "ok   $name (exit $got)"
  else
    echo "FAIL $name: expected exit $expected, got $got"; sed 's/^/     | /' "$work/out.txt"; fail=1
  fi
}

mk_repo() {
  rm -rf "$work/repo"; mkdir -p "$work/repo/supabase/migrations"
  cd "$work/repo" || exit 2
  git init -q -b dev
  git -c user.name=selftest -c user.email=selftest@example.invalid commit -q --allow-empty -m init
}
add_commit() { # file
  touch "supabase/migrations/$1"; git add -A
  git -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m "$1"
}
set_remote_ref() { git update-ref "refs/remotes/origin/$1" "$2"; }

# 共通の base: dev / staging / main が 20300101000000 まで持つ
mk_repo
add_commit 20300101000000_base.sql
base_sha="$(git rev-parse HEAD)"
for b in dev staging main; do set_remote_ref "$b" "$base_sha"; done

# staging にだけ hotfix が入っている（dev より新しい version）
git checkout -q -b stg "$base_sha"
add_commit 20300105000000_hotfix.sql
set_remote_ref staging "$(git rev-parse HEAD)"

# [1] 衝突: staging の hotfix と同じ version・別名を HEAD に足す（dev の最大より新しいので逆行ではない）
git checkout -q -b case1 "$base_sha"
add_commit 20300105000000_feature.sql
run_case "[1] 衝突は落ちる" 1 "$target" dev

# [2] 逆行: base の最大より古い新規
git checkout -q -b case2 "$base_sha"
add_commit 20291231000000_old.sql
run_case "[2] 逆行は落ちる" 1 "$target" dev

# [3] 昇格 PR では逆行を免除
run_case "[3] 昇格 PR では逆行を免除" 0 "$target" staging

# [4] 正常
git checkout -q -b case4 "$base_sha"
add_commit 20300102000000_new.sql
run_case "[4] 正常な新規は通る" 0 "$target" dev

# [5] base が読めない
run_case "[5] base が読めないと判定不能" 2 "$target" no-such-branch

# [6][7] ガードを潰した写し
sed 's/status=1 # GUARD:collision/: # neutered/' "$target" > "$work/neuter-collision.sh"
sed 's/status=1 # GUARD:reverse/: # neutered/' "$target" > "$work/neuter-reverse.sh"
if cmp -s "$target" "$work/neuter-collision.sh" || cmp -s "$target" "$work/neuter-reverse.sh"; then
  echo "FAIL 潰す対象の印（GUARD:collision / GUARD:reverse）が見つからない。selftest が空振りしている"; fail=1
fi
git checkout -q case1
run_case "[6] 衝突の判定を潰すと [1] が通る" 0 "$work/neuter-collision.sh" dev
git checkout -q case2
run_case "[7] 逆行の判定を潰すと [2] が通る" 0 "$work/neuter-reverse.sh" dev

exit "$fail"
