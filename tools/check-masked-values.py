#!/usr/bin/env python3
"""Fail if a file contains a *masked* value where real content belongs.

Why this exists
---------------
Hermes' secret redaction rewrites `NAME=value` shapes in **terminal output only**.
The filesystem is never masked, but an agent that reads a document through the shell,
sees masked text, and writes it back permanently corrupts the file. That is how the
usage examples and several docs in this project ended up containing a masked value
where an env-var name or an API key belonged.

The fix for the cause is a process rule (never build file content from shell output).
This script is the backstop that makes the mistake impossible to ship unnoticed.

It is deliberately written in Python, and prints only counts and locations, because a
shell `grep` for these shapes is itself masked and therefore cannot be trusted.

Usage
-----
    python3 tools/check-masked-values.py [paths...]      # default: tracked files
Exit code 0 = clean, 1 = masked values found.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

STARS = chr(42) * 3  # built at runtime so this file can't match its own rules

# (label, compiled pattern). Patterns are intentionally narrow: they match a masked
# value sitting where real content belongs, not legitimate prose about masking.
PATTERNS = [
    ("env assignment", re.compile(r"[A-Z][A-Z0-9_]{2,}=[ \t]*" + re.escape(STARS) + r"(?![*])\s*$")),
    ("bearer header", re.compile(r"[Bb]earer[ \t]+" + re.escape(STARS) + r"(?![*])")),
    ("url userinfo", re.compile(r"://[^/\s:@]+:" + re.escape(STARS) + r"(?![*])@")),
    ("json field", re.compile(r'"[A-Za-z0-9_]*(?:[Kk]ey|[Ss]ecret|[Tt]oken)"[ \t]*:[ \t]*"' + re.escape(STARS) + r'(?![*])"')),
]

SKIP_SUFFIX = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip", ".gz", ".woff", ".woff2", ".jar"}

# Files that legitimately *document* the defect.
ALLOW_FILES = {
    "check-masked-values.py",
    "custodian-bug-index.md",
}

# Bug records legitimately QUOTE the defect - that is their purpose - so they are not
# findings. Skipped by path, so a bug log can keep describing what went wrong.
BUG_RECORD_DIRS = {"session-logs"}
BUG_RECORD_PREFIXES = ("bug-",)


def is_bug_record(p: Path) -> bool:
    if p.name in ALLOW_FILES:
        return True
    if any(part in BUG_RECORD_DIRS for part in p.parts):
        return True
    return p.name.startswith(BUG_RECORD_PREFIXES)


def tracked_files() -> list[Path]:
    try:
        out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
        return [Path(p) for p in out.splitlines() if p]
    except Exception:
        return [p for p in Path(".").rglob("*") if p.is_file()]


def scan(paths: list[Path]) -> int:
    findings = 0
    for p in paths:
        if not p.is_file() or p.suffix.lower() in SKIP_SUFFIX:
            continue
        if is_bug_record(p):
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="strict")
        except Exception:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for label, pat in PATTERNS:
                if pat.search(line):
                    findings += 1
                    print(f"{p}:{lineno}: masked value where real content belongs ({label})")
    return findings


def main() -> int:
    args = sys.argv[1:]
    paths = [Path(a) for a in args] if args else tracked_files()
    print(f"scanning {len(paths)} file(s) for masked values...")
    n = scan(paths)
    if n:
        print(f"\nFAIL: {n} occurrence(s). Rebuild the line from ground truth — "
              f"never by guessing a plausible value.")
        return 1
    print("OK: no masked values found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
