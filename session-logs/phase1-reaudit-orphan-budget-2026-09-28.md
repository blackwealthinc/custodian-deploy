# Phase 1 re-audit — orphaned budget repair + provisioning regression (2026-09-28)

**Date:** 2026-09-28
**Found by:** adversarial re-audit of a completed phase ("reaudit, strongman your analysis")
**Severity:** High (customer-billable behaviour) + High (provisioning path)
**Status:** Fixed, verified live, tooling shipped

A re-audit of Phase 1 found the phase was **not** fully done. Two defects, one of them
self-inflicted by the Phase 1 rename itself.

---

## Defect 1 — the rename broke the PROVISIONING path (self-inflicted)

Phase 1 renamed the LiteLLM image alias `gpt-image-2-hd` → `gpt-image-2`. The live host was
updated and verified, but the **repo** was never swept, so the code path that runs on the
*next* deployment still used the retired name.

| file | line | problem |
|---|---|---|
| `docker-compose.custodian-factory.yml` | ~82 | `IMAGE_GENERATION_MODEL=gpt-image-2-hd` (dead model) |
| `setup-custodian-factory.sh` | 39 | new customer keys created with the dead alias in their `models` list |
| `setup-custodian-factory.sh` | 816 | wrote the dead name into the Open WebUI config table |
| `setup-custodian-factory.sh` | 661 | stale model row |

**Impact:** a freshly provisioned reseller would have had a key unable to reach the image model
and a UI pointed at a name that no longer exists. Existing deployments were unaffected — which is
precisely why live testing had passed and hid the regression.

**Why the WebUI database write was inert (and the env var was the real fix):** Open WebUI runs
here with `ENABLE_PERSISTENT_CONFIG=false`, and its official docs state that in that mode the app
"always use[s] your environment variables (ignoring the database)" and that Admin-UI edits
"are NOT saved". Confirmed empirically too: the live database still read the retired name while
image generation worked.

**Deliberately left alone:** the legacy-cleanup `DELETE` at `setup-custodian-factory.sh:643`
targets rows created by *pre-rename* deploys, so it **must** keep the old string. Changing it
would retarget the query and risk deleting the current, working model row.

**Fix:** commit `a0b0b6c`.

---

## Defect 2 — keys whose budget never resets

LiteLLM's reset job only selects rows whose `budget_reset_at` is in the past. A key carrying a
direct `max_budget` with **no `budget_id`** and **no `budget_duration`** is a *one-time budget*:
`budget_reset_at` is never set, so spend accumulates to the ceiling and the key stays blocked
**permanently**.

Found: `admin` ($100) and the blank-alias key ($50).

**Not a defect:** a key **with** a `budget_id` inherits that budget object's schedule and keeps
its own `budget_duration` NULL **by design** — so `cust-demo-001` reading NULL is correct.

**Fix:** `POST /key/update` with the key's sha256 hash and `budget_duration: "1mo"` →
`http 200`, then verified by re-reading the table (not the API response).

**Why a hash works:** `_hash_token_if_needed()` hashes only values starting with `sk-`, so the
stored hash is used as-is. The plaintext key is never needed.

---

## Verification that mattered

The reset mechanism had been gated on "wait for the 2026-10-01 calendar reset". That was the wrong
test: the reset job is an APScheduler interval of **597–605 s**, so it can be observed directly.

Disposable key, `budget_duration=30s`:

```
baseline  spend 0 → 1.05e-05 after one tiny request;  budget_reset_at 22:37:00
observed  spend → 0;                                  budget_reset_at → 22:44:00
cleanup   /key/delete → http 200, 0 rows remaining
```

The live keys' `2026-10-01` reset is therefore backed by a **proven mechanism** rather than a wait.

---

## Tooling shipped

- **`fix-orphan-budget-durations.sh`** — detect / `--apply` / `--clear --only <alias>`.
  `--clear` **requires** `--only` and refuses bulk reverts, because a blanket revert would also
  clear keys that were deliberately repaired.
- **`verify-budget-reset.sh`** — proves the reset job fires, on a disposable key it deletes itself
  in an `EXIT` trap.

Both: `shellcheck -S warning` clean, `bash -n` clean.

> **The first version of `fix-orphan-budget-durations.sh` had a real bug.** `--clear` re-derived
> its targets from the orphan query, which matches nothing after `--apply` — so it silently did
> nothing. Running the script is what caught it; reading it did not.

---

## Lessons

1. A config change that only affects **future** writes does not repair **existing** state — verify
   the row, not the service.
2. A rename is not done until the **repo** is swept, not only the live host. Test the code path
   that runs *later*, not just the one running *now*.
3. Fix by research, not by pattern-matching. The fixes were right; only the research made them
   defensible.
4. Public documentation can be incomplete — the pinned source is authoritative. (The docs omit
   `mo` entirely as a duration unit, and never mention that `2mo` raises or that an unparseable
   duration silently falls back to a **daily** reset.)
5. Test the tool you just wrote, or it ships broken.
