#!/usr/bin/env python3
"""Reconcile the Custodian bug index against GitHub issue state.

WHY THIS EXISTS
---------------
The bug index (`research/custodian-bug-index.md`) is a table where each row's
second column references a GitHub issue, and the last column carries a status
word (Fixed / Open / Blocked / ...). A bug is "shipped" only when its fix is
committed AND its GitHub issue is closed. So the index's status word must agree
with the GitHub issue's actual state.

An earlier one-off script only matched issue links in the `issues/N` URL form
and therefore MISSED every row that references the issue as a bare `#NN`
(69 rows). This tool parses BOTH forms, paginates GitHub correctly, skips
pull-request entries, and classifies by the status WORD (never the emoji, per
the bug index's own recount history).

USAGE
-----
    python3 tools/kb-bug-reconcile.py [path/to/custodian-bug-index.md]

Prints two lists and totals:
  * FIXED-BUT-OPEN   index says Fixed/Not-a-bug, GitHub still open  -> to close
  * OPEN-BUT-CLOSED  index says Open/Blocked/..., GitHub closed     -> to investigate

Exit code 0 always; the report is the artifact.
"""
import re
import sys
import urllib.request
import urllib.error
import json

REPO = "blackwealthinc/custodian-deploy"
API = f"https://api.github.com/repos/{REPO}/issues"

# Order matters: "partially" before "fixed", "not a bug" before "fixed",
# "blocked"/"upstream" before "open".
_STATUS_WORDS = (
    ("not-a-bug", "closed"),
    ("not a bug", "closed"),
    ("partially", "open"),
    ("blocked", "open"),
    ("upstream", "open"),
    ("fixed", "closed"),
    ("open", "open"),
)


def classify_status(text: str) -> str:
    """Return 'closed' or 'open' (the EXPECTED GitHub state) for a status cell."""
    low = text.lower()
    for word, expected in _STATUS_WORDS:
        if word in low:
            return expected
    return "unknown"


def parse_index(path: str) -> list[dict]:
    """Parse the markdown table rows into {bug, issues:[], status, expected}."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            # Only table rows: | #N | <github> | <title> | <status> |
            m = re.match(r"^\|\s*(#\d+)\s*\|\s*(.*?)\s*\|\s*.*?\s*\|\s*(.*?)\s*\|", ln)
            if not m:
                continue
            bug, gh_col, status = m.group(1), m.group(2), m.group(3)
            # Issue numbers: bare #NN and issues/NN URLs, deduped, order kept.
            issues = []
            seen = set()
            for token in re.findall(r"#(\d+)", gh_col):
                n = int(token)
                if n not in seen:
                    seen.add(n)
                    issues.append(n)
            for n in re.findall(r"issues/(\d+)", gh_col):
                n = int(n)
                if n not in seen:
                    seen.add(n)
                    issues.append(n)
            rows.append({
                "bug": bug,
                "issues": issues,
                "status": status,
                "expected": classify_status(status),
            })
    return rows


def fetch_github_states() -> dict[int, str]:
    """Return {issue_number: 'open'|'closed'} for all non-PR issues."""
    states = {}
    page = 1
    while True:
        url = f"{API}?state=all&per_page=100&page={page}"
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode())
        for item in data:
            if "pull_request" in item:  # skip PRs
                continue
            states[int(item["number"])] = item["state"]  # 'open' | 'closed'
        if len(data) < 100:
            break
        page += 1
    return states


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "research/custodian-bug-index.md"
    rows = parse_index(path)
    gh = fetch_github_states()

    fixed_but_open = []
    open_but_closed = []
    not_filed = []
    unknown_status = []
    total_issue_rows = 0

    for r in rows:
        if not r["issues"]:
            not_filed.append(r["bug"])
            continue
        total_issue_rows += 1
        if r["expected"] == "unknown":
            unknown_status.append((r["bug"], r["status"]))
            continue
        for n in r["issues"]:
            actual = gh.get(n)
            if actual is None:
                # referenced but not returned by the API (deleted / not an issue)
                continue
            if r["expected"] == "closed" and actual == "open":
                fixed_but_open.append((r["bug"], n))
            elif r["expected"] == "open" and actual == "closed":
                open_but_closed.append((r["bug"], n))

    print(f"Parsed {len(rows)} index rows; {total_issue_rows} reference >=1 GitHub issue; "
          f"{len(not_filed)} not filed (no issue link).")
    print(f"GitHub: {sum(1 for v in gh.values() if v == 'open')} open / "
          f"{sum(1 for v in gh.values() if v == 'closed')} closed (non-PR).")
    print()
    print(f"FIXED-BUT-OPEN  (index Fixed/Not-a-bug, GitHub open)  = {len(fixed_but_open)}")
    for bug, n in fixed_but_open:
        print(f"  {bug} -> issue #{n}")
    print()
    print(f"OPEN-BUT-CLOSED (index Open/Blocked/..., GitHub closed) = {len(open_but_closed)}")
    for bug, n in open_but_closed:
        print(f"  {bug} -> issue #{n}")
    print()
    if unknown_status:
        print(f"UNKNOWN STATUS (no recognised word) = {len(unknown_status)}")
        for bug, st in unknown_status:
            print(f"  {bug}: {st!r}")
    print()
    print(f"NOT FILED (no GitHub issue link) = {len(not_filed)}")


if __name__ == "__main__":
    main()
