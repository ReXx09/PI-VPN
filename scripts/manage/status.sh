#!/usr/bin/env bash
# =============================================================================
# status.sh — VPN-Status und Systeminformationen anzeigen
# Ausführen als: sudo bash scripts/manage/status.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "  ${RED}✘${NC}  $*"; }

echo -e "${BOLD}PI-VPN Status — $(date '+%d.%m.%Y %H:%M:%S')${NC}"

# ─── WireGuard-Interface ──────────────────────────────────────────────────────
section "WireGuard Interface"
if ip link show wg0 &>/dev/null; then
    ok "wg0 Interface ist UP"
    if command -v wg &>/dev/null; then
        wg show wg0 2>/dev/null || true
    else
        # Falls wg nicht auf Host, im Container ausführen
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "wireguard"; then
            CONTAINER=$(docker ps --format '{{.Names}}' | grep wireguard | head -1)
            docker exec "$CONTAINER" wg show 2>/dev/null || true
        fi
    fi
else
    fail "wg0 Interface ist DOWN oder nicht vorhanden"
fi

# ─── Docker Container ─────────────────────────────────────────────────────────
section "Docker Container"
if command -v docker &>/dev/null; then
    docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Image}}" \
        | grep -E "wireguard|ddns" \
        | while IFS=$'\t' read -r name status image; do
            if echo "$status" | grep -q "Up"; then
                ok "$name — $status ($image)"
            else
                fail "$name — $status ($image)"
            fi
        done || warn "Keine VPN-Container gefunden"
else
    warn "Docker nicht installiert oder nicht erreichbar"
fi

# ─── IPv6-Adressen ────────────────────────────────────────────────────────────
section "IPv6-Adressen"
ip -6 addr show scope global | grep "inet6" | while read -r line; do
    echo "  $line"
done || warn "Keine globalen IPv6-Adressen gefunden"

# ─── DDNS-Auflösung ───────────────────────────────────────────────────────────
section "DDNS-Auflösung (OPNsense-Endpoint)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Endpoint direkt aus dem laufenden wg0-Interface auslesen
if ip link show wg0 &>/dev/null && command -v wg &>/dev/null; then
    ENDPOINT=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | head -1)
    if [[ -n "$ENDPOINT" && "$ENDPOINT" != "(none)" ]]; then
        ok "Aktiver Peer-Endpoint: $ENDPOINT"
    else
        warn "Kein Peer-Endpoint sichtbar (noch kein Handshake oder Tunnel offline)"
    fi
else
    warn "wg0 nicht aktiv — Endpoint nicht ermittelbar"
fi

# Hostname aus wireguard-ui wg0.conf lesen (Fallback)
WG_CONF="$PROJECT_ROOT/docker/nebenwohnsitz/data/wireguard/wg0.conf"
if [[ -f "$WG_CONF" ]]; then
    DDNS_HOST=$(grep -i "Endpoint" "$WG_CONF" | head -1 | awk -F= '{print $2}' | awk -F: '{print $1}' | tr -d ' ')
    if [[ -n "$DDNS_HOST" && "$DDNS_HOST" != *"<"* ]]; then
        RESOLVED=$(dig +short AAAA "$DDNS_HOST" 2>/dev/null || echo "")
        if [[ -n "$RESOLVED" ]]; then
            ok "DDNS $DDNS_HOST → $RESOLVED"
        else
            fail "DDNS $DDNS_HOST → nicht auflösbar (IPv6-Konnektivität prüfen)"
        fi
    fi
fi

# ─── Konnektivität ────────────────────────────────────────────────────────────
section "VPN-Konnektivität"
if ping -c 1 -W 2 10.10.0.1 &>/dev/null; then
    ok "10.10.0.1 (WireGuard-Server) erreichbar"
else
    fail "10.10.0.1 (WireGuard-Server) nicht erreichbar"
fi

section "Forwarding-Status"
IPV4_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
IPV6_FWD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "?")
[[ "$IPV4_FWD" == "1" ]] && ok "IPv4-Forwarding aktiv" || warn "IPv4-Forwarding inaktiv (net.ipv4.ip_forward=$IPV4_FWD)"
[[ "$IPV6_FWD" == "1" ]] && ok "IPv6-Forwarding aktiv" || warn "IPv6-Forwarding inaktiv (net.ipv6.conf.all.forwarding=$IPV6_FWD)"

echo ""
