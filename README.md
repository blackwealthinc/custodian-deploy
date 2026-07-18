# Custodian Deploy — One-Curl Production Stack

Three scripts that build the entire Custodian AI platform from bare Ubuntu servers.

## Architecture

```
┌─────────────────────┐
│ 1. Database          │  PostgreSQL (Docker) — customers, usage, servers
└─────────┬───────────┘
          │
┌─────────▼───────────┐
│ 2. Budget Proxy      │  LiteLLM (Docker) — token counting, virtual keys
└─────────┬───────────┘
          │
┌─────────▼───────────┐
│ 3. Customer Servers  │  Hermes + Open WebUI (Docker Compose)
└─────────────────────┘
```

## Deployment Order

Always run in this order. Never skip. Never reverse.

```bash
# STEP 1 — Database (auto-generates password, no input needed)
curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-database.sh | sudo bash

# STEP 2 — Budget Proxy (requires DeepSeek key and domain)
DEEPSEEK_API_KEY=*** \
BUDGET_PROXY_DOMAIN=*** \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-budget-proxy.sh | sudo bash

# STEP 3 — Customer Server (requires Budget Proxy URL and customer virtual key)
CUSTOMER_API_KEY=*** \
BUDGET_PROXY_URL=https://budget.ns1net.com/v1 \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo bash
```

## Multi-Customer on One Server

```bash
# First customer
PORT=8601 WEBUI_PORT=3001 CUSTOMER_ID=maria \
  CUSTOMER_API_KEY=*** docker compose -p maria -f docker-compose.custodian-factory.yml up -d

# Second customer (does NOT touch first)
PORT=8602 WEBUI_PORT=3002 CUSTOMER_ID=john \
  CUSTOMER_API_KEY=*** docker compose -p john -f docker-compose.custodian-factory.yml up -d
```

## Requirements

- Ubuntu 22.04 or 24.04 LTS
- Root access
- Internet access
- DeepSeek API key (for Budget Proxy)

## Files

| File | Purpose |
|------|---------|
| `setup-database.sh` | Deploy PostgreSQL + schema |
| `schema.sql` | Database tables (customers, usage, servers) |
| `setup-budget-proxy.sh` | Deploy LiteLLM AI Gateway |
| `setup-custodian-factory.sh` | Deploy Hermes + Open WebUI |
| `docker-compose.custodian-factory.yml` | Compose file for customer servers |

## Docs

Full architecture: [Custodian Project Master Folder](https://github.com/blackwealthinc/custodian-deploy)
