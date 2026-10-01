#!/usr/bin/env python3
"""Kill Bill business-level regression harness (Custodian).

Kill Bill's Deployment Guide pre/post-deployment checklist says:

    "Test, test, test ... Write business-level regression tests that you can run
     before each upgrade."

This is that test. It exists so that a maintenance window can be judged by
comparison against a recorded baseline instead of by hope.

DESIGN CONSTRAINTS (deliberate -- see the Four Gates in the runbook):
  * READ-ONLY. No POST/PUT/DELETE, ever. Nothing here can change engine state.
  * NO CREDENTIALS. Uses only /1.0/healthcheck and /1.0/metrics, which Kill Bill
    serves unauthenticated. The repo is public, so secrets must never be needed.
  * NO SERVER FOOTPRINT. Runs from an operator machine over HTTP.
  * Restart-safe comparisons. Counters reset when the container restarts, so the
    diff compares the *set* of failure signals, not cumulative values.

The DB half of Kill Bill's own checklist (bus_events empty, no past-due
AVAILABLE notifications) is in tools/kb-queue-health.sql. Run that through your
privileged path and pass the output here with --db-counts-file.

USAGE
    # record a baseline
    python3 tools/kb-regression.py snapshot --out baseline.json

    # after the maintenance window, compare
    python3 tools/kb-regression.py diff baseline.json current.json

    # add the DB half
    bash -c 'PW=$(grep DB_PASSWORD /opt/killbill/.db-credentials | cut -d= -f2); \
      docker exec killbill-db mariadb -u root -p"$PW" killbill -N \
      < tools/kb-queue-health.sql' > /tmp/dbcounts.txt
    python3 tools/kb-regression.py snapshot --db-counts-file /tmp/dbcounts.txt --out baseline.json

Exit codes:  0 = clean   1 = FAIL   2 = warnings only
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

DEFAULT_BASE = "http://192.168.50.104:8080"

# Metrics whose *presence* means something went wrong. We compare membership, not
# values, because counters reset to zero on restart.
FAILURE_METRIC_MARKERS = (".5xx.", "error", "fail", "unknow")


def http_get(base, path, timeout=25):
    """GET a Kill Bill endpoint. Returns (status, parsed_json_or_text)."""
    req = urllib.request.Request(
        base.rstrip("/") + path,
        headers={"Accept": "application/json", "User-Agent": "custodian-kb-regression/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", errors="replace")
            try:
                return r.status, json.loads(raw)
            except ValueError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except Exception as e:  # noqa: BLE001 - surface any transport failure as a status
        return None, "transport error: %s" % e


def collect_healthcheck(base):
    """Flatten /1.0/healthcheck into {check_name: healthy_bool} plus plugin list.

    The plugin list is the single most valuable field here: after installing the
    email plugin, 'killbill-email-notifications' MUST appear. Kill Bill's own
    Plugin Installation Guide says a plugin that is silently absent from the logs
    "usually confirms the directory mismatch ... Kill Bill never saw the files".
    """
    status, body = http_get(base, "/1.0/healthcheck")
    if not isinstance(body, dict):
        return {
            "http_status": status,
            "error": "unparseable healthcheck response",
            "checks": {},
            "plugins": [],
            "queues_growing": [],
        }

    checks = {}
    queues_growing = []
    plugins = []

    for name, detail in body.items():
        if not isinstance(detail, dict):
            continue
        if "healthy" in detail:
            checks[name] = bool(detail["healthy"])
        if "KillbillPluginsHealthcheck" in name:
            plugins = sorted(
                k for k in detail.keys() if k not in ("healthy", "message", "error")
            )
        if "KillbillQueuesHealthcheck" in name:
            for qname, qdetail in detail.items():
                if isinstance(qdetail, dict) and qdetail.get("growing"):
                    queues_growing.append(qname)

    return {
        "http_status": status,
        "checks": checks,
        "plugins": plugins,
        "queues_growing": sorted(queues_growing),
    }


def collect_metrics(base):
    """Extract only the failure signals from /1.0/metrics.

    The full payload is ~700 series and mostly uninteresting; taking all of it
    would make the diff unreadable and the baseline enormous.
    """
    status, body = http_get(base, "/1.0/metrics")
    if not isinstance(body, dict):
        return {"http_status": status, "error": "unparseable metrics response", "failure_keys": []}

    failure_keys = []
    for section in ("timers", "meters", "counters"):
        for key in (body.get(section) or {}).keys():
            low = key.lower()
            if any(m in low for m in FAILURE_METRIC_MARKERS):
                failure_keys.append("%s:%s" % (section, key))

    return {"http_status": status, "failure_keys": sorted(set(failure_keys))}


def collect_db_counts(path):
    """Parse `label<TAB>value` output from tools/kb-queue-health.sql."""
    counts = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or "\t" not in line:
                continue
            label, _, value = line.partition("\t")
            value = value.strip()
            try:
                counts[label.strip()] = int(value)
            except ValueError:
                counts[label.strip()] = value
    return counts


def build_snapshot(base, db_counts_file):
    snap = {
        "captured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "target": base,
        "healthcheck": collect_healthcheck(base),
        "metrics": collect_metrics(base),
    }
    if db_counts_file:
        try:
            snap["db"] = collect_db_counts(db_counts_file)
        except OSError as e:
            snap["db"] = {"_error": str(e)}
    return snap


def cmd_snapshot(args):
    snap = build_snapshot(args.base, args.db_counts_file)
    text = json.dumps(snap, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print("snapshot written: %s" % args.out)
    else:
        print(text)

    hc = snap["healthcheck"]
    print()
    print("--- snapshot summary ---")
    print("target        : %s" % snap["target"])
    print("healthcheck   : HTTP %s" % hc.get("http_status"))
    bad = sorted(k for k, v in (hc.get("checks") or {}).items() if not v)
    print("checks failing: %s" % (", ".join(bad) if bad else "none"))
    print("plugins       : %s" % (", ".join(hc.get("plugins") or []) or "(none reported)"))
    growing = hc.get("queues_growing") or []
    print("queues growing: %s" % (", ".join(growing) if growing else "none"))
    print("failure keys  : %d" % len(snap["metrics"].get("failure_keys") or []))
    if "db" in snap and "_error" not in snap["db"]:
        db = snap["db"]
        print("db past_due   : %s  (must be 0)" % db.get("notifications.past_due_available", "n/a"))
        print("db bus_avail  : %s" % db.get("bus_events.available", "n/a"))

    # A snapshot is only returned healthy if the things Kill Bill itself names
    # are all true right now.
    if hc.get("http_status") != 200 or bad:
        return 1
    if growing:
        return 1
    db = snap.get("db") or {}
    if db.get("notifications.past_due_available") not in (0, None, "n/a"):
        return 1
    return 0


def cmd_diff(args):
    old = json.load(open(args.baseline, encoding="utf-8"))
    new = json.load(open(args.current, encoding="utf-8"))

    failures = []
    warnings = []
    notes = []

    ohc, nhc = old.get("healthcheck", {}), new.get("healthcheck", {})

    # 1. Any health check that was true and is now false.
    for name, was in (ohc.get("checks") or {}).items():
        now = (nhc.get("checks") or {}).get(name)
        if was and now is False:
            failures.append("healthcheck %s went healthy -> UNHEALTHY" % name)
        elif was and now is None:
            failures.append("healthcheck %s disappeared from the response" % name)

    # 2. NEW failing checks that were not in the baseline.
    for name, now in (nhc.get("checks") or {}).items():
        if name not in (ohc.get("checks") or {}) and now is False:
            failures.append("healthcheck %s is UNHEALTHY (absent from baseline)" % name)

    # 3. Plugin set must not shrink. This is the email-plugin assertion.
    old_plugins = set(ohc.get("plugins") or [])
    new_plugins = set(nhc.get("plugins") or [])
    for gone in sorted(old_plugins - new_plugins):
        failures.append("plugin %s was loaded in the baseline and is GONE" % gone)
    for added in sorted(new_plugins - old_plugins):
        notes.append("plugin %s is newly loaded" % added)

    # 4. Queues that started growing.
    og, ng = set(ohc.get("queues_growing") or []), set(nhc.get("queues_growing") or [])
    for q in sorted(ng - og):
        failures.append("queue %s is now GROWING (was not in baseline)" % q)
    for q in sorted(og - ng):
        notes.append("queue %s no longer growing" % q)

    # 5. New failure signals in metrics (restart-safe: membership, not values).
    ofk = set((old.get("metrics") or {}).get("failure_keys") or [])
    nfk = set((new.get("metrics") or {}).get("failure_keys") or [])
    for k in sorted(nfk - ofk):
        warnings.append("new failure metric: %s" % k)
    for k in sorted(ofk - nfk):
        notes.append("failure metric cleared: %s" % k)

    # 6. The DB half of Kill Bill's checklist.
    odb, ndb = old.get("db") or {}, new.get("db") or {}
    if ndb:
        past_due = ndb.get("notifications.past_due_available")
        if isinstance(past_due, int) and past_due > 0:
            failures.append(
                "notifications.past_due_available = %d (must be 0 -- Kill Bill is late)" % past_due
            )
        for label, before in sorted(odb.items()):
            if label.startswith("_") or label not in ndb:
                continue
            after = ndb[label]
            if isinstance(before, int) and isinstance(after, int) and before != after:
                line = "%s: %d -> %d (%+d)" % (label, before, after, after - before)
                if after < before and label.startswith("state."):
                    warnings.append("state DECREASED " + line)
                else:
                    notes.append(line)
    elif "db" in old and "db" not in new:
        warnings.append("baseline had DB counts but the current snapshot does not")

    print("=" * 68)
    print("KILL BILL REGRESSION DIFF")
    print("=" * 68)
    print("baseline : %s  (%s)" % (args.baseline, old.get("captured_at", "?")))
    print("current  : %s  (%s)" % (args.current, new.get("captured_at", "?")))
    print()

    for title, items in (("FAIL", failures), ("WARN", warnings), ("INFO", notes)):
        print("[%s] %d" % (title, len(items)))
        for i in items:
            print("   - %s" % i)
        print()

    if failures:
        print("RESULT: FAIL -- %d regression(s). Do not call the window done." % len(failures))
        return 1
    if warnings:
        print("RESULT: PASS with %d warning(s) -- review before declaring done." % len(warnings))
        return 2
    print("RESULT: PASS -- no regressions against the baseline.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", help="record current state as JSON")
    s.add_argument("--base", default=DEFAULT_BASE)
    s.add_argument("--out")
    s.add_argument("--db-counts-file", help="output of tools/kb-queue-health.sql")
    s.set_defaults(func=cmd_snapshot)

    d = sub.add_parser("diff", help="compare two snapshots")
    d.add_argument("baseline")
    d.add_argument("current")
    d.set_defaults(func=cmd_diff)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
