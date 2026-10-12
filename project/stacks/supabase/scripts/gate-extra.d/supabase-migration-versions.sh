#!/usr/bin/env bash
# supabase 部品: マイグレーション version の「衝突」と「逆行」を検査する（PR ゲートの拡張点）。
#
# 呼ばれ方（scripts/gate-extra.d/*.sh の約束）:
#   - リポジトリ直下で実行される。HEAD が PR の head
#   - 環境変数 BASE_REF に PR の base ブランチ名（dev / staging / main / …）が入る
#   - 終了コード: 0 = 合格 / 1 = 違反 / 2 = 判定不能（ref が読めない等。合格として扱わないこと）
#
# 検査:
#   [衝突] 同じ version（ファイル名の先頭 14 桁）で別名のファイルが、HEAD と
#          origin/dev・origin/staging・origin/main のどこかに併存していないか。
#          dev 単体では db reset が通るため、昇格まで気づけない。
#   [逆行] HEAD で新しく足した version が、base の最大 version より大きいか。
#          `supabase migration new` は UTC 採番なので、手で別 TZ の名前を付けた
#          ファイルが混ざると「base より古い新規」ができる。db reset は通るが、
#          統合後に同じ関数の定義が黙って上書きされる。
#          昇格 PR（base が staging / main と完全一致）では免除する
#          （昇格では逆行が構造的に起きるため。代わりに runbook 補足 §3 を人が見る）。
#
# この検査の空振り検査は scripts/selftest-supabase-migration-versions.sh。
set -uo pipefail

MIG_DIR="supabase/migrations"
REMOTE="${MIGRATION_REMOTE:-origin}"
BASE_REF="${BASE_REF:-}"

if [ -z "$BASE_REF" ]; then
  echo "[migration-versions] 判定不能: BASE_REF が空です" >&2
  exit 2
fi

# 昇格先かどうかは完全一致で判定する（末尾一致にすると feature/staging が免除される）
is_promotion_target() {
  case "$1" in
    staging|main) return 0 ;;
    *) return 1 ;;
  esac
}

# ref の migration ファイル名一覧（存在しない ref は空 + 非 0）
list_migrations() {
  local ref="$1"
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || return 1
  git ls-tree --name-only "$ref" "$MIG_DIR/" 2>/dev/null \
    | sed -n "s#^$MIG_DIR/##p" | grep -E '^[0-9]{14}_.*\.sql$' || true
}

base_ref="$REMOTE/$BASE_REF"
if ! git rev-parse --verify -q "$base_ref^{commit}" >/dev/null; then
  echo "[migration-versions] 判定不能: $base_ref が読めません（fetch 済みか確認）" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

list_migrations HEAD > "$tmp/head.txt"
: > "$tmp/all.txt"
cat "$tmp/head.txt" >> "$tmp/all.txt"
for b in dev staging main; do
  if list_migrations "$REMOTE/$b" > "$tmp/$b.txt"; then
    cat "$tmp/$b.txt" >> "$tmp/all.txt"
  else
    echo "[migration-versions] note: $REMOTE/$b が無いので衝突検査の対象から外します"
  fi
done

status=0

# [衝突] version ごとに異なるファイル名が 2 つ以上あるか
collisions="$(sort -u "$tmp/all.txt" | awk -F_ '{print $1}' | sort | uniq -d)"
if [ -n "$collisions" ]; then
  echo "[migration-versions] NG 衝突: 同じ version で別名のファイルがあります"
  for v in $collisions; do
    sort -u "$tmp/all.txt" | grep "^${v}_" | sed 's/^/    /'
  done
  echo "  直し方: 未適用側（通常は dev 側）を新しい version で作り直し、古いファイルを消す。"
  echo "          staging / main に適用済みのファイルはリネームしない。"
  status=1 # GUARD:collision
fi

# [逆行]
if is_promotion_target "$BASE_REF"; then
  echo "[migration-versions] skip: base が ${BASE_REF}（昇格 PR）なので逆行検査は行いません。runbook 補足 §3 を人が確認すること"
else
  base_list="$tmp/base.txt"
  list_migrations "$base_ref" > "$base_list"
  base_max="$(awk -F_ '{print $1}' "$base_list" | sort | tail -n1)"
  new_files="$(comm -23 <(sort -u "$tmp/head.txt") <(sort -u "$base_list"))"
  if [ -n "$base_max" ] && [ -n "$new_files" ]; then
    reversed=""
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      v="${f%%_*}"
      if [ "$v" \< "$base_max" ] || [ "$v" = "$base_max" ]; then
        reversed="$reversed$f"$'\n'
      fi
    done <<< "$new_files"
    if [ -n "$reversed" ]; then
      echo "[migration-versions] NG 逆行: base（${base_ref}）の最大 version $base_max 以下の新規 migration があります"
      printf '%s' "$reversed" | sed '/^$/d; s/^/    /'
      echo "  直し方: $base_max より大きい version を手で付け直す（migration new の再実行では直らないことがある）"
      status=1 # GUARD:reverse
    fi
  fi
fi

[ "$status" -eq 0 ] && echo "[migration-versions] OK"
exit "$status"
