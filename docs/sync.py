#!/usr/bin/env python3
# Verify (or regenerate) fenced code blocks in markdown files against
# their source files. Pattern: an HTML comment
#
#     <!-- include: path/to/file -->
#
# immediately followed (whitespace-skipped) by a fenced code block. The
# block's body must match the file at that path exactly.
#
# Modes:
#   --check  exit nonzero on drift, print a diff
#   --fix    rewrite the markdown so the block matches the file
#
# Path is resolved relative to the repo root (the parent of docs/).

import argparse
import difflib
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _collect_docs() -> list[Path]:
    """Doc surfaces with potential <!-- include: ... --> blocks.

    The fixed list is the canonical project docs; the globs sweep Claude Code
    project-local scaffolding so newly-added agents/commands/skills auto-
    participate without re-editing this file.
    """
    fixed = [
        REPO_ROOT / "README.md",
        REPO_ROOT / "BELIEFS.md",
        REPO_ROOT / "CLAUDE.md",
        REPO_ROOT / "AGENTS.md",
    ]
    globbed = list((REPO_ROOT / ".claude").glob("agents/*.md")) \
        + list((REPO_ROOT / ".claude").glob("commands/*.md")) \
        + list((REPO_ROOT / ".claude").glob("skills/*/SKILL.md"))
    return [p for p in (*fixed, *sorted(globbed)) if p.exists()]


DOCS = _collect_docs()

INCLUDE_RE = re.compile(
    r"<!--\s*include:\s*([^\s>]+)\s*-->\s*\n"      # marker line
    r"(```[^\n]*\n)"                                # opening fence (lang optional)
    r"(.*?)"                                        # body (non-greedy)
    r"(^```\s*$)",                                  # closing fence on its own line
    re.DOTALL | re.MULTILINE,
)


def check_or_fix(md_path: Path, fix: bool) -> tuple[bool, str]:
    """Return (ok, new_text). ok is False if any block drifted."""
    text = md_path.read_text()
    ok = True
    drift_reports: list[str] = []

    def replace(match: re.Match) -> str:
        nonlocal ok
        rel = match.group(1)
        fence_open = match.group(2)
        body = match.group(3)
        fence_close = match.group(4)
        src = (REPO_ROOT / rel).resolve()
        try:
            expected = src.read_text()
        except FileNotFoundError:
            ok = False
            drift_reports.append(f"{md_path.name}: include target not found: {rel}")
            return match.group(0)
        # Body always carries a trailing newline before the closing fence.
        if not expected.endswith("\n"):
            expected += "\n"
        if body != expected:
            ok = False
            diff = "".join(
                difflib.unified_diff(
                    expected.splitlines(keepends=True),
                    body.splitlines(keepends=True),
                    fromfile=f"{rel} (source)",
                    tofile=f"{md_path.name} (doc block)",
                    n=2,
                )
            )
            drift_reports.append(
                f"{md_path.name}: block out of sync with {rel}\n{diff}"
            )
        if fix:
            return f"<!-- include: {rel} -->\n{fence_open}{expected}{fence_close}"
        return match.group(0)

    new_text = INCLUDE_RE.sub(replace, text)
    for report in drift_reports:
        print(report, file=sys.stderr)
    return ok, new_text


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--fix", action="store_true")
    args = ap.parse_args()

    all_ok = True
    blocks_seen = 0
    for md in DOCS:
        if not md.exists():
            continue
        before = md.read_text()
        blocks_seen += len(INCLUDE_RE.findall(before))
        ok, new_text = check_or_fix(md, fix=args.fix)
        if not ok:
            all_ok = False
        if args.fix and new_text != before:
            md.write_text(new_text)
            print(f"updated {md.relative_to(REPO_ROOT)}")

    if blocks_seen == 0:
        print("docs/sync.py: no <!-- include: ... --> markers found", file=sys.stderr)

    if args.check:
        if all_ok:
            print(f"docs/sync.py: {blocks_seen} block(s) in sync")
            return 0
        print("docs/sync.py: drift detected (see above)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
