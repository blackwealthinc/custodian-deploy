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
AVAILABLE notifications, UNKNOWN payments) is in tools/kb-queue-health.sql. Run
that through your privileged path and pass the output here with --db-counts-file.

CORE RULE (Bug #179): missing is not the same as unchanged. If the harness
cannot read a signal it is supposed to report, that is a FAIL -- never a pass.

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

    # assert the email plugin loaded after the window. The healthcheck's plugin
    # list cannot show plugins that register no Healthcheck service (the email
    # plugin registers none), so supply the authoritative list from the
    # privileged path -- GET /1.0/kb/pluginsInfo, one name per line:
    python3 tools/kb-regression.py diff baseline.json current.json \
        --plugins-file /tmp/plugins.txt --expect-plugin killbill-email-notifications

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

# The logging framework's own error counter is not an application failure: it is
# non-zero whenever anything logged at error level, which is not a regression.
# Reading it as "the system is failing" is a false positive. (Bug #179.)
NON_APP_METRIC_NAMESPACES = ("ch.qos.logback",)

# The full set of labels tools/kb-queue-health.sql emits. A snapshot missing any
# of these did not read the DB correctly. Missing is a read failure, not "no
# change" -- it must FAIL. Keep this in lockstep with the SQL file. (Bug #179.)
DB_REQUIRED_LABELS = (
    "bus_events.total",
    "bus_events.available",
    "bus_ext_events.total",
    "bus_ext_events.available",
    "notifications.past_due_available",
    "notifications.future_scheduled",
    "state.tenants",
    "state.accounts",
    "state.invoices",
    "state.subscriptions",
    "state.payments",
    "state.payment_methods",
    "state.blocking_states",
    "payments.unknown",
)


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

    The plugin list here comes from KillbillPluginsHealthcheck, which enumerates
    only plugins that registered a Healthcheck service. The email plugin registers
    none, so it can never appear here -- use --plugins-file for it (Bug #179).
    The queue `growing` field is likewise captured but is INFO-only: at the
    ~2.7 h poll interval of this deployment it can essentially never fire.
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
            if low.startswith(NON_APP_METRIC_NAMESPACES):
                continue
            if any(m in low for m in FAILURE_METRIC_MARKERS):
                failure_keys.append("%s:%s" % (section, key))

    return {"http_status": status, "failure_keys": sorted(set(failure_keys))}


def collect_db_counts(path):
    """Parse `label<TAB>value` output from tools/kb-queue-health.sql.

    Returns the parsed map, plus a ``_missing`` key listing any DB_REQUIRED_LABELS
    that were absent -- a partial read must FAIL, not silently pass. (Bug #179.)
    """
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
    missing = [lab for lab in DB_REQUIRED_LABELS if lab not in counts]
    if missing:
        counts["_missing"] = missing
    return counts


def load_plugin_list(path):
    """Read an authoritative plugin-name list (one per line, # comments ignored).

    Produce it from the privileged path with GET /1.0/kb/pluginsInfo, e.g.:
        curl -s -u admin:password -H 'X-Killbill-ApiKey: ...' \
          http://localhost:8080/1.0/kb/pluginsInfo | jq -r '.[].pluginName' \
          > /tmp/plugins.txt
    (the exact jq path is proven in the Phase 2 rehearsal, not guessed here.)
    """
    names = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            names.append(line)
    return names


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
    print("queues growing: %s (INFO only -- poll interval makes this unreliable)"
          % (", ".join(growing) if growing else "none"))
    print("failure keys  : %d" % len(snap["metrics"].get("failure_keys") or []))
    if "db" in snap and "_error" not in snap["db"]:
        db = snap["db"]
        print("db past_due   : %s  (must be 0)" % db.get("notifications.past_due_available", "n/a"))
        print("db unknown pay: %s  (must be 0)" % db.get("payments.unknown", "n/a"))
        print("db bus_avail  : %s" % db.get("bus_events.available", "n/a"))
        if db.get("_missing"):
            print("db MISSING    : %s" % ", ".join(db["_missing"]))

    # A snapshot is only returned healthy if the things Kill Bill itself names
    # are all true right now -- and if every signal was actually readable.
    if hc.get("http_status") != 200 or bad:
        return 1
    if (snap.get("metrics") or {}).get("http_status") != 200:
        return 1
    db = snap.get("db") or {}
    if db.get("notifications.past_due_available") not in (0, None, "n/a"):
        return 1
    if db.get("payments.unknown") not in (0, None, "n/a"):
        return 1
    if db.get("_missing"):
        return 1
    return 0


def cmd_diff(args):
    old = json.load(open(args.baseline, encoding="utf-8"))
    new = json.load(open(args.current, encoding="utf-8"))

    failures = []
    warnings = []
    notes = []

    ohc, nhc = old.get("healthcheck", {}), new.get("healthcheck", {})

    # 0. An endpoint that is down NOW is a failure in itself. During a window the
    #    most likely breakage is the engine or metrics endpoint going down, and
    #    that must read as FAIL, never as "no change". (Bug #179.)
    for label, side in (
        ("healthcheck", nhc),
        ("metrics", new.get("metrics") or {}),
    ):
        if side.get("http_status") != 200:
            failures.append("%s endpoint returned HTTP %s (must be 200)"
                            % (label, side.get("http_status")))

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

    # 3. Plugin set must not shrink (healthcheck-derived list).
    old_plugins = set(ohc.get("plugins") or [])
    new_plugins = set(nhc.get("plugins") or [])
    for gone in sorted(old_plugins - new_plugins):
        failures.append("plugin %s was loaded in the baseline and is GONE" % gone)
    for added in sorted(new_plugins - old_plugins):
        notes.append("plugin %s is newly loaded" % added)

    # 3b. An expected plugin must be PRESENT. The healthcheck list cannot show a
    #     plugin with no Healthcheck service, so --expect-plugin is checked against
    #     the healthcheck list UNION the --plugins-file list. (Bug #179.)
    authoritative_plugins = set(new_plugins)
    if getattr(args, "plugins_file", None):
        authoritative_plugins |= set(load_plugin_list(args.plugins_file))
    if getattr(args, "expect_plugin", None):
        if args.expect_plugin not in authoritative_plugins:
            failures.append("expected plugin %s is NOT loaded (--expect-plugin)"
                            % args.expect_plugin)
        else:
            notes.append("expected plugin %s is loaded" % args.expect_plugin)

    # 4. Queues that started growing -- INFO only (see Bug #179).
    og, ng = set(ohc.get("queues_growing") or []), set(nhc.get("queues_growing") or [])
    for q in sorted(ng - og):
        notes.append("queue %s is now GROWING (INFO only -- poll interval makes this unreliable)" % q)
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
    if ndb.get("_error"):
        failures.append("DB read error: %s" % ndb["_error"])
    # Missing is not unchanged. If the baseline carried a DB read, the current
    # snapshot must carry a complete one too -- absent, empty, or partial all FAIL.
    had_db = bool(odb) and not odb.get("_error")
    if had_db:
        if "db" not in new:
            failures.append("baseline had DB counts but the current snapshot has none")
        elif not ndb or ndb.get("_error"):
            failures.append("DB read produced no usable counts (empty or errored)")
        else:
            missing_now = [lab for lab in DB_REQUIRED_LABELS if lab not in ndb]
            if missing_now:
                failures.append("DB read missing labels: %s" % ", ".join(missing_now))
    if ndb and not ndb.get("_error"):
        past_due = ndb.get("notifications.past_due_available")
        if isinstance(past_due, int) and past_due > 0:
            failures.append(
                "notifications.past_due_available = %d (must be 0 -- Kill Bill is late)" % past_due
            )
        unknown_pay = ndb.get("payments.unknown")
        if isinstance(unknown_pay, int) and unknown_pay > 0:
            failures.append(
                "payments.unknown = %d (must be 0 -- manual fix via Payment Admin API)" % unknown_pay
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
    d.add_argument("--expect-plugin", help="assert this plugin is loaded in the current snapshot")
    d.add_argument("--plugins-file", help="authoritative plugin list (one name per line) from GET /1.0/kb/pluginsInfo")
    d.set_defaults(func=cmd_diff)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
