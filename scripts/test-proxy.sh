#!/usr/bin/env bash
# =============================================================================
# test-proxy.sh — Squid Egress Whitelist Validation Suite
# =============================================================================
# Tests that:
#   ✅ Whitelisted domains (company, copilot, extras) are reachable via Squid
#   ❌ Blocked domains (n8n telemetry, common internet, data brokers) are denied
#
# Uses raw CONNECT through Squid via nc — no DNS required on the n8n container.
# A 200 response = Squid allowed the tunnel.
# A 403/407 response = Squid blocked it.
#
# Usage:
#   ./scripts/test-proxy.sh             (reads ../.env)
#   ./scripts/test-proxy.sh /path/.env  (reads custom .env)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${1:-$PROJECT_DIR/.env}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Counters ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
TOTAL=0

# Populated after .env is loaded — holds every whitelisted base domain (no leading dot)
ALLOWED_DOMAINS_LIST=()

# =============================================================================
# Helpers
# =============================================================================

header() {
  echo ""
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# Send HTTP CONNECT to Squid from inside the n8n container via nc.
# Returns the first line of Squid's response (e.g. "HTTP/1.1 200 Connection established")
squid_connect() {
  local domain="$1"
  local port="${2:-443}"
  # nc with 5s timeout; send CONNECT, read first line of response
  docker exec n8n sh -c \
    "printf 'CONNECT ${domain}:${port} HTTP/1.1\r\nHost: ${domain}\r\n\r\n' \
     | nc -w 5 squid-proxy 3128 2>/dev/null \
     | head -1 | tr -d '\r'"
}

# Check that a domain IS allowed (expects HTTP 200 from Squid)
expect_allowed() {
  local domain="$1"
  local port="${2:-443}"
  local label="${3:-$domain}"
  TOTAL=$((TOTAL + 1))

  local response
  response="$(squid_connect "$domain" "$port" 2>/dev/null || true)"
  local http_code
  http_code="$(echo "$response" | awk '{print $2}')"

  if [[ "$http_code" == "200" ]]; then
    echo -e "  ${GREEN}✅ ALLOWED${RESET}   $label"
    echo -e "             ${YELLOW}↳ Squid: $response${RESET}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌ FAIL${RESET}      $label  ${BOLD}(expected ALLOWED)${RESET}"
    echo -e "             ${YELLOW}↳ Squid: ${response:-no response / timeout}${RESET}"
    FAIL=$((FAIL + 1))
  fi
}

# Returns 0 (true) if the given domain matches any entry in ALLOWED_DOMAINS_LIST.
# Mirrors Squid dstdomain matching: allowed base domain covers itself + all subdomains.
is_whitelisted() {
  local domain="${1,,}"
  domain="${domain#.}"
  for allowed in "${ALLOWED_DOMAINS_LIST[@]}"; do
    allowed="${allowed,,}"
    allowed="${allowed#.}"
    [[ "$domain" == "$allowed" ]] && return 0
    [[ "$domain" == *".${allowed}" ]] && return 0
  done
  return 1
}

# Wrapper around expect_blocked: skips the check when the domain is whitelisted
# to avoid false failures if someone intentionally added it to EXTRA_ALLOWED_DOMAINS.
safe_expect_blocked() {
  local domain="$1"
  local port="${2:-443}"
  local label="${3:-$domain}"
  if is_whitelisted "$domain"; then
    echo -e "  ${YELLOW}\u26a0\ufe0f  SKIPPED${RESET}    $label"
    echo -e "             ${YELLOW}\u21b3 In your whitelist \u2014 remove from EXTRA_ALLOWED_DOMAINS if unintentional${RESET}"
    SKIP=$((SKIP + 1))
    return
  fi
  expect_blocked "$domain" "$port" "$label"
}


# Check that a domain IS blocked (expects HTTP 403 from Squid)
expect_blocked() {
  local domain="$1"
  local port="${2:-443}"
  local label="${3:-$domain}"
  TOTAL=$((TOTAL + 1))

  local response
  response="$(squid_connect "$domain" "$port" 2>/dev/null || true)"
  local http_code
  http_code="$(echo "$response" | awk '{print $2}')"

  if [[ "$http_code" == "403" ]]; then
    echo -e "  ${GREEN}✅ BLOCKED${RESET}   $label"
    echo -e "             ${YELLOW}↳ Squid: $response${RESET}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌ FAIL${RESET}      $label  ${BOLD}(expected BLOCKED)${RESET}"
    echo -e "             ${YELLOW}↳ Squid: ${response:-no response / timeout}${RESET}"
    FAIL=$((FAIL + 1))
  fi
}

# =============================================================================
# Load .env
# =============================================================================

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}❌  .env not found at: $ENV_FILE${RESET}"
  exit 1
fi

COMPANY_DOMAIN=""
COPILOT_DOMAIN=""
EXTRA_ALLOWED_DOMAINS=""

while IFS='=' read -r key value; do
  [[ "$key" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$key" ]] && continue
  value="$(echo "$value" | sed 's/#.*//' | xargs)"
  case "$key" in
    COMPANY_DOMAIN)        COMPANY_DOMAIN="$value" ;;
    COPILOT_DOMAIN)        COPILOT_DOMAIN="$value" ;;
    EXTRA_ALLOWED_DOMAINS) EXTRA_ALLOWED_DOMAINS="$value" ;;
  esac
done < "$ENV_FILE"

# ── Build ALLOWED_DOMAINS_LIST for is_whitelisted() ──────────────────────────
[[ -n "$COMPANY_DOMAIN" ]] && ALLOWED_DOMAINS_LIST+=("$COMPANY_DOMAIN")
if [[ -n "$COPILOT_DOMAIN" ]]; then
  ALLOWED_DOMAINS_LIST+=("${COPILOT_DOMAIN#.}")
fi
if [[ -n "$EXTRA_ALLOWED_DOMAINS" ]]; then
  IFS=',' read -ra _extras <<< "$EXTRA_ALLOWED_DOMAINS"
  for _d in "${_extras[@]}"; do
    _d="$(echo "${_d#.}" | xargs)"
    [[ -n "$_d" ]] && ALLOWED_DOMAINS_LIST+=("$_d")
  done
fi

# =============================================================================
# Pre-flight checks
# =============================================================================

echo ""
echo -e "${BOLD}n8n Proxy Validation Suite${RESET}"
echo -e "Reading config from: ${CYAN}$ENV_FILE${RESET}"
echo ""

# Check n8n container is running
if ! docker ps --format '{{.Names}}' | grep -q '^n8n$'; then
  echo -e "${RED}❌  n8n container is not running. Start with: docker compose up -d${RESET}"
  exit 1
fi

# Check squid-proxy container is running
if ! docker ps --format '{{.Names}}' | grep -q '^n8n-squid$'; then
  echo -e "${RED}❌  squid-proxy container is not running. Start with: docker compose up -d${RESET}"
  exit 1
fi

# Check nc is available in n8n container
if ! docker exec n8n sh -c 'command -v nc' &>/dev/null; then
  echo -e "${RED}❌  nc (netcat) not found in n8n container.${RESET}"
  exit 1
fi

echo -e "${GREEN}✓${RESET}  n8n container running"
echo -e "${GREEN}✓${RESET}  squid-proxy container running"
echo -e "${GREEN}✓${RESET}  nc available in n8n container"

# =============================================================================
# TEST GROUP 1 — Squid proxy is reachable from n8n
# =============================================================================

header "1 / Proxy Connectivity"

TOTAL=$((TOTAL + 1))
if docker exec n8n nc -zw3 squid-proxy 3128 2>/dev/null; then
  echo -e "  ${GREEN}✅ REACHABLE${RESET} squid-proxy:3128"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}❌ FAIL${RESET}      squid-proxy:3128 not reachable"
  echo -e "  ${YELLOW}Aborting — no point testing ACLs if proxy is unreachable.${RESET}"
  FAIL=$((FAIL + 1))
  exit 1
fi

# =============================================================================
# TEST GROUP 2 — Whitelisted domains (must be ALLOWED)
# =============================================================================

header "2 / Whitelisted Domains — Must Be ALLOWED"

# Company domain
if [[ -n "$COMPANY_DOMAIN" ]]; then
  expect_allowed "$COMPANY_DOMAIN" 443 "Company domain: $COMPANY_DOMAIN"
  expect_allowed "sub.${COMPANY_DOMAIN}" 443 "Company subdomain: sub.$COMPANY_DOMAIN"
else
  echo -e "  ${YELLOW}⚠️  COMPANY_DOMAIN not set in .env — skipping${RESET}"
fi

# Copilot/LLM domain
if [[ -n "$COPILOT_DOMAIN" ]]; then
  COPILOT_DOMAIN_CLEAN="${COPILOT_DOMAIN#.}"
  expect_allowed "$COPILOT_DOMAIN_CLEAN" 443 "Copilot domain: $COPILOT_DOMAIN_CLEAN"
fi

# Extra domains
if [[ -n "$EXTRA_ALLOWED_DOMAINS" ]]; then
  IFS=',' read -ra EXTRAS <<< "$EXTRA_ALLOWED_DOMAINS"
  for domain in "${EXTRAS[@]}"; do
    domain="$(echo "${domain#.}" | xargs)"
    [[ -z "$domain" ]] && continue
    expect_allowed "$domain" 443 "Extra domain: $domain"
  done
fi

# =============================================================================
# TEST GROUP 3 — n8n Phone-Home Domains (must be BLOCKED)
# =============================================================================

header "3 / n8n Telemetry & Phone-Home — Must Be BLOCKED"

safe_expect_blocked "telemetry.n8n.io"       443 "n8n telemetry endpoint"
safe_expect_blocked "api.n8n.io"             443 "n8n API / version check"
safe_expect_blocked "app.n8n.cloud"          443 "n8n cloud app"
safe_expect_blocked "n8n.io"                 443 "n8n.io main site"

# =============================================================================
# TEST GROUP 4 — Common Internet Domains (must be BLOCKED)
# =============================================================================

header "4 / General Internet — Must Be BLOCKED"

safe_expect_blocked "google.com"             443 "Google"
safe_expect_blocked "github.com"             443 "GitHub"
safe_expect_blocked "amazonaws.com"          443 "AWS"
safe_expect_blocked "cloudflare.com"         443 "Cloudflare"
safe_expect_blocked "microsoft.com"          443 "Microsoft"
safe_expect_blocked "azure.com"              443 "Azure"

# =============================================================================
# TEST GROUP 5 — Data Brokers & Analytics (must be BLOCKED)
# =============================================================================

header "5 / Data Brokers & Analytics — Must Be BLOCKED"

safe_expect_blocked "segment.io"             443 "Segment (analytics)"
safe_expect_blocked "mixpanel.com"           443 "Mixpanel (analytics)"
safe_expect_blocked "amplitude.com"          443 "Amplitude (analytics)"
safe_expect_blocked "datadog-hq.com"         443 "Datadog"
safe_expect_blocked "sentry.io"              443 "Sentry (error tracking)"
safe_expect_blocked "posthog.com"            443 "PostHog (analytics)"
safe_expect_blocked "intercom.io"            443 "Intercom"
safe_expect_blocked "fullstory.com"          443 "FullStory (session recording)"

# =============================================================================
# TEST GROUP 6 — Port Restriction (non-standard ports must be BLOCKED)
# =============================================================================

header "6 / Non-Standard Port Restriction — Must Be BLOCKED"

# Squid only allows port 80 and 443 (as configured in squid.conf)
if [[ -n "$COMPANY_DOMAIN" ]]; then
  expect_blocked "$COMPANY_DOMAIN"  8080 "Company domain on port 8080 (non-standard)"
  expect_blocked "$COMPANY_DOMAIN"  22   "Company domain on port 22 / SSH (non-standard)"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Results${RESET}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Total:   ${BOLD}$TOTAL${RESET}"
echo -e "  ${GREEN}Passed:  $PASS${RESET}"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  ${RED}Failed:  $FAIL${RESET}"
else
  echo -e "  Failed:  $FAIL"
fi
if [[ $SKIP -gt 0 ]]; then
  echo -e "  ${YELLOW}Skipped: $SKIP  (domains are whitelisted — see notes above)${RESET}"
fi
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}🔒  All checks passed. Proxy is configured correctly.${RESET}"
else
  echo -e "  ${RED}${BOLD}⚠️   $FAIL check(s) failed. Review whitelist.acl and squid.conf.${RESET}"
  echo ""
  echo -e "  Useful commands:"
  echo -e "    ${CYAN}docker exec n8n-squid tail -f /var/log/squid/access.log${RESET}"
  echo -e "    ${CYAN}docker compose restart squid-proxy${RESET}"
fi

echo ""
exit $FAIL