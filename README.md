# n8n — Fully Private Docker Deployment

A production-grade, privacy-first n8n setup with **zero telemetry**, **domain-whitelisted egress**, and **defense-in-depth** network isolation.

---

## Architecture

```text
HOST MACHINE

  frontend-net (host access)
    localhost:5678
         |
         v
      [n8n-web]
         |
         v
  internal-net (172.20.0.0/24, internal: true)
    [n8n] <----> [postgres]
      |
      | proxy
      v
    [squid-proxy]
         |
         v
  egress-net (172.20.1.0/24)
         |
         v
      Internet

Allowed:  .yourcompany.com, api.openai.com
Blocked:  telemetry.n8n.io, *.google.com, everything else
```

### Security layers

| Layer | Component | What it blocks |
|-------|-----------|----------------|
| **L1** | n8n env vars | n8n-level telemetry calls disabled at the app level |
| **L2** | Docker `internal: true` | No gateway on internal-net → containers physically can't route to internet |
| **L2.5** | `n8n-web` reverse proxy | Publishes `localhost:5678` without attaching `n8n` itself to a non-internal network |
| **L3** | Squid ACL whitelist | HTTP/HTTPS proxy enforces domain allowlist; denies everything else |
| **L4** | iptables DOCKER-USER | Kernel drops any packet from internal-net not destined for egress-net |

---

## Quick Start

### 1. Clone & configure

```bash
git clone https://github.com/yourcompany/n8n-private
cd n8n-private

# Create your .env from the template
cp .env.example .env
```

Edit `.env` and set at minimum:
- `COMPANY_DOMAIN` — your company domain (e.g. `yourcompany.com`)
- `COPILOT_DOMAIN` — your AI/copilot API domain (e.g. `api.openai.com`)
- `N8N_BASIC_AUTH_PASSWORD` — strong password
- `N8N_ENCRYPTION_KEY` — 32-char hex: `openssl rand -hex 32`
- `POSTGRES_PASSWORD` — strong DB password

### 2. Generate whitelist

```bash
chmod +x scripts/update-whitelist.sh
./scripts/update-whitelist.sh
```

This reads `COMPANY_DOMAIN`, `COPILOT_DOMAIN`, and `EXTRA_ALLOWED_DOMAINS` from `.env` and writes `squid/whitelist.acl`.

If you want `scripts/test-proxy.sh` to validate wildcard matching against a real subdomain, also set `COMPANY_TEST_SUBDOMAIN` in `.env` (for example `app.yourcompany.com`). If it is unset, the script skips the subdomain check instead of guessing `sub.<domain>`.

### 3. Start services

```bash
docker compose up -d
```

On Docker Desktop / Windows, `n8n` itself is intentionally **not** published directly. Instead, the `n8n-web` container publishes `localhost:5678` and reverse-proxies to `n8n` over the internal Docker network. This avoids the host reachability issue that occurs when a service is attached only to an `internal: true` network.

### 4. Apply host firewall (recommended — requires root)

```bash
sudo chmod +x scripts/iptables-setup.sh
sudo ./scripts/iptables-setup.sh
```

> On Windows hosts, skip this step. `scripts/iptables-setup.sh` is Linux-only and cannot run under Docker Desktop/Windows PowerShell.

### 5. Make firewall persistent across reboots

```bash
# Option A — iptables-persistent (Ubuntu/Debian)
sudo apt install iptables-persistent
sudo netfilter-persistent save

# Option B — systemd service
sudo cp scripts/n8n-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now n8n-firewall.service
```

---

## Updating the Domain Whitelist

Edit `.env`, change `COMPANY_DOMAIN`, `COPILOT_DOMAIN`, or `EXTRA_ALLOWED_DOMAINS`, then:

```bash
./scripts/update-whitelist.sh
docker compose restart squid-proxy
```

The whitelist takes effect immediately. No n8n restart needed.

---

## Verifying Isolation

### Test that telemetry is blocked
```bash
# Should fail / time out (telemetry.n8n.io is NOT whitelisted)
docker exec n8n wget -q --timeout=5 -Y on -O- https://telemetry.n8n.io || echo "BLOCKED ✅"
```

### Test that your company domain is reachable
```bash
# Should succeed (routed through Squid)
docker exec -e https_proxy=http://squid-proxy:3128 n8n \
  wget -q --timeout=10 -Y on -O- https://yourcompany.com && echo "ALLOWED ✅"
```

### Test that a random domain is blocked
```bash
# Should fail with 403 from Squid
docker exec -e https_proxy=http://squid-proxy:3128 n8n \
  wget -q --timeout=10 -Y on -O- https://google.com || echo "BLOCKED ✅"
```

### View Squid access logs (real-time)
```bash
docker exec n8n-squid tail -f /var/log/squid/access.log
```

---

## Telemetry Variables Reference

All n8n phone-home mechanisms are disabled:

| Variable | Value | Purpose |
|----------|-------|---------|
| `N8N_DIAGNOSTICS_ENABLED` | `false` | Disables all usage analytics |
| `N8N_DIAGNOSTICS_CONFIG_FRONTEND` | `""` | Clears frontend telemetry server URL |
| `N8N_DIAGNOSTICS_CONFIG_BACKEND` | `""` | Clears backend telemetry server URL |
| `N8N_VERSION_NOTIFICATIONS_ENABLED` | `false` | No version check pings to n8n servers |
| `N8N_TEMPLATES_ENABLED` | `false` | No template fetches from n8n template store |
| `EXTERNAL_FRONTEND_HOOKS_URLS` | `""` | Clears frontend hook JS fetch URL |
| `N8N_ONBOARDING_FLOW_DISABLED` | `true` | No onboarding prompt fetches |
| `N8N_COMMUNITY_PACKAGES_ENABLED` | `false` | No community package registry calls |

---

## Egress Control — Technical Deep Dive

### Why not just block in the Docker network?

`internal: true` alone is insufficient if a container is also attached to an external network (which Squid is, by design). We need **three layers**:

1. **`internal: true`** on n8n's network → no default gateway, packets have nowhere to go
2. **Squid proxy** → the ONLY exit point; enforces domain ACL
3. **iptables DOCKER-USER** → kernel-enforced; blocks any traffic from internal-net that somehow escapes

### Why Squid and not nginx?

| | nginx stream | Squid forward proxy |
|-|--------------|---------------------|
| Domain-based filtering | ❌ One container per domain | ✅ Single container, ACL file |
| HTTPS (CONNECT) | ✅ TCP passthrough | ✅ CONNECT tunneling |
| Logging | Limited | ✅ Full audit log per request |
| ACL flexibility | None | ✅ Regex, time, IP, method |
| Transparent proxy | With extra work | ✅ Native |

### Why not iptables alone?

iptables works on IPs, not domain names. A domain's IP set changes frequently (CDN, load balancers). You'd need to maintain a constantly-refreshing IP set, which is brittle. Squid resolves DNS at request time and applies domain rules correctly.

---

## Production Hardening Checklist

- [ ] Set `N8N_SECURE_COOKIE=true` and put n8n behind HTTPS (nginx/Caddy reverse proxy)
- [ ] Replace `N8N_BASIC_AUTH` with LDAP/SAML if on Enterprise tier
- [ ] Pin `N8N_VERSION` to a specific tag (e.g. `1.45.0`) — avoid `latest` in production
- [ ] Enable PostgreSQL SSL (`DB_POSTGRESDB_SSL_ENABLED=true`)
- [ ] Add Squid log rotation (`logrotate`)
- [ ] Set up volume backups for `n8n-postgres-data` and `n8n-app-data`
- [ ] Run `sudo ./scripts/iptables-setup.sh` and persist with systemd service
- [ ] Restrict `.env` permissions: `chmod 600 .env`
- [ ] Review `EXTRA_ALLOWED_DOMAINS` — only add what workflows strictly need

---

## File Structure

```
n8n-private/
├── docker-compose.yml          # Main service definitions
├── .env.example                # Template — copy to .env
├── .env                        # YOUR secrets (gitignored)
├── .gitignore
├── nginx/
│   └── n8n.conf                # Reverse proxy exposing localhost:5678
├── squid/
│   ├── squid.conf              # Squid proxy configuration
│   └── whitelist.acl           # Domain allowlist (generated)
└── scripts/
    ├── update-whitelist.sh     # Regenerate whitelist from .env
    ├── iptables-setup.sh       # Apply host firewall rules
    └── n8n-firewall.service    # Systemd unit for persistent firewall
```