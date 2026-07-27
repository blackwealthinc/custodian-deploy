# Bug #34 — JSON Column Corruption in config.value

**Discovered:** 2026-07-27  
**Severity:** 🔴 CRITICAL  
**Location:** `setup-custodian-factory.sh`, Step 5b (lines 234-255)  
**Affected:** All existing and future Dell deployments

## Symptoms

- Open WebUI Admin Panel → Settings → Web Search shows **blank page**
- Web search toggle not visible in chat input
- `JSONDecodeError` in WebUI container logs:
  ```
  json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
  File "sqlalchemy/sql/sqltypes.py", line 2821, in process
      return json_deserializer(value)
  ```

## Root Cause

Step 5b writes raw Python strings directly into SQLAlchemy's `JSON` column using Python's `sqlite3` module. SQLAlchemy expects JSON-encoded text in the `config.value` column — it calls `json.loads()` on every read.

| Key | What Step 5b stores | What SQLAlchemy expects | Result |
|---|---|---|---|
| `web.search.enable` | `true` | `true` | ✅ Works by accident |
| `web.search.engine` | `searxng` | `"searxng"` | ❌ `json.loads('searxng')` crashes |
| `web.search.searxng_query_url` | `http://...` | `"http://..."` | ❌ `json.loads('http://...')` crashes |

The crash happens when the admin page calls `Config.get_namespace('web.search')`, which reads ALL web.search keys via SQLAlchemy, including the corrupt ones.

## Fix

### Dell (immediate repair)

```bash
docker exec admin-webui python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')
conn.execute('UPDATE config SET value=? WHERE key=?',
    (json.dumps('searxng'), 'web.search.engine'))
conn.execute('UPDATE config SET value=? WHERE key=?',
    (json.dumps('http://searxng:8080/search?q=<query>'), 'web.search.searxng_query_url'))
conn.commit()
conn.close()
print('FIXED')
"
docker restart admin-webui
```

### Curl (prevent recurrence)

In Step 5b, wrap all values with `json.dumps()`:

```python
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')

configs = [
    ('web.search.enable', json.dumps(True)),
    ('web.search.engine', json.dumps('searxng')),
    ('web.search.searxng_query_url', json.dumps('http://searxng:8080/search?q=<query>')),
]
```

## Prevention Rule

**Never write raw strings to a SQLAlchemy JSON column via raw sqlite3.** Always use `json.dumps(val)` or SQLite's `json()` function:

```sql
INSERT OR REPLACE INTO config (key, value) VALUES ('web.search.engine', json('searxng'));
```

## Related

- Bug #33 (stale COMPOSE_URL) — same script, similar "tested wrong" pattern
- Incident Pattern #2 from agent-mistake-pattern-fix-2026-07-15.md: fixing one component without checking dependents
