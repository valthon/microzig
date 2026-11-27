#!/usr/bin/env python3
"""List the design docs that describe code a change touches, for a reviewer to look at.

Usage: touched_docs.py BASE MERGED

BASE is the base branch commit and MERGED the result of merging the PR into it (in CI, the
pull_request merge commit the workflow checks out). The PR's changes are the diff BASE..MERGED,
and the design docs are read from MERGED, so coverage that either side added is in effect.

Each docs/design/*.md (except README.md and TEMPLATE.md) names the code it describes on a
`Covers:` line near its top: comma-separated files, or directories ending in `/`. For every doc
whose covered paths the PR changes, print one Markdown line:

    This PR touches code described by `docs/design/interrupts.md`.

The Lint workflow appends the output to the job summary. A match says where to look; the reviewer
decides whether a documented behavior or contract changed. Prints nothing when no doc is touched,
and always exits 0.
"""

import subprocess
import sys
from pathlib import PurePosixPath

DESIGN_DIR = "docs/design/"
SKIP = {"README.md", "TEMPLATE.md"}


def git(*args: str) -> str:
    # surrogateescape: a path or doc that is not valid UTF-8 must not crash an advisory listing.
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          errors="surrogateescape").stdout


def git_paths(cmd: str, *args: str) -> list[str]:
    """Paths from a NUL-delimited listing: git quotes non-ASCII names in its default output."""
    return [p for p in git(cmd, "-z", *args).split("\0") if p]


def covers(text: str) -> list[str]:
    """The `Covers:` entries from the doc's head (the lines before its first `## ` heading or
    fence). Only `\\n` ends a line."""
    for line in (raw.rstrip("\r") for raw in text.split("\n")):
        if line.startswith(("## ", "```", "~~~")):
            break
        if line.startswith("Covers:"):
            return [c.strip() for c in line[len("Covers:"):].split(",") if c.strip()]
    return []


def matches(path: str, cover: str) -> bool:
    return path.startswith(cover) if cover.endswith("/") else path == cover


def shown(path: str) -> str:
    """A path safe on one Markdown line: control characters written as escapes."""
    return "".join(c if 0x20 <= ord(c) != 0x7F else repr(c)[1:-1] for c in path)


def touched(base: str, merged: str) -> list[str]:
    changed = git_paths("diff", "--no-renames", "--name-only", base, merged)
    docs = [p for p in git_paths("ls-tree", "-r", "--name-only", merged, "--", DESIGN_DIR)
            if p.endswith(".md") and PurePosixPath(p).name not in SKIP]
    found = []
    for doc in sorted(docs):
        entries = covers(git("show", f"{merged}:{doc}"))
        if any(matches(path, cov) for path in changed for cov in entries):
            found.append(doc)
    return found


def main() -> int:
    if len(sys.argv) != 3 or not all(sys.argv[1:]):
        print("touched_docs.py needs BASE and MERGED commits; design docs not listed.")
        return 0
    sys.stdout.reconfigure(errors="backslashreplace")
    try:
        docs = touched(sys.argv[1], sys.argv[2])
    except (subprocess.CalledProcessError, ValueError, OSError) as e:
        print(f"touched_docs.py could not list design docs ({type(e).__name__}).")
        return 0
    for doc in docs:
        name = shown(doc)
        span = f"`` {name} ``" if "`" in name else f"`{name}`"  # a backtick ends a `span`
        print(f"This PR touches code described by {span}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
