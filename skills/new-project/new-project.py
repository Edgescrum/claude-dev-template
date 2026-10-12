#!/usr/bin/env python3
"""雛形（コア + 選んだスタック部品）を新しいリポジトリにコピーし、置換変数を埋める。

使い方:
  new-project.py --target <dir> --name <表示名> --owner <GitHub組織> --repo <リポジトリ名> \
      --prod-url <URL> --staging-url <URL> --author "<名前> <email>" \
      [--requirements-dir docs/requirements] [--stacks supabase,nextjs-vercel] [--dry-run] [--list-stacks]

方針:
  - 既存のファイルは上書きしない（衝突したら何も書かずに exit 2）
  - 対象ディレクトリは空（.git だけはあってよい）であること
  - 埋められなかった {{VAR}} は一覧を出し、docs/bootstrap.md の「残っている置換変数」に書く
  - スタック部品のファイル名の末尾が `.append` ならコアの同名ファイルの末尾に追記し、
    `.override` ならコアの同名ファイルを差し替える（どちらも、コアに同名ファイルが無ければエラー）
  - 終了コード: 0 = 成功 / 1 = 入力の誤り / 2 = 衝突・安全のため中止
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
from pathlib import Path

ROOT = Path(os.path.realpath(__file__)).parent.parent.parent
CORE = ROOT / "project" / "core"
STACKS = ROOT / "project" / "stacks"
STACK_META_FILES = {"README.md", "CLAUDE.section.md"}
VAR_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")


def available_stacks() -> list[str]:
    if not STACKS.is_dir():
        return []
    return sorted(p.name for p in STACKS.iterdir() if p.is_dir() and not p.name.startswith("."))


def stack_summary(name: str) -> str:
    readme = STACKS / name / "README.md"
    if readme.is_file():
        for line in readme.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if s and not s.startswith("#") and not s.startswith(">"):
                return s[:120]
    return ""


def plan_files(stacks: list[str]) -> list[tuple[Path, Path, str]]:
    """(コピー元, リポジトリ内の相対パス, 種別 copy|append|override) の一覧。.tmpl は外す。"""
    out: list[tuple[Path, Path, str]] = []

    def walk(base: Path, skip_meta: bool) -> None:
        for src in sorted(base.rglob("*")):
            if src.is_dir() or src.name == ".DS_Store":
                continue
            rel = src.relative_to(base)
            if skip_meta and len(rel.parts) == 1 and rel.name in STACK_META_FILES:
                continue
            kind = "copy"
            for suffix in (".append", ".override"):
                if rel.name.endswith(suffix):
                    kind = suffix[1:]
                    rel = rel.with_name(rel.name[: -len(suffix)])
            if rel.name.endswith(".tmpl"):
                rel = rel.with_name(rel.name[: -len(".tmpl")])
            out.append((src, rel, kind))

    walk(CORE, skip_meta=False)
    for s in stacks:
        walk(STACKS / s, skip_meta=True)
    return out


def is_text(path: Path) -> bool:
    try:
        path.read_text(encoding="utf-8")
        return True
    except (UnicodeDecodeError, OSError):
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target")
    ap.add_argument("--name")
    ap.add_argument("--owner")
    ap.add_argument("--repo")
    ap.add_argument("--prod-url")
    ap.add_argument("--staging-url")
    ap.add_argument("--author")
    ap.add_argument("--requirements-dir", default="docs/requirements")
    ap.add_argument("--stacks", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list-stacks", action="store_true")
    a = ap.parse_args()

    if a.list_stacks:
        for s in available_stacks():
            print(f"{s}\t{stack_summary(s)}")
        return 0

    missing = [k for k in ("target", "name", "owner", "repo", "prod_url", "staging_url", "author") if not getattr(a, k)]
    if missing:
        print("必須の引数がありません: " + ", ".join("--" + m.replace("_", "-") for m in missing), file=sys.stderr)
        return 1
    if not re.fullmatch(r".+ <[^<>@\s]+@[^<>\s]+>", a.author):
        print('--author は "名前 <email>" の形で渡してください（git の identity と同じ形）', file=sys.stderr)
        return 1

    stacks = [s.strip() for s in a.stacks.split(",") if s.strip()]
    unknown = [s for s in stacks if s not in available_stacks()]
    if unknown:
        print(f"存在しないスタック部品: {', '.join(unknown)}（--list-stacks で一覧）", file=sys.stderr)
        return 1

    target = Path(a.target).expanduser().resolve()
    if not target.is_dir():
        print(f"対象ディレクトリがありません: {target}", file=sys.stderr)
        return 1
    leftovers = [p.name for p in target.iterdir() if p.name != ".git"]
    if leftovers:
        print(f"対象ディレクトリが空ではありません（.git 以外: {', '.join(sorted(leftovers)[:10])}）。上書きしないため中止します", file=sys.stderr)
        return 2

    files = plan_files(stacks)
    seen: dict[Path, Path] = {}
    overridden: set[Path] = set()
    for src, rel, kind in files:
        if kind == "copy":
            if rel in seen:
                print(f"衝突: {rel} が {seen[rel]} と {src} の両方にあります。部品の組み合わせを見直してください", file=sys.stderr)
                return 2
            seen[rel] = src
        else:
            if rel not in seen:
                print(f"{src} は {kind} 先の {rel} がコアにありません", file=sys.stderr)
                return 2
            if kind == "override":
                if rel in overridden:
                    print(f"衝突: {rel} を 2 つの部品が差し替えようとしています", file=sys.stderr)
                    return 2
                overridden.add(rel)

    stack_rows = "\n".join(f"- `{s}` — {stack_summary(s)}" for s in stacks) or "- （なし）"
    values = {
        "PROJECT_NAME": a.name,
        "GITHUB_OWNER": a.owner,
        "GITHUB_REPO": a.repo,
        "PROD_URL": a.prod_url,
        "STAGING_URL": a.staging_url,
        "ALLOWED_AUTHOR": a.author,
        "REQUIREMENTS_DIR": a.requirements_dir.rstrip("/"),
        "STACKS": stack_rows,
        "STACKS_INLINE": ", ".join(stacks) or "（なし）",
    }

    def render(text: str) -> str:
        return VAR_RE.sub(lambda m: values.get(m.group(1), m.group(0)), text)

    claude_sections = []
    for s in stacks:
        sec = STACKS / s / "CLAUDE.section.md"
        if sec.is_file():
            body = sec.read_text(encoding="utf-8").strip()
            if not body.startswith("## "):
                body = f"## スタック: {s}\n\n{body}"
            claude_sections.append(body)

    if a.dry_run:
        print(f"[dry-run] 出力先: {target}")
        print(f"[dry-run] スタック部品: {values['STACKS_INLINE']}")
        for _, rel, kind in files:
            print(f"  {rel}" + ("" if kind == "copy" else f"  ({kind})"))
        print(f"[dry-run] CLAUDE.md に追加する節: {len(claude_sections)}")
        return 0

    unresolved: dict[str, set[str]] = {}
    # コピー → 差し替え → 追記 の順に適用する（追記は差し替え後の内容に足す）
    order = {"copy": 0, "override": 1, "append": 2}
    for src, rel, kind in sorted(files, key=lambda f: order[f[2]]):
        dst = target / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if is_text(src):
            text = render(src.read_text(encoding="utf-8"))
            if kind == "append":
                text = dst.read_text(encoding="utf-8").rstrip("\n") + "\n\n" + text
            if rel == Path("CLAUDE.md") and claude_sections and kind == "copy":
                text = text.rstrip() + "\n\n" + "\n\n".join(render(c) for c in claude_sections) + "\n"
            dst.write_text(text, encoding="utf-8")
        else:
            shutil.copyfile(src, dst)
        mode = src.stat().st_mode
        if mode & stat.S_IXUSR:
            dst.chmod(dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    for _, rel, _ in files:
        p = target / rel
        if p.is_file() and is_text(p):
            for v in VAR_RE.findall(p.read_text(encoding="utf-8")):
                unresolved.setdefault(v, set()).add(str(rel))

    boot = target / "docs" / "bootstrap.md"
    if unresolved and boot.is_file():
        lines = "\n".join(f"- `{{{{{k}}}}}` — {', '.join(sorted(v))}" for k, v in sorted(unresolved.items()))
        boot.write_text(boot.read_text(encoding="utf-8").rstrip() + "\n\n" + lines + "\n", encoding="utf-8")

    print(f"処理したファイル: {len(files)} 件（追記・差し替えを含む）→ {target}")
    print(f"スタック部品: {values['STACKS_INLINE']}")
    if unresolved:
        print("埋まっていない置換変数（docs/bootstrap.md に記録済み）:")
        for k, v in sorted(unresolved.items()):
            print(f"  {{{{{k}}}}}: {', '.join(sorted(v))}")
    else:
        print("置換変数はすべて埋まりました")
    return 0


if __name__ == "__main__":
    sys.exit(main())
