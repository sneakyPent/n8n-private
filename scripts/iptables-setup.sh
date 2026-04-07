#!/usr/bin/env bash
# =============================================================================
# iptables-setup.sh — Host-level egress firewall for Docker containers
# =============================================================================
# PURPOSE:
#   Enforces that n8n containers on the internal network (172.20.0.0/24)
#   CANNOT make direct internet connections, even if container config changes.
#   This is the "defense in depth" layer — Squid ACLs are Layer 1,
#   iptables is Layer 2 (kernel-level, cannot be bypassed by the container).
#
# WHAT THIS DOES:
#   • Allows established/related connections (return traffic)
#   • Allows traffic from internal-net → egress-net (i.e., to Squid proxy)
#   • DROPS all other forwarded traffic from internal-net to the internet
#
# REQUIREMENTS:
#   • Must be run as root (or with sudo)
#   • Run AFTER docker compose up (so bridge interfaces exist)
#   • Re-run after Docker daemon restarts (or add to a systemd service)
#
# USAGE:
#   sudo ./scripts/iptables-setup.sh
# =============================================================================
set -euo pipefail

# ── Subnets (must match docker-compose.yml) ───────────────────────────────────
INTERNAL_SUBNET="172.20.0.0/24"   # n8n + postgres (internal-net)
EGRESS_SUBNET="172.20.1.0/24"     # squid-proxy (egress-net)

echo "🔒  Applying n8n egress firewall rules..."
echo ""
echo "    Internal subnet : $INTERNAL_SUBNET"
echo "    Egress subnet   : $EGRESS_SUBNET"
echo ""

# ── Verify iptables is available ──────────────────────────────────────────────
if ! command -v iptables &>/dev/null; then
  echo "❌  iptables not found. Install with: apt install iptables"
  exit 1
fi

# ── Flush existing DOCKER-USER rules ──────────────────────────────────────────
# DOCKER-USER is Docker's dedicated chain for user-managed rules.
# Rules here are applied BEFORE Docker's own rules.
iptables -F DOCKER-USER 2>/dev/null || true
echo "✓   Flushed existing DOCKER-USER rules"

# ── Rule 1: Allow established/related connections (return traffic) ─────────────
# iptables -A DOCKER-USER \
#   -m conntrack --ctstate ESTABLISHED,RELATED,NEW,INVALID \
#   -j RETURN
# echo "✓   Rule 1: Allow established/related connections"

# ── Rule 2: Allow internal-net → egress-net (to reach Squid proxy) ────────────
# Containers on internal-net can talk to the Squid proxy on egress-net.
# Squid then decides what external destinations are allowed.
iptables -A DOCKER-USER \
  -s "$INTERNAL_SUBNET" \
  -d "$EGRESS_SUBNET" \
  -j RETURN
echo "✓   Rule 2: Allow internal-net → squid proxy (egress-net)"

# ── Rule 3: Allow internal container-to-container communication ───────────────
# n8n ↔ postgres, n8n ↔ squid (within internal-net)
iptables -A DOCKER-USER \
  -s "$INTERNAL_SUBNET" \
  -d "$INTERNAL_SUBNET" \
  -j RETURN
echo "✓   Rule 3: Allow internal container-to-container traffic"

# ── Rule 4: DROP all other forwarded traffic from internal-net ────────────────
# Any traffic from internal-net that isn't going to egress-net or internal-net
# (i.e., direct internet access attempts) will be silently dropped.
iptables -A DOCKER-USER \
  -s "$INTERNAL_SUBNET" \
  -j DROP
echo "✓   Rule 4: DROP all direct internet access from internal-net"

# ── Optional: Log dropped packets (uncomment for debugging) ───────────────────
# iptables -I DOCKER-USER 4 \
#   -s "$INTERNAL_SUBNET" \
#   -j LOG --log-prefix "[n8n-DROP] " --log-level 4

echo ""
echo "✅  Firewall rules applied successfully."
echo ""
echo "   Current DOCKER-USER chain:"
iptables -L DOCKER-USER -n --line-numbers
echo ""
echo "⚠️   NOTE: iptables rules are NOT persistent across reboots."
echo "    To make them persistent:"
echo ""
echo "    Ubuntu/Debian:  sudo apt install iptables-persistent"
echo "                    sudo netfilter-persistent save"
echo ""
echo "    Or add this script to /etc/rc.local or a systemd service."
echo "    See scripts/n8n-firewall.service for a ready-made systemd unit."
