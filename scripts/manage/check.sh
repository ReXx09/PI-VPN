#!/usr/bin/env bash
# =============================================================================
# PI-VPN — Vollständiger Diagnose-Report
#
# Prüft alle relevanten Komponenten:
#   System · Netzwerk · IPv6 · DNS · Docker · WireGuard
#   Dienste & Ports · ddns-go · VPN-Konnektivität · .env
#
# Ausführen: sudo bash /opt/pi-vpn/scripts/manage/check.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker/nebenwohnsitz"
ENV_FILE="$DOCKER_DIR/.env"

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen: sudo bash $0"; exit 1; }

# .env laden (Variablen wie VPN_HOST, HAUPT_GW übernehmen)
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE" 2>/dev/null; set +a; } || true

VPN_HOST="${VPN_HOST:-vpn.deine-domain.de}"
HAUPT_GW="${HAUPT_GW:-}"

# ─── Farben ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Zähler ──────────────────────────────────────────────────────────────────
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; PASS=$(( PASS + 1 )); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$(( WARN + 1 )); }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAIL=$(( FAIL + 1 )); }
hint() { echo -e "  ${DIM}→  $1${NC}"; }
sect() { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }

# ─── Zwischenspeicher (werden in mehreren Sektionen genutzt) ─────────────────
LAN_IP=""
EXT_IPV6=""
DNS_AAAA=""
DNS_TTL=""

# =============================================================================
# HEADER
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         PI-VPN — Vollständiger Diagnose-Report                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "  Datum:    $(date '+%d.%m.%Y  %H:%M:%S')"
echo -e "  Hostname: $(hostname)    LAN-IP: ${LAN_IP:-nicht ermittelbar}"
echo -e "  Domain:   $VPN_HOST"
echo -e "  Projekt:  $SCRIPT_DIR"

# =============================================================================
# 1. SYSTEM
# =============================================================================
sect "SYSTEM"

UPTIME=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "unbekannt")
ok "Uptime: $UPTIME"

LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
CORES=$(nproc 2>/dev/null || echo 1)
LOAD_HIGH=$(awk -v l="$LOAD" -v c="$CORES" 'BEGIN{print (l+0 > c+0) ? "yes" : "no"}')
if [[ "$LOAD_HIGH" == "no" ]]; then
    ok "CPU-Load: $LOAD  ($CORES Kerne)"
else
    warn "CPU-Load: $LOAD — erhöht ($CORES Kerne)"
fi

MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 1)
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 1)
MEM_PCT=$(( 100 - (MEM_FREE * 100 / MEM_TOTAL) ))
if [[ $MEM_PCT -lt 85 ]]; then
    ok "RAM: ${MEM_PCT}% genutzt  ($(( MEM_FREE / 1024 )) MB frei)"
else
    warn "RAM: ${MEM_PCT}% — knapp ($(( MEM_FREE / 1024 )) MB frei)"
fi

DISK=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo 0)
if   [[ "${DISK:-0}" -lt 85 ]]; then ok "Disk (/): ${DISK}% belegt"
elif [[ "${DISK:-0}" -lt 95 ]]; then warn "Disk (/): ${DISK}% — fast voll"; hint "docker system prune -f"
else fail "Disk (/): ${DISK}% — kritisch!"; hint "docker system prune -af --volumes"
fi

# =============================================================================
# 2. NETZWERK
# =============================================================================
sect "NETZWERK"

if ip link show eth0 &>/dev/null 2>&1; then
    ETH_STATE=$(cat /sys/class/net/eth0/operstate 2>/dev/null || echo "?")
    [[ "$ETH_STATE" == "up" ]] && ok "eth0: up" || fail "eth0: $ETH_STATE — physisches Problem?"
else
    fail "eth0: Interface nicht gefunden (anderer Name? ip link show)"
fi

if [[ -n "$LAN_IP" ]]; then
    ok "LAN-IPv4: $LAN_IP"
else
    fail "LAN-IPv4: nicht ermittelbar"
fi

GW=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1 || true)
if [[ -n "$GW" ]]; then
    if ping -c 1 -W 2 "$GW" &>/dev/null; then
        ok "Standard-Gateway ($GW): erreichbar"
    else
        fail "Standard-Gateway ($GW): nicht erreichbar — LAN-Problem?"
    fi
else
    fail "Standard-Route: nicht konfiguriert"
fi

# Internet-Erreichbarkeit (IPv4 via curl, DS-Lite hat kein native IPv4 von außen)
IPV4_OK=$(curl -4 -s --max-time 5 -o /dev/null -w "%{http_code}" http://1.1.1.1 2>/dev/null || true)
[[ "$IPV4_OK" == "200" || "$IPV4_OK" == "301" ]] \
    && ok "IPv4-Internet: erreichbar (via DS-Lite/NAT)" \
    || warn "IPv4-Internet: nicht erreichbar (bei DS-Lite normal für eingehende Verbindungen)"

# =============================================================================
# 3. IPv6
# =============================================================================
sect "IPv6"

IF_IPV6=$(ip -6 addr show eth0 2>/dev/null | awk '/scope global/{print $2}' | cut -d'/' -f1 | head -1 || true)
if [[ -n "$IF_IPV6" ]]; then
    ok "Interface eth0: $IF_IPV6"
else
    fail "Interface eth0: keine globale IPv6-Adresse"
    hint "Fritzbox → Internet → IPv6 aktiviert? DHCPv6-PD konfiguriert?"
fi

EXT_IPV6=$(curl -6 -s --max-time 8 ifconfig.co 2>/dev/null || true)
if [[ -n "$EXT_IPV6" ]]; then
    ok "Extern (öffentlich): $EXT_IPV6"
    # Stimmt Interface mit externem überein?
    if [[ -n "$IF_IPV6" && "$IF_IPV6" != "$EXT_IPV6" ]]; then
        warn "Interface-IP ≠ öffentliche IP (mehrere Adressen / Präfix delegiert)"
        hint "Interface: $IF_IPV6  Extern: $EXT_IPV6"
    fi
else
    fail "Externe IPv6: nicht erreichbar — kein IPv6-Internet"
    hint "Fritzbox → Internet → IPv6 aktiviert?"
fi

# IPv6-Konnektivität zu bekanntem Ziel
if ping6 -c 1 -W 3 2606:4700:4700::1111 &>/dev/null 2>&1; then
    ok "IPv6 zu Cloudflare (2606:4700:4700::1111): OK"
else
    warn "IPv6 zu Cloudflare: nicht erreichbar (Routing-Problem?)"
fi

# slaac-Modus
SLAAC=$(grep -E '^slaac ' /etc/dhcpcd.conf 2>/dev/null | awk '{print $2}' | head -1 || true)
NM_ACTIVE=$(systemctl is-active NetworkManager 2>/dev/null || echo "inactive")
DHCPCD_ACTIVE=$(systemctl is-active dhcpcd 2>/dev/null || echo "inactive")

if [[ "$NM_ACTIVE" == "active" ]]; then
    warn "NetworkManager aktiv — /etc/dhcpcd.conf (slaac) wird typischerweise ignoriert"
    hint "IPv6-Adressmodus in NetworkManager prüfen (nmcli)"
else
    if [[ "$SLAAC" == "hwaddr" ]]; then
        ok "slaac hwaddr: Suffix fest — Dauerlösung aktiv"
    else
        warn "slaac ${SLAAC:-private}: Suffix ändert sich bei Präfixwechsel!"
        hint "Diagnosemenü Option 11: IPv6-Suffix fixieren (Dauerlösung)"
    fi
fi

if [[ "$DHCPCD_ACTIVE" == "active" ]]; then
    ok "dhcpcd: aktiv"
elif [[ "$NM_ACTIVE" == "active" ]]; then
    ok "dhcpcd: inaktiv (ok, da NetworkManager aktiv)"
else
    warn "Weder dhcpcd noch NetworkManager aktiv erkannt"
fi

ADDR_ETH0=$(sysctl -n net.ipv6.conf.eth0.addr_gen_mode 2>/dev/null || echo "?")
ADDR_DEF=$(sysctl -n net.ipv6.conf.default.addr_gen_mode 2>/dev/null || echo "?")
ADDR_ALL=$(sysctl -n net.ipv6.conf.all.addr_gen_mode 2>/dev/null || echo "?")

if [[ "$ADDR_ETH0" == "0" ]]; then
    ok "addr_gen_mode eth0: 0 (EUI-64)"
else
    fail "addr_gen_mode eth0: ${ADDR_ETH0} (nicht EUI-64)"
    hint "Bei NetworkManager: nmcli connection modify ... ipv6.addr-gen-mode eui64"
fi

if [[ "$ADDR_DEF" == "0" && "$ADDR_ALL" == "0" ]]; then
    ok "addr_gen_mode default/all: 0/0"
else
    warn "addr_gen_mode default/all: ${ADDR_DEF}/${ADDR_ALL} (abweichend)"
fi

if [[ -r /sys/class/net/eth0/address ]]; then
    MAC=$(tr '[:upper:]' '[:lower:]' < /sys/class/net/eth0/address 2>/dev/null)
    IFS=':' read -r M0 M1 M2 M3 M4 M5 <<< "$MAC"
    if [[ -n "$M0" && -n "$M5" ]]; then
        B0=$(printf '%02x' $((16#$M0 ^ 2)))
        EXPECT_SUFFIX="${B0}${M1}:${M2}ff:fe${M3}:${M4}${M5}"
        ok "Erwarteter EUI-64-Suffix: ::${EXPECT_SUFFIX}"

        if [[ -n "$EXT_IPV6" ]]; then
            if [[ "${EXT_IPV6,,}" == *":${EXPECT_SUFFIX}" ]]; then
                ok "Öffentliche IPv6 nutzt den erwarteten EUI-64-Suffix"
            else
                fail "Öffentliche IPv6 nutzt NICHT den erwarteten EUI-64-Suffix"
                hint "Aktuell: $EXT_IPV6"
            fi
        fi
    fi
fi

# Aktueller Präfix extrahieren
if [[ -n "$EXT_IPV6" ]]; then
    PREFIX=$(echo "$EXT_IPV6" | awk -F: 'BEGIN{OFS=":"} {print $1,$2,$3,$4}')
    ok "Aktueller IPv6-Präfix: ${PREFIX}::/64"
fi

# =============================================================================
# 4. DNS
# =============================================================================
sect "DNS  ($VPN_HOST)"

if ! command -v dig &>/dev/null; then
    warn "dig nicht installiert — DNS-Checks übersprungen"
    hint "Diagnosemenü Option 9: Tools installieren (dnsutils)"
else
    DNS_AAAA=$(dig "$VPN_HOST" AAAA +short +time=3 2>/dev/null | head -1 || true)
    DNS_TTL=$(dig  "$VPN_HOST" AAAA +noall +answer +time=3 2>/dev/null | awk 'NR==1{print $2}' || true)

    if [[ -n "$DNS_AAAA" ]]; then
        ok "AAAA-Record: $DNS_AAAA"

        # DNS vs. externe IP
        if [[ -n "$EXT_IPV6" ]]; then
            if [[ "$DNS_AAAA" == "$EXT_IPV6" ]]; then
                ok "DNS = Externe IPv6 — ddns-go aktuell ✓"
            else
                fail "DNS ≠ Externe IPv6 — Präfixwechsel nicht synchronisiert!"
                hint "DNS-Wert:     $DNS_AAAA"
                hint "Aktuell wäre: $EXT_IPV6"
                hint "→ repair.sh ausführen oder Diagnosemenü Option 10"
            fi
        fi

        # TTL
        if [[ -n "$DNS_TTL" ]]; then
            if   [[ "$DNS_TTL" -le 60  ]]; then ok   "TTL: ${DNS_TTL}s — optimal für schnelle Präfix-Updates"
            elif [[ "$DNS_TTL" -le 300 ]]; then warn  "TTL: ${DNS_TTL}s — bis zu ${DNS_TTL}s Ausfall nach Präfixwechsel"; hint "Cloudflare: TTL auf 60s (Auto) setzen"
            else                                 fail  "TTL: ${DNS_TTL}s — zu hoch! Lange Ausfallzeit nach Präfixwechsel"; hint "Cloudflare: DNS-Record TTL auf 60s (Auto) setzen"
            fi
        fi

        # Konsistenzcheck: lokaler Resolver vs. 1.1.1.1
        DNS_CF=$(dig "@1.1.1.1" "$VPN_HOST" AAAA +short +time=3 2>/dev/null | head -1 || true)
        if [[ -n "$DNS_CF" && "$DNS_CF" != "$DNS_AAAA" ]]; then
            warn "DNS-Divergenz: lokaler Resolver ($DNS_AAAA) ≠ 1.1.1.1 ($DNS_CF)"
            hint "DNS-Cache des Routers noch nicht abgelaufen?"
        elif [[ -n "$DNS_CF" ]]; then
            ok "DNS konsistent (lokal = Cloudflare 1.1.1.1)"
        fi

        # Reverse-DNS (optional, zeigt ob IP zu Domain passt)
        if command -v host &>/dev/null && [[ -n "$DNS_AAAA" ]]; then
            RDNS=$(host "$DNS_AAAA" 2>/dev/null | awk '/domain name pointer/{print $NF}' | head -1 || true)
            [[ -n "$RDNS" ]] && ok "Reverse-DNS: $RDNS" || warn "Reverse-DNS: kein PTR-Record"
        fi
    else
        fail "AAAA-Record: nicht auflösbar für $VPN_HOST"
        hint "ddns-go läuft? Domain korrekt? Cloudflare API-Key gültig?"
        hint "WebUI: http://${LAN_IP}:9876"
    fi

    # A-Record (bei DS-Lite sollte keiner gesetzt sein)
    DNS_A=$(dig "$VPN_HOST" A +short +time=3 2>/dev/null | head -1 || true)
    if [[ -n "$DNS_A" ]]; then
        warn "A-Record vorhanden: $DNS_A (bei DS-Lite ungewöhnlich)"
    else
        ok "Kein A-Record — korrekt für DS-Lite (nur AAAA)"
    fi
fi

# =============================================================================
# 5. DOCKER
# =============================================================================
sect "DOCKER"

if ! command -v docker &>/dev/null; then
    fail "Docker nicht installiert"
    hint "scripts/setup/install-docker.sh ausführen"
else
    if docker info &>/dev/null 2>&1; then
        DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
        ok "Docker Engine läuft (v${DOCKER_VER})"
    else
        fail "Docker Engine nicht erreichbar (systemd-Dienst gestoppt?)"
        hint "systemctl start docker"
    fi

    for SVC in wireguard-ui ddns-go dashboard; do
        if (cd "$DOCKER_DIR" 2>/dev/null && docker compose ps "$SVC" 2>/dev/null | tail -n +2 | grep -qE '\bUp\b|\brunning\b'); then
            UPTIME_SVC=$(cd "$DOCKER_DIR" && docker compose ps "$SVC" 2>/dev/null | tail -n +2 | grep "$SVC" | awk '{print $(NF-1), $NF}' | head -1 || true)
            ok "Container $SVC: Up  ${UPTIME_SVC}"
        else
            STATUS=$(cd "$DOCKER_DIR" 2>/dev/null && docker compose ps "$SVC" 2>/dev/null | tail -n +2 | head -1 || true)
            if [[ -z "$STATUS" ]]; then
                warn "Container $SVC: nicht gefunden (noch nicht gestartet?)"
                hint "cd $DOCKER_DIR && docker compose up -d"
            else
                fail "Container $SVC: gestoppt / fehlerhaft"
                hint "cd $DOCKER_DIR && docker compose start $SVC"
                hint "docker compose logs $SVC  (Fehlerdetails)"
            fi
        fi
    done

    # Docker-Disk-Nutzung
    DOCKER_SIZE=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || true)
    [[ -n "$DOCKER_SIZE" ]] && ok "Docker-Speicher: $(docker system df 2>/dev/null | grep Images | awk '{print $3, "Images:", $2}' || true)" || true
fi

# =============================================================================
# 6. WIREGUARD
# =============================================================================
sect "WIREGUARD"

if ip link show wg0 &>/dev/null 2>&1; then
    ok "wg0: Interface aktiv"

    PEERS=$(wg show wg0 peers 2>/dev/null | wc -l || echo 0)
    if [[ "$PEERS" -gt 0 ]]; then
        ok "Peers konfiguriert: $PEERS"
    else
        warn "Keine Peers konfiguriert"
        hint "WireGuard-UI: http://${LAN_IP}:5000 → Client hinzufügen"
    fi

    # Handshake
    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo "0")
    if [[ -n "$HS" && "$HS" != "0" ]]; then
        AGO=$(( $(date +%s) - HS ))
        if   [[ $AGO -lt 180 ]]; then ok   "Letzter Handshake: vor ${AGO}s — Tunnel aktiv"
        elif [[ $AGO -lt 600 ]]; then warn  "Letzter Handshake: vor ${AGO}s — Verbindung instabil?"
        else                          fail  "Letzter Handshake: vor ${AGO}s — Tunnel unterbrochen"
             hint "Gegenstelle (OPNsense) prüfen oder repair.sh ausführen"
        fi
    else
        fail "Kein Handshake — Gegenstelle nicht verbunden"
        hint "OPNsense verbunden? Fritzbox UDP 51820 freigegeben?"
        hint "WireGuard-UI: http://${LAN_IP}:5000"
    fi

    # Transfer-Statistik
    TX=$(wg show wg0 transfer 2>/dev/null | awk '{print $3}' | head -1 || true)
    RX=$(wg show wg0 transfer 2>/dev/null | awk '{print $2}' | head -1 || true)
    [[ -n "$TX" && -n "$RX" ]] && ok "Traffic: RX ${RX} B  TX ${TX} B" || true

    # Listen-Port
    LISTEN=$(wg show wg0 listen-port 2>/dev/null || true)
    [[ -n "$LISTEN" ]] && ok "Listen-Port: $LISTEN" || warn "Listen-Port: nicht ermittelbar"
else
    fail "wg0: Interface nicht aktiv"
    hint "Container wireguard-ui läuft? → docker compose up -d"
fi

# =============================================================================
# 7. DIENSTE & PORTS
# =============================================================================
sect "DIENSTE & PORTS"

# sshd
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    ok "sshd: läuft"
else
    fail "sshd: nicht aktiv"
    hint "systemctl start ssh"
fi

# Port-Prüfung: "port proto beschreibung"
while IFS=' ' read -r PORT PROTO NAME; do
    if [[ "$PROTO" == "tcp" ]]; then
        ss -tlnp 2>/dev/null | grep -q ":${PORT} " \
            && ok   "Port ${PORT}/tcp ($NAME): lauscht" \
            || warn "Port ${PORT}/tcp ($NAME): nicht aktiv"
    else
        ss -ulnp 2>/dev/null | grep -q ":${PORT} " \
            && ok   "Port ${PORT}/udp ($NAME): lauscht" \
            || warn "Port ${PORT}/udp ($NAME): nicht aktiv"
    fi
done << 'PORTLIST'
22 tcp SSH
51820 udp WireGuard
5000 tcp wireguard-ui WebUI
9876 tcp ddns-go WebUI
8080 tcp Dashboard
PORTLIST

# =============================================================================
# 8. ddns-go KONFIGURATION
# =============================================================================
sect "ddns-go KONFIGURATION"

DDNS_CONF="$DOCKER_DIR/data/ddns-go/.ddns_go_config.yaml"
if [[ -f "$DDNS_CONF" ]]; then
    ok "Konfigurationsdatei vorhanden: $DDNS_CONF"

    grep -q "$VPN_HOST" "$DDNS_CONF" 2>/dev/null \
        && ok   "Domain $VPN_HOST: in Konfiguration gefunden" \
        || { warn "Domain $VPN_HOST: nicht in ddns-go konfiguriert"; hint "WebUI: http://${LAN_IP}:9876"; }

    grep -qiE 'cloudflare|apitoken|api_key|apikey|token|secret' "$DDNS_CONF" 2>/dev/null \
        && ok   "API-Credentials: vorhanden" \
        || { warn "API-Credentials: nicht erkannt"; hint "WebUI: http://${LAN_IP}:9876 → Provider konfigurieren"; }

    grep -qiE 'ipv6|AAAA|aaaa' "$DDNS_CONF" 2>/dev/null \
        && ok   "IPv6 (AAAA): in Konfiguration aktiviert" \
        || warn "IPv6/AAAA: möglicherweise nicht aktiviert (nur IPv4?)"
else
    warn "ddns-go-Konfiguration nicht gefunden (noch nicht eingerichtet?)"
    hint "WebUI öffnen: http://${LAN_IP}:9876"
fi

# =============================================================================
# 9. VPN-KONNEKTIVITÄT
# =============================================================================
sect "VPN-KONNEKTIVITÄT"

if ip link show wg0 &>/dev/null 2>&1; then
    PEER_IP=$(wg show wg0 allowed-ips 2>/dev/null | awk '{print $2}' | grep -v '^::' | cut -d'/' -f1 | head -1 || true)
    if [[ -n "$PEER_IP" ]]; then
        if ping -c 2 -W 2 "$PEER_IP" &>/dev/null; then
            ok "VPN-Peer ($PEER_IP): erreichbar — Tunnel funktioniert"
        else
            fail "VPN-Peer ($PEER_IP): nicht erreichbar — Tunnel unterbrochen"
            hint "OPNsense: WireGuard-Interface up? Peer-Config korrekt?"
        fi
    else
        warn "Kein VPN-Peer-IP ermittelbar (Peer konfiguriert?)"
    fi

    # Heimnetz-Gateway pingen (wenn bekannt)
    if [[ -n "$HAUPT_GW" && "$HAUPT_GW" != "<HAUPT-GW>" ]]; then
        if ping -c 2 -W 2 "$HAUPT_GW" &>/dev/null; then
            ok "Heimnetz-Gateway ($HAUPT_GW): erreichbar — Routing ok"
        else
            warn "Heimnetz-Gateway ($HAUPT_GW): nicht erreichbar"
        fi
    fi
else
    warn "wg0 nicht aktiv — VPN-Ping übersprungen"
fi

# =============================================================================
# 10. FRITZBOX (Hinweis — nicht automatisch prüfbar)
# =============================================================================
sect "FRITZBOX  (nicht automatisch prüfbar)"

echo -e "  ${DIM}Fritzbox-Portfreigaben können von innen nicht geprüft werden.${NC}"
echo -e "  ${DIM}Folgendes muss manuell sichergestellt sein:${NC}"
echo -e "  ${DIM}  http://fritz.box → Heimnetz → Netzwerk → ${LAN_IP:-Raspi}${NC}"
echo -e "  ${DIM}  → IPv6-Portfreigaben:${NC}"
echo -e "  ${DIM}    TCP Port 22    → ${LAN_IP:-<raspi-ip>}  (SSH)${NC}"
echo -e "  ${DIM}    UDP Port 51820 → ${LAN_IP:-<raspi-ip>}  (WireGuard)${NC}"
echo -e "  ${DIM}  → Bei Präfixwechsel: Ziel-IPv6 in Portfreigabe aktualisieren${NC}"
echo -e "  ${DIM}    (oder: Suffix fixieren → Option 11 → einmalig aktualisieren)${NC}"

# =============================================================================
# 11. HARDWAREWECHSEL-SCHUTZ
# =============================================================================
sect "HARDWAREWECHSEL-SCHUTZ"

IDENTITY_FILE="/opt/pi-vpn/.host_identity"
CUR_MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
CUR_HOST=$(hostname 2>/dev/null || true)
CUR_WG_PUB=$(wg show wg0 public-key 2>/dev/null || true)

if [[ -f "$IDENTITY_FILE" ]]; then
    BASE_MAC=$(grep '^BASE_ETH0_MAC=' "$IDENTITY_FILE" 2>/dev/null | cut -d= -f2- | tr '[:upper:]' '[:lower:]' || true)
    BASE_HOST=$(grep '^BASE_HOSTNAME=' "$IDENTITY_FILE" 2>/dev/null | cut -d= -f2- || true)
    BASE_WG_PUB=$(grep '^BASE_WG_PUBLIC_KEY=' "$IDENTITY_FILE" 2>/dev/null | cut -d= -f2- || true)

    if [[ -n "$BASE_MAC" && -n "$CUR_MAC" && "$BASE_MAC" != "$CUR_MAC" ]]; then
        fail "Geräte-MAC geändert: $BASE_MAC -> $CUR_MAC"
        hint "Fritzbox: Gerät neu zuordnen, DHCP-Reservierung und IPv6-Portfreigaben prüfen"
        hint "Wenn neuer Pi: gleicher WireGuard-Key empfohlen oder Peer-Public-Key auf Gegenstelle aktualisieren"
    else
        ok "Geräte-MAC unverändert"
    fi

    if [[ -n "$BASE_HOST" && -n "$CUR_HOST" && "$BASE_HOST" != "$CUR_HOST" ]]; then
        warn "Hostname geändert: $BASE_HOST -> $CUR_HOST"
    else
        ok "Hostname unverändert"
    fi

    if [[ -n "$BASE_WG_PUB" && -n "$CUR_WG_PUB" && "$BASE_WG_PUB" != "$CUR_WG_PUB" ]]; then
        fail "WireGuard Public Key geändert"
        hint "OPNsense/Peers: Public Key dieses Standorts aktualisieren"
    elif [[ -n "$CUR_WG_PUB" ]]; then
        ok "WireGuard Public Key unverändert"
    else
        warn "WireGuard Public Key nicht ermittelbar (wg0 aktiv?)"
    fi
else
    {
        echo "# PI-VPN Hardware-Referenz (automatisch erzeugt)"
        echo "BASE_ETH0_MAC=${CUR_MAC}"
        echo "BASE_HOSTNAME=${CUR_HOST}"
        echo "BASE_WG_PUBLIC_KEY=${CUR_WG_PUB}"
        echo "CREATED_AT=$(date -Iseconds)"
    } > "$IDENTITY_FILE"
    chmod 600 "$IDENTITY_FILE" 2>/dev/null || true

    warn "Keine Hardware-Referenz vorhanden — wurde jetzt angelegt: $IDENTITY_FILE"
    hint "Beim nächsten check.sh werden MAC/Key-Änderungen automatisch erkannt"
fi

# =============================================================================
# 12. KONFIGURATION (.env)
# =============================================================================
sect "KONFIGURATION (.env)"

if [[ -f "$ENV_FILE" ]]; then
    ok ".env vorhanden"

    for VAR in VPN_HOST WG_PASSWORD; do
        VAL=$(grep "^${VAR}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$VAL" ]]; then
            ok "$VAR: gesetzt"
        else
            warn "$VAR: leer oder nicht gesetzt"
            hint "nano $ENV_FILE"
        fi
    done

    if grep -qE 'vpn\.deine-domain\.de|CHANGE_ME|your-domain|<DOMAIN>|<PASS>' "$ENV_FILE" 2>/dev/null; then
        fail ".env enthält noch Platzhalter-Werte!"
        hint "nano $ENV_FILE"
    else
        ok ".env: keine Standard-Platzhalter gefunden"
    fi
else
    fail ".env nicht vorhanden"
    hint "cp $DOCKER_DIR/.env.example $ENV_FILE && nano $ENV_FILE"
fi

# =============================================================================
# ZUSAMMENFASSUNG
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Zusammenfassung                                                     ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}✔${NC}  $PASS Checks bestanden"
[[ $WARN -gt 0 ]] && echo -e "  ${YELLOW}⚠${NC}  $WARN Warnungen"
[[ $FAIL -gt 0 ]] && echo -e "  ${RED}✘${NC}  $FAIL Fehler"
echo ""

if   [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Alles in Ordnung!${NC}"
elif [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}Fehler gefunden — Reparatur empfohlen:${NC}"
    echo -e "  ${DIM}sudo bash $SCRIPT_DIR/scripts/manage/repair.sh${NC}"
else
    echo -e "  ${YELLOW}Warnungen vorhanden — Details oben prüfen.${NC}"
    echo -e "  ${DIM}sudo bash $SCRIPT_DIR/scripts/manage/repair.sh${NC}"
fi
echo ""
