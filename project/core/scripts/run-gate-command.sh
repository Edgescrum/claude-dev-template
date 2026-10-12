#!/usr/bin/env bash
#
# .github/gate-commands.env に宣言されたコマンドを 1 つ実行する（ワークフローに npm 等を直書きしないため）。
#
#   使い方: bash scripts/run-gate-command.sh <変数名>
#           例) bash scripts/run-gate-command.sh LINT_CMD
#
#   挙動:
#     変数が未定義        → exit 2（設定の誤り。typo で検査が黙って消えるのを防ぐ）
#     変数が空文字        → 実行せず exit 0。GITHUB_OUTPUT に status=unconfigured を書く
#                           （ワークフローはこれを gate-summary.sh に `unconfigured` として渡し、
#                             「未設定・未検証」と表示する。pass とは書かない）
#     変数に値がある      → `bash -c` で実行し、その exit code を返す。status=ran を書く
#
#   GATE_COMMANDS_FILE で env ファイルの場所を差し替えられる（相対パスはリポジトリルート基準）。
set -euo pipefail

var="${1:-}"
case "$var" in
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  ""|*[!A-Z0-9_]*) echo "usage: $0 <変数名（例: LINT_CMD）>" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
env_file="${GATE_COMMANDS_FILE:-.github/gate-commands.env}"
case "$env_file" in
  /*) ;;
  *) env_file="$repo_root/$env_file" ;;
esac
if [ ! -f "$env_file" ]; then
  echo "::error::$env_file が見つかりません。" >&2
  exit 2
fi

cd "$repo_root"
# shellcheck disable=SC1090 # 宣言ファイルはリポジトリ管理下（変更は通常の PR レビューを通る）
. "$env_file"

if [ -z "${!var+x}" ]; then
  echo "::error::$var が $env_file に定義されていません。検査しないなら空文字（$var=\"\"）で明示すること。" >&2
  exit 2
fi

cmd="${!var}"
if [ -z "$cmd" ]; then
  echo "::warning::$var は空なので実行しません（未設定・未検証。合格ではありません）。"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "status=unconfigured" >>"$GITHUB_OUTPUT"; fi
  exit 0
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "status=ran" >>"$GITHUB_OUTPUT"; fi
echo "+ $cmd"
exec bash -c "$cmd"
