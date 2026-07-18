-- ============================================================================
-- Custodian — Central Database Schema
-- Repository: https://github.com/blackwealthinc/custodian-deploy
-- ============================================================================
-- Tables: customers, usage, servers
-- Auto-loaded by PostgreSQL Docker on first run via docker-entrypoint-initdb.d/
-- ============================================================================

-- ── CUSTOMERS ──
CREATE TABLE IF NOT EXISTS customers (
    id              SERIAL PRIMARY KEY,
    customer_id     TEXT UNIQUE NOT NULL,          -- "maria-bakery"
    email           TEXT,                           -- "maria@example.com"
    plan            TEXT DEFAULT 'starter',         -- starter / pro / enterprise
    api_key         TEXT,                           -- virtual key from Budget Proxy
    server_ip       TEXT,                           -- which server hosts them
    container_port  INTEGER,                        -- which port on that server
    billing_status  TEXT DEFAULT 'active',          -- active / suspended / cancelled
    subscription_start  TIMESTAMP,
    subscription_end    TIMESTAMP,
    space_retention_days INTEGER DEFAULT 30,
    token_retention_days  INTEGER DEFAULT 60,
    auto_renew      BOOLEAN DEFAULT true,
    notification_stage TEXT DEFAULT 'none',         -- none / warning / final
    archive_path    TEXT,
    created_at      TIMESTAMP DEFAULT NOW()
);

-- ── USAGE ──
CREATE TABLE IF NOT EXISTS usage (
    id              SERIAL PRIMARY KEY,
    customer_id     TEXT NOT NULL,                  -- "maria-bakery"
    tokens_in       INTEGER DEFAULT 0,
    tokens_out      INTEGER DEFAULT 0,
    model           TEXT DEFAULT 'deepseek-chat',
    timestamp       TIMESTAMP DEFAULT NOW(),
    cost_usd        REAL DEFAULT 0.0
);

CREATE INDEX IF NOT EXISTS idx_usage_customer ON usage(customer_id);
CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage(timestamp);

-- ── SERVERS ──
CREATE TABLE IF NOT EXISTS servers (
    id              SERIAL PRIMARY KEY,
    server_name     TEXT UNIQUE,                    -- "contabo-cust-01"
    provider        TEXT DEFAULT 'contabo',
    provider_id     TEXT,
    ip_address      TEXT NOT NULL,
    region          TEXT,
    spec            TEXT,
    customer_count  INTEGER DEFAULT 0,
    max_customers   INTEGER DEFAULT 8,
    status          TEXT DEFAULT 'provisioning',    -- provisioning / active / draining / offline
    monthly_cost    DECIMAL(10,2),
    created_at      TIMESTAMP DEFAULT NOW(),
    last_health_check TIMESTAMP
);

-- ── INITIAL SERVER ROW ──
-- The database script inserts this row itself, but if schema is loaded 
-- manually via docker-entrypoint-initdb.d, we insert a placeholder that 
-- the setup script updates with actual server info.
INSERT INTO servers (server_name, ip_address, status, max_customers)
VALUES ('budget-proxy', '127.0.0.1', 'provisioning', 1)
ON CONFLICT (server_name) DO NOTHING;
