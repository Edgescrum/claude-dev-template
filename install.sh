#!/usr/bin/env bash
# Claude Code 開発運用テンプレートを、ユーザーレベル（~/.claude）にインストールする。
#
#   ./install.sh            エージェントとスキルを ~/.claude にシンボリックリンクで入れる
#   ./install.sh --dry-run  何をするかだけ表示する
#   ./install.sh --uninstall  このリポジトリを指すリンクだけを外す
#
# 方針:
#   - 既にある「実ファイル」や「別の場所を指すリンク」は上書きしない（衝突として報告し exit 2）
#   - リンクなので、このリポジトリを更新すれば ~/.claude 側にもそのまま反映される
#   - プロジェクトの .claude/agents/ に同名の定義があれば、そちらが優先される（Claude Code の仕様）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
DEST="${CLAUDE_HOME:-$HOME/.claude}"
MODE="install"
case "${1:-}" in
  --dry-run) MODE="dry-run" ;;
  --uninstall) MODE="uninstall" ;;
  "") ;;
  *) echo "不明な引数: $1" >&2; exit 1 ;;
esac

conflicts=0
linked=0
skipped=0

link_one() { # $1=リンク元（このリポジトリ内） $2=リンク先（~/.claude 内）
  local src="$1" dst="$2"
  if [ "$MODE" = "uninstall" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      rm "$dst"; echo "外した: $dst"; linked=$((linked+1))
    fi
    return
  fi
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    skipped=$((skipped+1)); return
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "衝突: $dst は既にあります（このリポジトリへのリンクではありません）。手で確認してください" >&2
    conflicts=$((conflicts+1)); return
  fi
  if [ "$MODE" = "dry-run" ]; then
    echo "[dry-run] ln -s $src $dst"
  else
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"; echo "入れた: $dst"
  fi
  linked=$((linked+1))
}

for f in "$ROOT"/agents/*.md; do
  [ -e "$f" ] || continue
  link_one "$f" "$DEST/agents/$(basename "$f")"
done
for d in "$ROOT"/skills/*/; do
  [ -d "$d" ] || continue
  d="${d%/}"
  link_one "$d" "$DEST/skills/$(basename "$d")"
done

echo "完了（${MODE}）: 処理 ${linked} 件 / 既に最新 ${skipped} 件 / 衝突 ${conflicts} 件"
[ "$conflicts" -eq 0 ] || exit 2
