# shellcheck shell=bash
#
# マージゲート共通ヘルパ。
#
# 単体では実行しない。scripts/merge-gate.sh と scripts/check-required-jobs.sh が source する。
# なぜ共通化するか: 「head SHA の確定」「チェック結果の正規化」は 2 つのゲートが
# 必ず同じ答えを出さなければならない（別実装だと合否判定と存在確認が別の SHA を見る）。
#
# 詳細と限界は docs/agents/commit-identity-and-ci-gate.md の「2. マージ前 CI ゲート」。

# ⚠️ ロケール固定（外すと fail-open になる）。
# macOS の awk は UTF-8 ロケールで文字列 `==` を照合順序で比較し、
# 別名の日本語ジョブ名を「一致」と判定して必須ジョブの欠落を見逃す（CI の mawk では再現しない）。
export LC_ALL=C

# ---------------------------------------------------------------------------
# fixture（自己テスト用の差し替え）
# ---------------------------------------------------------------------------
# GATE_FIXTURE_DIR を指定すると gh / git を一切呼ばず、以下のファイルを読む:
#   pr.json / lsremote.txt / compare.json / compare-files.json / comments.tsv / checks.tsv / files.tsv
#
# gate_fx <ファイル名> <代入先の変数名>
#   0 … fixture を使う / 1 … fixture モードではない / 2 … fixture が足りない（呼び出し側は中止）
# 「fixture が無ければ本物を叩く」にしない（自己テストが黙って本物の API で通ってしまうため）。
gate_fx() {
  [ -n "${GATE_FIXTURE_DIR:-}" ] || return 1
  local p="$GATE_FIXTURE_DIR/$1"
  if [ ! -f "$p" ]; then
    printf 'NG: fixture が足りません: %s\n' "$p" >&2
    return 2
  fi
  printf -v "$2" '%s' "$p"
  return 0
}

gate_err() { printf '%s\n' "$*" >&2; }

# gate_resolve_repo [<明示値>] → owner/repo を stdout に
# リポジトリ名はハードコードしない。明示値 → GH_REPO → GITHUB_REPOSITORY → gh repo view の順。
gate_resolve_repo() {
  local r="${1:-${GH_REPO:-${GITHUB_REPOSITORY:-}}}"
  if [ -z "$r" ]; then
    r=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || r=""
  fi
  case "$r" in
    */*) printf '%s\n' "$r" ;;
    *) gate_err "NG: リポジトリ（owner/repo）を特定できません。--repo か GH_REPO を指定してください。"; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# head SHA の確定
# ---------------------------------------------------------------------------
# GraphQL の headRefOid は stale な statusCheckRollup と同じノードから来るため鮮度保証が無い。
# ① REST の .head.sha と ② git ls-remote（refs/pull/<n>/head と refs/heads/<branch>）を
# 突き合わせ、一致しなければ「API が stale」として判定を中止する（exit 2）。
gate_resolve_head_sha() { # gate_resolve_head_sha <pr> <repo> → SHA を stdout に
  local pr="$1" repo="$2" rest_sha head_ref head_repo lsremote pull_sha branch_sha
  local fx_pr="" fx_ls="" rc

  rc=0; gate_fx pr.json fx_pr || rc=$?
  [ "$rc" -eq 2 ] && return 2
  if [ "$rc" -eq 0 ]; then
    gate_fx lsremote.txt fx_ls || return 2
    rest_sha=$(jq -r '.head.sha' <"$fx_pr")
    head_ref=$(jq -r '.head.ref' <"$fx_pr")
    head_repo=$(jq -r '.head.repo.full_name // ""' <"$fx_pr")
    lsremote=$(cat "$fx_ls")
  else
    local json
    json=$(gh api "repos/$repo/pulls/$pr") || { gate_err "NG: PR #$pr を取得できません。"; return 2; }
    rest_sha=$(printf '%s' "$json" | jq -r '.head.sha')
    head_ref=$(printf '%s' "$json" | jq -r '.head.ref')
    head_repo=$(printf '%s' "$json" | jq -r '.head.repo.full_name // ""')
    lsremote=$(gate_ls_remote "$repo") || return 2
  fi

  case "$rest_sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) gate_err "NG: REST が返した head.sha が SHA ではありません: '$rest_sha'"; return 2 ;;
  esac

  if [ -n "$head_repo" ] && [ "$head_repo" != "$repo" ]; then
    gate_err "NG: head が別リポジトリ ($head_repo) です。fork からの PR はこのゲートの対象外。"
    return 2
  fi

  pull_sha=$(printf '%s\n' "$lsremote" | awk -v r="refs/pull/$pr/head" '$2==r {print $1; exit}')
  branch_sha=$(printf '%s\n' "$lsremote" | awk -v r="refs/heads/$head_ref" '$2==r {print $1; exit}')

  if [ -z "$pull_sha" ] && [ -z "$branch_sha" ]; then
    gate_err "NG: git ls-remote から head SHA を確認できませんでした（refs/pull/$pr/head も refs/heads/$head_ref も無い）。"
    gate_err "    REST の値だけを信じて先に進むことはしません。"
    return 2
  fi

  local ref name
  for ref in "$pull_sha:refs/pull/$pr/head" "$branch_sha:refs/heads/$head_ref"; do
    name="${ref#*:}"
    ref="${ref%%:*}"
    [ -n "$ref" ] || continue
    if [ "$ref" != "$rest_sha" ]; then
      gate_err "NG: head SHA が経路によって食い違っています（API が stale の可能性）。"
      gate_err "    REST  repos/$repo/pulls/$pr .head.sha = $rest_sha"
      gate_err "    git   $name = $ref"
      gate_err "    30〜60 秒待ってから再実行してください。一致するまで判定してはいけません。"
      return 2
    fi
  done

  printf '%s\n' "$rest_sha"
}

gate_ls_remote() { # gate_ls_remote <repo> → ls-remote の出力
  local repo="$1" out
  if out=$(git ls-remote origin 'refs/heads/*' 'refs/pull/*/head' 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    # URL にトークンを埋めるとプロセス一覧・エラー出力に出るため、credential helper で渡す。
    if out=$(GIT_TERMINAL_PROMPT=0 \
        git -c "credential.helper=!f(){ echo username=x-access-token; echo password=${GH_TOKEN:-$GITHUB_TOKEN}; }; f" \
        ls-remote "https://github.com/$repo" 'refs/heads/*' 'refs/pull/*/head' 2>/dev/null) && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  gate_err "NG: git ls-remote に失敗しました。head SHA を独立に確認できないので判定を中止します。"
  return 2
}

# ---------------------------------------------------------------------------
# チェック結果の正規化
# ---------------------------------------------------------------------------
# Actions のジョブは /check-runs、外部サービス（デプロイ連携など）は /status に出る。
# 片方だけだと空振りするので両方を引いて 1 つの名前空間に統合する。
# bucket は `gh pr checks --json bucket` と同じ語彙: pass / fail / pending / skipping / cancel
# 同名の check-run が複数ある場合（再実行）は id が最大のもの（＝最後の結果）を採る。
gate_fetch_checks() { # gate_fetch_checks <sha> <repo> → "name<TAB>bucket" を stdout に
  local sha="$1" repo="$2" raw fx="" rc statuses

  rc=0; gate_fx checks.tsv fx || rc=$?
  [ "$rc" -eq 2 ] && return 2
  if [ "$rc" -eq 0 ]; then
    # bucket 欠落を「pass」に落とさない（空振り防止）。
    awk -F'\t' 'NF<2 || $2=="" {
        print "fixture の checks.tsv に bucket がありません: " $0 > "/dev/stderr"; bad=1; next
      } { print $1 "\t" $2 }
      END { if (bad) exit 2 }' "$fx"
    return $?
  fi

  raw=$(
    gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
      -q '.check_runs[] | [(.id|tostring), .name, .status, (.conclusion // "")] | @tsv' 2>/dev/null
  ) || raw=""
  statuses=$(
    gh api "repos/$repo/commits/$sha/status?per_page=100" \
      -q '.statuses[] | [.context, .state] | @tsv' 2>/dev/null
  ) || statuses=""

  {
    printf '%s\n' "$raw" | awk -F'\t' '
      NF < 3 { next }
      {
        id=$1; name=$2; status=$3; concl=$4
        if (status != "completed")                      b="pending"
        else if (concl=="success" || concl=="neutral")  b="pass"
        else if (concl=="skipped")                      b="skipping"
        else if (concl=="cancelled")                    b="cancel"
        else                                            b="fail"
        if (!(name in seen) || id+0 > seen[name]) { seen[name]=id+0; bucket[name]=b }
      }
      END { for (n in bucket) print n "\t" bucket[n] }
    '
    printf '%s\n' "$statuses" | awk -F'\t' '
      NF < 2 { next }
      {
        if ($2=="success")      b="pass"
        else if ($2=="pending") b="pending"
        else                    b="fail"
        print $1 "\t" b
      }
    '
  } | awk -F'\t' 'NF>=2 && $1 != "" { print }'
}

# ---------------------------------------------------------------------------
# base drift の免除
# ---------------------------------------------------------------------------
# `behind_by == 0` の要求は、dev に 1 件入るたびに open な PR 全部の CI 再実行を強いる（O(n²)）。
# 目的は「base が進むとベースラインが黙って緩む」の防止なので、
# base 側の新差分が「CI の結果を動かしえない」場合だけ免除する。
# ★ 判定はゲート側で機械的に行い、判定できなければ必ず免除しない（fail-closed）。
# ★ 免除は「マージ結果を検証した」ではない。最後の砦は post-merge-verify.yml。
GATE_DRIFT_SAFE_DESC='docs/**（docs/agents/** を除く）/ リポジトリ直下の *.md（追加・変更のみ）'
GATE_DRIFT_SENSITIVE_DESC='.github/** / scripts/** / .claude/** / docs/agents/** / それ以外の許可リスト外すべて'

# gate_base_drift_sensitive_path <パス> → 0=CI の結果を動かしうる / 1=ここでは判定しない
# 許可リストとは独立に評価する（片方の書き間違い 1 回で穴が開かないように）。
gate_base_drift_sensitive_path() {
  case "$1" in
    .github/*|scripts/*) return 0 ;;
    # .claude/** と docs/agents/** は CI のエージェント文書検査が読みうる。
    # 「今どのファイルを読んでいるか」で線を引くと、読む検査が増えた日に誰も気づけない。
    .claude|.claude/*) return 0 ;;
    docs/agents|docs/agents/*) return 0 ;;
  esac
  return 1
}

# gate_base_drift_safe_status <status> → 0=免除してよい / 1=免除しない（理由を stdout）
# 削除・改名は「PR 側がそのパスを名指ししている」と統合後にだけ壊れるので免除しない。
gate_base_drift_safe_status() {
  case "$1" in
    added|modified|changed) return 0 ;;
    removed) printf 'ファイルの削除（名指ししている側がマージ結果で壊れうる）\n' ;;
    renamed) printf 'ファイルの改名（同上）\n' ;;
    "") printf 'status を読めませんでした\n' ;;
    *) printf '追加・変更以外の変更種別（%s）\n' "$1" ;;
  esac
  return 1
}

# gate_base_drift_safe_path <パス> → 0=免除してよい / 1=免除しない（理由を stdout）
# allowlist ∧ ¬denylist。denylist だけだと知らない種類のファイルが素通りする（fail-open）。
gate_base_drift_safe_path() {
  local p="$1"
  case "$p" in
    "") printf 'パスが空\n'; return 1 ;;
    /*) printf '絶対パス\n'; return 1 ;;
    *..*) printf '.. を含むパス\n'; return 1 ;;
    *\\*) printf 'バックスラッシュ / 制御文字を含むパス\n'; return 1 ;;
  esac
  if gate_base_drift_sensitive_path "$p"; then
    printf 'CI の結果に影響しうる（%s）\n' "$GATE_DRIFT_SENSITIVE_DESC"
    return 1
  fi
  # ⚠️ docs-only 側（gate_docs_only_allowed）とは問いが違うので範囲を揃えないこと。
  #    こちらは「CI の結果を動かしうるか」、あちらは「レビューを飛ばしてよいか」。
  case "$p" in
    docs/*) return 0 ;;
    */*) ;;
    *.md) return 0 ;;
  esac
  printf '免除の対象外（免除できるのは %s のみ）\n' "$GATE_DRIFT_SAFE_DESC"
  return 1
}

# gate_base_drift_exempt <repo> <merge_base_sha> <base_ref>
#   0 = 免除してよい / 1 = 免除しない（どちらも理由を stdout）
# 見るのは merge_base..base（＝ head が取り込んでいない base の新コミット）。
# `--paginate` は使わない。取りこぼしが免除方向（fail-open）に効くので、
# 上限（files 300 件 / total_commits 250）に達したら免除しない。
gate_base_drift_exempt() {
  local repo="$1" merge_base="$2" base_ref="$3"
  local fx="" rc=0 json total files n p st line reason bad=0

  case "$merge_base" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) printf 'merge base を特定できませんでした（判定不能なので免除しません）\n'; return 1 ;;
  esac

  gate_fx compare-files.json fx || rc=$?
  [ "$rc" -eq 2 ] && { printf 'fixture compare-files.json がありません（判定不能なので免除しません）\n'; return 1; }
  if [ "$rc" -eq 0 ]; then
    json=$(cat "$fx")
  else
    json=$(gh api "repos/$repo/compare/$merge_base...$base_ref?per_page=100" 2>/dev/null) || {
      printf '%s の差分を取得できませんでした（判定不能なので免除しません）\n' "$base_ref"
      return 1
    }
  fi

  total=$(printf '%s' "$json" | jq -r '.total_commits // ""' 2>/dev/null || printf '')
  case "$total" in
    ""|*[!0-9]*) printf 'total_commits を読めませんでした（判定不能なので免除しません）\n'; return 1 ;;
  esac
  if [ "$total" -gt 250 ]; then
    printf 'compare API の比較上限（250 コミット）を超えています（判定不能なので免除しません）\n'
    return 1
  fi
  if ! printf '%s' "$json" | jq -e 'has("files") and (.files | type == "array")' >/dev/null 2>&1; then
    printf '差分ファイル一覧を読めませんでした（判定不能なので免除しません）\n'
    return 1
  fi
  # status を先に置く（ファイル名にタブが含まれても壊れない）。
  files=$(printf '%s' "$json" | jq -r '.files[] | "\(.status // "")\t\(.filename)"' 2>/dev/null) || {
    printf '差分ファイル一覧を読めませんでした（判定不能なので免除しません）\n'
    return 1
  }
  if [ -z "$files" ]; then
    printf '差分ファイルが 0 件でした（判定不能なので免除しません）\n'
    return 1
  fi
  n=$(printf '%s\n' "$files" | grep -c '')
  if [ "$n" -ge 300 ]; then
    printf '差分が %s 件あり compare API の上限（300）に達しています（判定不能なので免除しません）\n' "$n"
    return 1
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    st="${line%%	*}"
    p="${line#*	}"
    [ -n "$p" ] || continue
    if ! reason=$(gate_base_drift_safe_path "$p"); then
      printf '%s: %s\n' "$p" "$reason"; bad=1; continue
    fi
    if ! reason=$(gate_base_drift_safe_status "$st"); then
      printf '%s: %s\n' "$p" "$reason"; bad=1
    fi
  done <<EOF
$files
EOF

  [ "$bad" -eq 0 ] || return 1
  printf '%s の新規 %s コミット / 差分 %s 件はすべて %s\n' "$base_ref" "$total" "$n" "$GATE_DRIFT_SAFE_DESC"
  return 0
}

# ---------------------------------------------------------------------------
# ゲート自身のジョブ名（自己参照の除外）
# ---------------------------------------------------------------------------
# workflow_dispatch の run は ref の head コミットに check-run を作るので、
# PR ブランチを ref にするとゲート自身が「未決着のチェック」として自分を止める。
# 除外対象は job id で人が明示し（既定: gate と post-merge）、表示名は merge-gate.yml から読む。
# 設定ファイルに除外名を置くと「都合の悪いジョブを除外する」抜け道になるため。
# smoke は dispatch 中 skipped にしかならず、PR では失敗しうるので除外しない。
GATE_SELF_JOB_IDS="${GATE_SELF_JOB_IDS:-gate post-merge}"

gate_self_job_names() { # gate_self_job_names [<merge-gate.yml のパス>]
  local wf="${1:-.github/workflows/merge-gate.yml}"
  [ -f "$wf" ] || return 0
  awk -v want="$GATE_SELF_JOB_IDS" '
    BEGIN { n_want = split(want, w, /[ \t]+/); for (i = 1; i <= n_want; i++) if (w[i] != "") keep[w[i]] = 1 }
    /^jobs:[ \t]*$/ { injobs = 1; next }
    injobs && /^[^ \t]/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:[ \t]*$/ {
      id = $0; sub(/^  /, "", id); sub(/:[ \t]*$/, "", id)
      cur = id; names[cur] = id; order[++n] = cur; next
    }
    injobs && cur != "" && /^    name:[ \t]/ {
      v = $0; sub(/^    name:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      names[cur] = v
    }
    END {
      for (i = 1; i <= n; i++) if (order[i] in keep) { print names[order[i]]; found++ }
      if (found == 0) print "warn: GATE_SELF_JOB_IDS (" want ") に一致する job が " FILENAME " に無い" > "/dev/stderr"
    }
  ' "$wf"
}

# ---------------------------------------------------------------------------
# 期待リストの読み込み（.github/required-checks.txt）
# ---------------------------------------------------------------------------
# 1 行 1 ジョブ名。`#` 以降はコメント。skip を許すジョブだけ行頭に `allow-skip:`。
# 既定は「skip を許さない」（注釈の書き忘れが厳しい側に倒れる）。出力: "policy<TAB>name"
gate_read_expected() { # gate_read_expected <ファイル>
  awk '
    { sub(/#.*/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    $0 == "" { next }
    {
      policy = "no-skip"
      if (index($0, "allow-skip:") == 1) { policy = "allow-skip"; sub(/^allow-skip:[ \t]*/, "") }
      if ($0 == "") next
      print policy "\t" $0
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# docs-only 経路
# ---------------------------------------------------------------------------
# ドキュメントだけの PR には Generator / Evaluator の評決を要求しない。
# ★ `docs-only` ラベルは申告にすぎない。ゲートが変更ファイル一覧を取得して全件を照合する。
# ★ 判定できない状況はすべて「docs-only ではない」に倒す（fail-closed）。
# ★ 説明ではなく gate_docs_only_allowed() の実装が正。
#
# 残る危険: CLAUDE.md / .claude/**/*.md はエージェントの行動規約そのもので、
#   そこに書かれた安全制約を削る変更がレビュー無しでマージされうる。
#   締めるなら gate_docs_only_sensitive_path に 1 行足す。
# 注意: docs/** は拡張子を問わない。docs/ に「CI が実行するもの」を置いた瞬間に穴になる。
#   また docs/ を読む CI 検査がある場合、その検査は PR ゲートで毎回走らせること
#   （docs-only PR は手元での検証を経ないため、走らなければ dev が赤くなる）。
GATE_DOCS_ONLY_ALLOWLIST_DESC='docs/** / リポジトリ直下の *.md / .claude/**/*.md'
GATE_DOCS_ONLY_SENSITIVE_DESC='.github/** / scripts/** / src/** / .claude/** のうち *.md 以外'

# gate_docs_only_sensitive_path <パス> → 0=ドキュメントではない / 1=ここでは判定しない
# 許可リストとは独立に評価する二重の歯止め（冗長であることに意味がある）。
gate_docs_only_sensitive_path() {
  case "$1" in
    .github/*|scripts/*|src/*) return 0 ;;
    # .claude/**/*.md は指示書なので打ち消さない（この行を消せば締め直せる）。
    .claude/*.md) ;;
    # それ以外の .claude/**（settings.json / hooks/*.sh）は実行される設定。
    .claude|.claude/*) return 0 ;;
  esac
  return 1
}

# gate_docs_only_allowed <パス> → 0=許可 / 1=不許可（理由を stdout に 1 行）
# 順序: ① 形式（怪しければ不許可）→ ② 明示的な拒否 → ③ 許可リスト（列挙のみ）。
# 大文字小文字は区別する（.MD は不許可。環境依存を避けて厳しい側に固定）。
gate_docs_only_allowed() {
  local p="$1"
  case "$p" in
    "") printf 'パスが空\n'; return 1 ;;
    /*) printf '絶対パス\n'; return 1 ;;
    *..*) printf '.. を含むパス\n'; return 1 ;;
    # jq の @tsv は制御文字を \t \n にエスケープするので、ここで捕まる。
    *\\*) printf 'バックスラッシュ / 制御文字を含むパス\n'; return 1 ;;
  esac
  if gate_docs_only_sensitive_path "$p"; then
    printf 'ドキュメントではないので docs-only の対象外（%s）\n' "$GATE_DOCS_ONLY_SENSITIVE_DESC"
    return 1
  fi
  case "$p" in
    docs/*) return 0 ;;
    # 必ず `*/*) ;;` より前に置く（後ろだと `*/*` に食われて届かない）。
    .claude/*.md) return 0 ;;
    # リポジトリ直下の *.md 限定（src/README.md を通さない）。
    */*) ;;
    *.md) return 0 ;;
  esac
  printf '許可リスト外\n'
  return 1
}

# gate_fetch_pr_files <pr> <repo> → "status<TAB>filename<TAB>previous_filename" を stdout に
# ⚠️ --paginate を外さないこと（既定 30 件で切れ、31 件目以降のコードが判定から消える）。
# API の 3000 件上限による切り捨ては、呼び出し側の changed_files 照合で fail-closed になる。
gate_fetch_pr_files() {
  local pr="$1" repo="$2" fx="" rc=0
  gate_fx files.tsv fx || rc=$?
  [ "$rc" -eq 2 ] && return 2
  if [ "$rc" -eq 0 ]; then
    cat "$fx"
    return 0
  fi
  gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" \
    -q '.[] | [.status, .filename, (.previous_filename // "")] | @tsv' || return 1
}

# gate_docs_only_verify <files.tsv> <changed_files> → 0=全件許可 / 1=不許可（理由を stdout）
# 一覧が空 / 件数が changed_files と不一致 / 想定外の status / rename 元が無い → すべて 1。
gate_docs_only_verify() {
  local f="$1" expected="$2"
  local n status name prev reason bad=0

  if [ ! -s "$f" ]; then
    printf '変更ファイルを 1 件も取得できませんでした（fail-closed）\n'
    return 1
  fi
  case "$expected" in
    ""|*[!0-9]*) printf 'PR の changed_files を取得できませんでした（fail-closed）\n'; return 1 ;;
  esac
  n=$(grep -c '' "$f")
  if [ "$n" -ne "$expected" ]; then
    printf '取得した変更ファイル %s 件が PR の changed_files=%s と一致しません\n' "$n" "$expected"
    printf '（ページネーション不足 / API の 3000 件上限による切り捨てを疑うこと）\n'
    return 1
  fi

  while IFS=$'\t' read -r status name prev; do
    [ -n "$status" ] || { printf 'status が空の行があります\n'; bad=1; continue; }
    case "$status" in
      added|modified|removed|renamed|copied|changed|unchanged) ;;
      *) printf '想定外の status=%s (%s)\n' "$status" "$name"; bad=1; continue ;;
    esac
    case "$status" in
      renamed|copied)
        if [ -z "$prev" ]; then
          printf 'status=%s なのに previous_filename が空です (%s)\n' "$status" "$name"
          bad=1; continue
        fi
        ;;
    esac
    # 新しい名前と古い名前の両方を照らす（src/x.ts → docs/x.md を通さない）。
    if ! reason=$(gate_docs_only_allowed "$name"); then
      printf '%s (%s): %s\n' "$name" "$status" "$reason"; bad=1
    fi
    if [ -n "$prev" ] && ! reason=$(gate_docs_only_allowed "$prev"); then
      printf '%s (%s の rename 元): %s\n' "$prev" "$status" "$reason"; bad=1
    fi
  done <"$f"

  [ "$bad" -eq 0 ] || return 1
  return 0
}
