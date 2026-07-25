# Custodian — All Curl Commands (Home Lab / Internal-Only)

**Date:** July 24, 2026  
**Status:** Current for home lab setup — VM 205 + Dell + Linode  
**Production variant:** See `all-curl-commands-reference.md` for Cloudflare/production version

---

## PREREQUISITES

All machines must be on the Tailscale mesh via Headscale (Linode).
- **Headscale:** `https://vpn.ns1net.com`
- **Tailscale IPs:** VM 205 = `100.64.0.1` | Dell = `100.64.0.2`

---

## STEP 0 — SearXNG (Run ONCE per physical server, BEFORE any customers)

SearXNG is shared infrastructure — one instance serves all customers on the same machine. Run this first, before deploying any customer stacks.

```bash
curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-searxng.sh | sudo -E bash
```

**No parameters needed.** Creates SearXNG + Valkey (Redis cache) containers. Hermes instances deployed later will auto-connect.

**Access:** `http://<SERVER_IP>:8888`

---

## STEP 1 — Database (VM 205)

```bash
curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-database.sh | sudo -E bash
```

**No parameters needed.** Sets up PostgreSQL 16 in Docker at `127.0.0.1:5432`.

**Credentials saved to:** `/opt/custodian-db/.db-credentials`

---

## STEP 2 — Budget Proxy (VM 205)

```bash
export DEEPSEEK_API_KEY=*** && \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-budget-proxy.sh | sudo -E bash
```

**`DEEPSEEK_API_KEY`** — Your real DeepSeek API key. The script passes it to LiteLLM which stores it in `/opt/litellm/litellm_config.yaml`. The Customer Server never sees this key.

**What it creates:**
- LiteLLM proxy in Docker (`litellm-proxy`) on port 4000
- Master key (in `litellm_config.yaml`)
- Dashboard at `http://100.64.0.1:4000`

**After this runs**, generate a virtual key for each customer:

```bash
# Generate a key (run on VM205 after setup-budget-proxy.sh)
curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer *** \
  -H "Content-Type: application/json" \
  -d '{"key_alias": "admin", "models": ["deepseek-v4-pro"], "max_budget": 100, "budget_duration": "1mo"}'
```

The response contains `"key": "sk-..."` — this is your `CUSTOMER_API_KEY`.  
**Create one key per customer.** LiteLLM tracks spend per key automatically at `http://100.64.0.1:4000/ui`.

---

## STEP 3 — Deep Research (Run ONCE per server, after SearXNG)

GPT Researcher adds autonomous deep research — multi-step web scraping with cited reports.

```bash
export CUSTOMER_API_KEY=*** && \
export BUDGET_PROXY_URL=http://100.64.0.1:4000/v1 && \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-deep-research.sh | sudo -E bash
```

**API on port 8000.** Test with: `curl -X POST http://localhost:8000/research -d '{"query":"your topic"}'`

---

## STEP 4 — Customer Server (First Customer)

The default CUSTOMER_ID is `custodian`. Default ports: Hermes 8642, OpenWebUI 3000.

```bash
export CUSTOMER_API_KEY=*** && \
export BUDGET_PROXY_URL=http://100.64.0.1:4000/v1 && \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo -E bash
```

**`CUSTOMER_API_KEY`** — The virtual key from Step 2. NOT the real DeepSeek key.  
**`BUDGET_PROXY_URL`** — `http://100.64.0.1:4000/v1` (VM 205 via Tailscale, internal-only).

**What it creates:**
- Hermes Agent (port 8642) — auto-connected to SearXNG + Budget Proxy
- Open WebUI (port 3000) — auto-connected to Hermes

**Access:** `http://<SERVER_IP>:3000`

---

## ADDING MORE CUSTOMERS (Same Server or New Server)

**This is the same curl command — just different variables.** Run it once per customer. Docker Compose isolates each customer by project name. They don't replace or interfere with each other.

```bash
# Customer 2 (William)
export CUSTOMER_API_KEY=*** && \
export BUDGET_PROXY_URL=http://100.64.0.1:4000/v1 && \
export CUSTOMER_ID=william && \
export PORT=8643 && \
export WEBUI_PORT=3001 && \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo -E bash

# Customer 3 (Gabriel)
export CUSTOMER_API_KEY=*** && \
export BUDGET_PROXY_URL=http://100.64.0.1:4000/v1 && \
export CUSTOMER_ID=gabriel && \
export PORT=8644 && \
export WEBUI_PORT=3002 && \
  curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo -E bash
```

**Rules for adding customers:**
- Each customer needs their own virtual key (generate in LiteLLM dashboard at `http://100.64.0.1:4000`)
- Each customer needs UNIQUE ports — pick any unused ports
- CUSTOMER_ID must be unique per server
- Run SearXNG (Step 0) FIRST on each new server before adding customers

**Result on the same server:**
```
custodian-hermes   :8642    custodian-webui   :3000
william-hermes     :8643    william-webui     :3001
gabriel-hermes     :8644    gabriel-webui     :3002
```

---

## ADDITIONAL COMMANDS

### Connect a Machine to Tailscale

```bash
tailscale up \
  --login-server https://vpn.ns1net.com \
  --authkey <PREAUTH_KEY> \
  --force-reauth
```

### Generate a Preauth Key (on Linode)

```bash
ssh root@45.79.19.91
docker exec headscale headscale preauthkeys create --user 1 --reusable --expiration 8760h
```

### Check Tailscale Nodes (on Linode)

```bash
ssh root@45.79.19.91
docker exec headscale headscale nodes list
```

### Check Budget Proxy Health

```bash
curl http://100.64.0.1:4000/health
```

### Check LiteLLM Dashboard

Browser → `http://100.64.0.1:4000`

### Check SearXNG Health

```bash
curl http://localhost:8888/search?q=test
```
Expected: HTTP 200, 302, or 303 (redirect to results page).

### Manage Customers (LiteLLM Dashboard)

Browser → `http://100.64.0.1:4000/ui`
- **Keys tab**: See every customer key, spend, budget remaining
- **Users tab**: Create/delete users, assign to keys
- **Spend Logs**: Every API call logged with model, tokens, cost
- **Create a key**: Click "Create Key" → set alias, budget, models → copy the key for the curl command

---

## NETWORK MAP

```
Linode (45.79.19.91) — Headscale + Caddy
   └─ vpn.ns1net.com (Cloudflare proxied, port 443)

VM 205 (100.64.0.1) — PostgreSQL :5432 + LiteLLM :4000
Dell  (100.64.0.2) — SearXNG :8888 + Hermes :8642-8644 + Open WebUI :3000-3002

Chat flow:    Dell:3000 → Hermes:8642 → LiteLLM:4000 → DeepSeek
Search flow:  Hermes → SearXNG:8080 (internal Docker network)
```

---

## KEY DIFFERENCES FROM PRODUCTION

| Setting | Internal | Production |
|---------|----------|------------|
| `BUDGET_PROXY_URL` | `http://100.64.0.1:4000/v1` | `https://budget.ns1net.com/v1` |
| DNS needed | No | Yes (Cloudflare) |
| Connectivity | Tailscale mesh | Public internet via Cloudflare |
| SSL on proxy | No (internal) | Yes (Let's Encrypt + Cloudflare) |
