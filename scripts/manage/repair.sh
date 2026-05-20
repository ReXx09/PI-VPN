#!/usr/bin/env bash
# =============================================================================
# PI-VPN — Automatische Reparatur
#
# Behebt typische Probleme automatisch:
#   Container-Start · SSH-Daemon · DNS-Sync via ddns-go · WireGuard-Restart
#
# Gibt klare manuelle Hinweise für alles, was nicht automatisch lösbar ist
# (Fritzbox-Portfreigaben, Cloudflare-TTL, slaac-Modus).
#
# Ausführen: sudo bash /opt/pi-vpn/scripts/manage/repair.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker/nebenwohnsitz"
ENV_FILE="$DOCKER_DIR/.env"

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen: sudo bash $0"; exit 1; }

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE" 2>/dev/null; set +a; } || true

VPN_HOST="${VPN_HOST:-vpn.deine-domain.de}"

# ─── Farben ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Zähler & Sammler ────────────────────────────────────────────────────────
FIXED=0
MANUAL_ACTIONS=()

fixed()  { echo -e "  ${GREEN}✔  BEHOBEN:${NC}   $1"; FIXED=$(( FIXED + 1 )); }
manual() { echo -e "  ${YELLOW}⚠  MANUELL:${NC}   $1"; MANUAL_ACTIONS+=("$1"); }
skip()   { echo -e "  ${DIM}–  OK:${NC}         $1"; }
problem(){ echo -e "  ${RED}→${NC}  $1"; }
sect()   { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }

# ─── Zustandsvariablen ───────────────────────────────────────────────────────
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
DDNS_RESTARTED=false
WG_RESTARTED=false
DNS_UPDATED=false

# =============================================================================
# HEADER
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         PI-VPN — Automatische Reparatur                         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo -e "  $(date '+%d.%m.%Y  %H:%M:%S')  |  $(hostname)  |  LAN: ${LAN_IP:-?}"
echo -e "  Domain: $VPN_HOST"

# =============================================================================
# 1. DOCKER ENGINE
# =============================================================================
sect "Docker Engine"

if ! command -v docker &>/dev/null; then
    problem "Docker nicht installiert — Repair nicht möglich"
    MANUAL_ACTIONS+=("Docker installieren: sudo bash $SCRIPT_DIR/scripts/setup/install-docker.sh")
    # Nicht abbrechen, weiter mit anderen Checks
elif ! docker info &>/dev/null 2>&1; then
    problem "Docker Engine gestoppt — starte…"
    systemctl start docker 2>/dev/null
    sleep 3
    docker info &>/dev/null 2>&1 && fixed "Docker Engine gestartet" \
        || { MANUAL_ACTIONS+=("Docker startet nicht: systemctl status docker"); }
else
    skip "Docker Engine läuft"
fi

# =============================================================================
# 2. CONTAINER STARTEN (falls gestoppt)
# =============================================================================
sect "Docker-Container"

container_running() {
    cd "$DOCKER_DIR" 2>/dev/null && docker compose ps "$1" 2>/dev/null \
        | tail -n +2 | grep -qE '\bUp\b|\brunning\b'
}

for SVC in wireguard-ui ddns-go dashboard; do
    if container_running "$SVC"; then
        skip "$SVC: läuft"
    else
        STATUS=$(cd "$DOCKER_DIR" 2>/dev/null && docker compose ps "$SVC" 2>/dev/null | tail -n +2 | head -1 || true)
        if [[ -z "$STATUS" ]]; then
            problem "$SVC nicht gefunden — führe 'up -d' aus…"
        else
            problem "$SVC gestoppt ($STATUS) — starte…"
        fi

        if (cd "$DOCKER_DIR" && docker compose up -d "$SVC" 2>/dev/null); then
            sleep 4
            if container_running "$SVC"; then
                fixed "$SVC gestartet"
                [[ "$SVC" == "ddns-go" ]]       && DDNS_RESTARTED=true
                [[ "$SVC" == "wireguard-ui" ]]  && WG_RESTARTED=true
            else
                MANUAL_ACTIONS+=("$SVC startet nicht: docker compose -f $DOCKER_DIR/docker-compose.yml logs $SVC")
            fi
        else
            MANUAL_ACTIONS+=("$SVC: 'docker compose up' fehlgeschlagen — Logs prüfen")
        fi
    fi
done

# =============================================================================
# 3. SSH-DAEMON
# =============================================================================
sect "SSH-Daemon"

if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    skip "sshd läuft"
else
    problem "sshd nicht aktiv — starte…"
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null
    sleep 1
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        fixed "sshd gestartet"
    else
        MANUAL_ACTIONS+=("sshd startet nicht: systemctl status ssh  (Konfiguration prüfen)")
    fi
fi

# Port 22 lauscht?
ss -tlnp 2>/dev/null | grep -q ':22 ' \
    && skip "Port 22/tcp lauscht" \
    || { echo -e "  ${YELLOW}⚠${NC}  Port 22 nicht in ss — SSH antwortet möglicherweise nicht"; }

# =============================================================================
# 4. IPv6 / DNS SYNCHRONISATION
# =============================================================================
sect "IPv6 — DNS-Synchronisation"

EXT_IPV6=$(curl -6 -s --max-time 10 ifconfig.co 2>/dev/null || true)
DNS_AAAA=""

if [[ -z "$EXT_IPV6" ]]; then
    problem "Kein IPv6-Internet — Synchronisation nicht möglich"
    MANUAL_ACTIONS+=("IPv6-Internet prüfen: Fritzbox → Internet → IPv6 → DHCPv6-PD aktiviert?")
elif [[ "$VPN_HOST" == "vpn.deine-domain.de" ]]; then
    echo -e "  ${YELLOW}⚠${NC}  VPN_HOST nicht konfiguriert — DNS-Check übersprungen"
    MANUAL_ACTIONS+=(".env bearbeiten: VPN_HOST=deine-echte-domain.de  →  nano $ENV_FILE")
elif ! command -v dig &>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC}  dig nicht installiert — DNS-Check übersprungen"
    MANUAL_ACTIONS+=("dig installieren: apt-get install -y dnsutils  (oder Diagnosemenü Option 9)")
else
    DNS_AAAA=$(dig "$VPN_HOST" AAAA +short +time=3 2>/dev/null | head -1 || true)

    if [[ -z "$DNS_AAAA" ]]; then
        problem "AAAA-Record nicht auflösbar — ddns-go neu starten…"
        (cd "$DOCKER_DIR" && docker compose restart ddns-go 2>/dev/null) && DDNS_RESTARTED=true
        echo -e "  ${DIM}→  Warte 15s auf DNS-Update…${NC}"
        sleep 15
        DNS_AAAA=$(dig "$VPN_HOST" AAAA +short +time=3 2>/dev/null | head -1 || true)
        if [[ -n "$DNS_AAAA" ]]; then
            fixed "DNS-Record jetzt auflösbar: $DNS_AAAA"
            DNS_UPDATED=true
        else
            MANUAL_ACTIONS+=("DNS-Record weiterhin nicht auflösbar: ddns-go WebUI prüfen → http://${LAN_IP}:9876")
            MANUAL_ACTIONS+=("Cloudflare API-Key gültig? Domain korrekt konfiguriert?")
        fi

    elif [[ "$DNS_AAAA" == "$EXT_IPV6" ]]; then
        skip "DNS = Externe IPv6 ($EXT_IPV6) — aktuell"

    else
        problem "Präfixwechsel erkannt!"
        echo -e "  ${DIM}   DNS zeigt:    $DNS_AAAA${NC}"
        echo -e "  ${DIM}   Aktuell wäre: $EXT_IPV6${NC}"
        problem "ddns-go Force-Update…"
        (cd "$DOCKER_DIR" && docker compose restart ddns-go 2>/dev/null) && DDNS_RESTARTED=true
        echo -e "  ${DIM}→  Warte 15s auf DNS-Propagation…${NC}"
        sleep 15
        DNS_NEW=$(dig "$VPN_HOST" AAAA +short +time=3 2>/dev/null | head -1 || true)

        if [[ "$DNS_NEW" == "$EXT_IPV6" ]]; then
            fixed "DNS aktualisiert: $DNS_NEW"
            DNS_UPDATED=true
            # Fritzbox muss jetzt manuell aktualisiert werden
            MANUAL_ACTIONS+=("Fritzbox: IPv6-Portfreigaben prüfen! (TCP 22 + UDP 51820 → ${LAN_IP})")
            MANUAL_ACTIONS+=("  → http://fritz.box → Heimnetz → Netzwerk → ${LAN_IP} → IPv6-Portfreigaben")
        else
            problem "DNS noch nicht synchron (TTL-Cache oder API-Problem)"
            MANUAL_ACTIONS+=("DNS-Sync fehlgeschlagen: ddns-go WebUI → http://${LAN_IP}:9876")
            MANUAL_ACTIONS+=("Cloudflare: TTL auf 60s (Auto) setzen → weniger Cache-Wartezeit")
        fi
    fi
fi

# =============================================================================
# 5. DNS TTL (nur prüfen, nicht automatisch änderbar)
# =============================================================================
sect "DNS TTL"

if command -v dig &>/dev/null && [[ -n "$VPN_HOST" && "$VPN_HOST" != "vpn.deine-domain.de" ]]; then
    DNS_TTL=$(dig "$VPN_HOST" AAAA +noall +answer +time=3 2>/dev/null | awk 'NR==1{print $2}' || true)
    if [[ -n "$DNS_TTL" ]]; then
        if   [[ "$DNS_TTL" -le 60  ]]; then skip  "TTL: ${DNS_TTL}s — optimal"
        elif [[ "$DNS_TTL" -le 300 ]]; then manual "TTL: ${DNS_TTL}s — Cloudflare: DNS-Record TTL auf 60s (Auto) senken"
        else                                manual "TTL: ${DNS_TTL}s — ZU HOCH! Cloudflare: TTL auf 60s (Auto) setzen"
        fi
    else
        skip "TTL nicht ermittelbar (AAAA-Record nicht auflösbar?)"
    fi
else
    skip "TTL-Check übersprungen (dig fehlt oder VPN_HOST nicht gesetzt)"
fi

# =============================================================================
# 6. WIREGUARD neu starten (wenn DNS-Update erfolgte)
# =============================================================================
sect "WireGuard"

if [[ "$DNS_UPDATED" == true ]] && ip link show wg0 &>/dev/null 2>&1; then
    problem "DNS wurde aktualisiert — WireGuard neu starten damit Peers reconnecten…"
    (cd "$DOCKER_DIR" && docker compose restart wireguard-ui 2>/dev/null)
    WG_RESTARTED=true
    sleep 5
    ip link show wg0 &>/dev/null 2>&1 && fixed "wireguard-ui neugestartet (wg0 aktiv)" \
        || MANUAL_ACTIONS+=("wg0 nach Neustart nicht aktiv: docker compose logs wireguard-ui")

elif ! ip link show wg0 &>/dev/null 2>&1; then
    if [[ "$WG_RESTARTED" == true ]]; then
        echo -e "  ${YELLOW}⚠${NC}  wireguard-ui wurde gerade gestartet — wg0 braucht noch etwas"
    else
        problem "wg0 nicht aktiv"
        MANUAL_ACTIONS+=("wg0 nicht aktiv: WireGuard-UI prüfen → http://${LAN_IP}:5000")
    fi

else
    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo "0")
    if [[ -n "$HS" && "$HS" != "0" ]]; then
        AGO=$(( $(date +%s) - HS ))
        if [[ $AGO -lt 600 ]]; then
            skip "Tunnel aktiv (letzter Handshake vor ${AGO}s)"
        else
            manual "Kein Handshake seit ${AGO}s — OPNsense verbunden? Fritzbox UDP 51820 freigegeben?"
        fi
    else
        manual "Kein Handshake — OPNsense prüfen + Fritzbox UDP 51820 Portfreigabe prüfen"
    fi
fi

# =============================================================================
# 7. IPv6-Suffix stabilisieren (NetworkManager oder dhcpcd)
# =============================================================================
sect "IPv6-Suffix stabilisieren"

NM_ACTIVE=$(systemctl is-active NetworkManager 2>/dev/null || echo "inactive")
DHCPCD_ACTIVE=$(systemctl is-active dhcpcd 2>/dev/null || echo "inactive")

MAC=$(tr '[:upper:]' '[:lower:]' < /sys/class/net/eth0/address 2>/dev/null || true)
EXPECT_SUFFIX=""
if [[ -n "$MAC" ]]; then
    IFS=':' read -r M0 M1 M2 M3 M4 M5 <<< "$MAC"
    if [[ -n "$M0" && -n "$M5" ]]; then
        B0=$(printf '%02x' $((16#$M0 ^ 2)))
        EXPECT_SUFFIX="${B0}${M1}:${M2}ff:fe${M3}:${M4}${M5}"
    fi
fi

if [[ "$NM_ACTIVE" == "active" ]]; then
    if command -v nmcli &>/dev/null; then
        CONN_UUID=$(nmcli -t -f GENERAL.CONNECTION device show eth0 2>/dev/null | cut -d: -f2-)
        if [[ -z "$CONN_UUID" || "$CONN_UUID" == "--" ]]; then
            CONN_UUID=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="eth0"{print $1; exit}')
        fi

        if [[ -n "$CONN_UUID" ]]; then
            problem "NetworkManager erkannt — setze IPv6 auf EUI-64 (stabiler Suffix)…"
            if nmcli connection modify "$CONN_UUID" ipv6.method auto ipv6.addr-gen-mode eui64 ipv6.ip6-privacy 0 2>/dev/null; then
                nmcli device reapply eth0 2>/dev/null || nmcli connection up "$CONN_UUID" 2>/dev/null || true
                fixed "NetworkManager-Profil angepasst: ipv6.addr-gen-mode=eui64, privacy=0"
            else
                MANUAL_ACTIONS+=("NetworkManager-Profil konnte nicht angepasst werden: nmcli connection show '$CONN_UUID'")
            fi
        else
            MANUAL_ACTIONS+=("Kein aktives NM-Profil für eth0 gefunden — nmcli connection show --active prüfen")
        fi
    else
        MANUAL_ACTIONS+=("NetworkManager aktiv, aber nmcli fehlt — Paket network-manager installieren")
    fi

elif [[ "$DHCPCD_ACTIVE" == "active" || -f /etc/dhcpcd.conf ]]; then
    SLAAC=$(grep -E '^slaac ' /etc/dhcpcd.conf 2>/dev/null | awk '{print $2}' | head -1 || true)
    if [[ "$SLAAC" == "hwaddr" ]]; then
        skip "dhcpcd: slaac hwaddr bereits gesetzt"
    else
        if grep -qE '^slaac ' /etc/dhcpcd.conf 2>/dev/null; then
            sed -i 's/^slaac .*/slaac hwaddr/' /etc/dhcpcd.conf
        else
            echo "slaac hwaddr" >> /etc/dhcpcd.conf
        fi
        systemctl restart dhcpcd 2>/dev/null || systemctl restart networking 2>/dev/null || true
        fixed "dhcpcd: slaac hwaddr gesetzt"
    fi
else
    manual "Kein unterstützter Netzwerkmanager erkannt (weder NetworkManager noch dhcpcd)"
fi

# Laufzeit-Modus auf EUI-64 erzwingen (wirksam bis zum nächsten Link-Reset)
ADDR_ETH0=$(sysctl -n net.ipv6.conf.eth0.addr_gen_mode 2>/dev/null || echo "?")
if [[ "$ADDR_ETH0" != "0" ]]; then
    sysctl -w net.ipv6.conf.eth0.addr_gen_mode=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.addr_gen_mode=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.addr_gen_mode=0 >/dev/null 2>&1 || true
    fixed "addr_gen_mode auf EUI-64 gesetzt (eth0/default/all)"
else
    skip "addr_gen_mode eth0 bereits EUI-64"
fi

if [[ -n "$EXPECT_SUFFIX" ]]; then
    ip -6 addr flush dev eth0 scope global 2>/dev/null || true
    sleep 3
    CUR_IPV6=$(ip -6 addr show dev eth0 scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d'/' -f1 | head -1)
    if [[ -n "$CUR_IPV6" && "${CUR_IPV6,,}" == *":${EXPECT_SUFFIX}" ]]; then
        fixed "IPv6-Suffix jetzt stabil (::$EXPECT_SUFFIX)"
    else
        manual "IPv6-Suffix noch nicht stabil erkannt — aktuell: ${CUR_IPV6:-unbekannt}, erwartet: ::$EXPECT_SUFFIX"
        manual "Falls Fritzbox alte IPv6 zeigt: Portfreigaben auf aktuelle IPv6 neu setzen"
    fi
fi

# =============================================================================
# 8. .env KONFIGURATION
# =============================================================================
sect ".env Konfiguration"

if [[ ! -f "$ENV_FILE" ]]; then
    MANUAL_ACTIONS+=(".env fehlt: cp $DOCKER_DIR/.env.example $ENV_FILE  dann nano $ENV_FILE")
elif grep -qE 'vpn\.deine-domain\.de|CHANGE_ME|your-domain|<DOMAIN>|<PASS>' "$ENV_FILE" 2>/dev/null; then
    manual ".env enthält noch Platzhalter → nano $ENV_FILE"
else
    skip ".env vorhanden, keine Platzhalter"
fi

# =============================================================================
# ZUSAMMENFASSUNG
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Ergebnis                                                            ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"

if [[ $FIXED -gt 0 ]]; then
    echo -e "  ${GREEN}✔  $FIXED Problem(e) automatisch behoben${NC}"
else
    echo -e "  ${DIM}–  Keine automatischen Korrekturen notwendig${NC}"
fi

if [[ ${#MANUAL_ACTIONS[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}Manuelle Maßnahmen erforderlich (${#MANUAL_ACTIONS[@]}):${NC}"
    for i in "${!MANUAL_ACTIONS[@]}"; do
        echo -e "  ${YELLOW}$(( i + 1 )).${NC}  ${MANUAL_ACTIONS[$i]}"
    done
else
    echo -e "  ${GREEN}Keine manuellen Maßnahmen erforderlich.${NC}"
fi

echo ""
echo -e "  ${DIM}Vollständiger Report: sudo bash $SCRIPT_DIR/scripts/manage/check.sh${NC}"
echo ""
