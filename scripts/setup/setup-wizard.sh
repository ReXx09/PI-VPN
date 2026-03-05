#!/usr/bin/env bash
# =============================================================================
# PI-VPN Setup-Wizard
# Interaktiver Installer für den Nebenwohnsitz-Raspberry Pi
#
# Ausführen als: sudo bash scripts/setup/setup-wizard.sh
#
# Was dieser Wizard erledigt:
#   1.  Systemvoraussetzungen prüfen
#   2.  Docker CE + Docker Compose installieren (falls noch nicht vorhanden)
#   3.  IP-Forwarding + Kernel-Tweaks setzen
#   4.  Dich durch alle Konfigurationswerte führen
#   5.  .env-Datei automatisch generieren
#   6.  Container starten
#   7.  Verbindungstest durchführen
#   8.  Nächste Schritte erklären
# =============================================================================

set -euo pipefail

# ─── Farben & Symbole ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()      { echo -e "  ${GREEN}✔${NC}  $*"; }
info()    { echo -e "  ${CYAN}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "\n  ${RED}✘ FEHLER:${NC} $*\n"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}┌─── Schritt $* ${NC}"; }
divider() { echo -e "${DIM}────────────────────────────────────────────────────────${NC}"; }
blank()   { echo ""; }

ask() {
    # ask "Beschreibung" "Beispiel/Default" VARIABLE_NAME [noecho]
    local prompt="$1"
    local example="$2"
    local varname="$3"
    local noecho="${4:-}"
    local input

    blank
    echo -e "  ${BOLD}${prompt}${NC}"
    [[ -n "$example" ]] && echo -e "  ${DIM}Beispiel / Vorgabe: ${example}${NC}"
    echo -ne "  ${CYAN}▶${NC} "

    if [[ "$noecho" == "noecho" ]]; then
        read -rs input
        echo ""
    else
        read -r input
    fi

    # Leer → Vorgabe nehmen wenn Vorgabe kein Platzhalterwert
    if [[ -z "$input" && -n "$example" && "$example" != *"CHANGEME"* && "$example" != *"<"* ]]; then
        input="$example"
    fi

    printf -v "$varname" '%s' "$input"
}

ask_yn() {
    # ask_yn "Frage" → gibt 0 (ja) oder 1 (nein) zurück
    local prompt="$1"
    local default="${2:-j}"
    local answer
    blank
    echo -ne "  ${BOLD}${prompt}${NC} ${DIM}[j/n, Vorgabe: ${default}]${NC} ${CYAN}▶${NC} "
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[jJyY] ]]
}

validate_password() {
    local pw="$1"
    [[ ${#pw} -ge 12 ]] || return 1
    return 0
}

# ─── Root-Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Bitte als root ausführen: sudo bash $0"
[[ "$(uname -s)" == "Linux" ]] || error "Dieses Skript ist nur für Linux (Raspberry Pi OS)."

# ─── Pfade ermitteln ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker/nebenwohnsitz"
ENV_FILE="$DOCKER_DIR/.env"
RASPI_IP=$(hostname -I | awk '{print $1}')

# ═════════════════════════════════════════════════════════════════════════════
# WILLKOMMEN
# ═════════════════════════════════════════════════════════════════════════════
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ██████╗ ██╗      ██╗   ██╗██████╗ ███╗   ██╗"
echo "  ██╔══██╗██║      ██║   ██║██╔══██╗████╗  ██║"
echo "  ██████╔╝██║█████╗██║   ██║██████╔╝██╔██╗ ██║"
echo "  ██╔═══╝ ██║╚════╝╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║"
echo "  ██║     ██║       ╚████╔╝ ██║     ██║ ╚████║"
echo "  ╚═╝     ╚═╝        ╚═══╝  ╚═╝     ╚═╝  ╚═══╝"
echo -e "${NC}"
echo -e "  ${BOLD}Site-to-Site WireGuard Setup-Wizard${NC}"
echo -e "  ${DIM}Nebenwohnsitz — Raspberry Pi — wireguard-ui + ddns-go${NC}"
echo ""
divider
echo ""
echo -e "  Dieser Wizard richtet deinen Raspberry Pi als WireGuard-Client"
echo -e "  ein, der sich über ${BOLD}IPv6${NC} mit deiner OPNsense verbindet."
echo ""
echo -e "  ${YELLOW}Voraussetzungen:${NC}"
echo -e "  • OPNsense am Hauptwohnsitz ist bereits konfiguriert"
echo -e "    (WireGuard-Plugin aktiv, Peer 'nebenwohnsitz' angelegt)"
echo -e "  • Du kennst den öffentlichen Schlüssel der OPNsense"
echo -e "  • Du hast einen DDNS-Hostnamen für die OPNsense (AAAA-Record)"
echo ""
divider

if ! ask_yn "Jetzt starten?"; then
    echo -e "\n  Abgebrochen. Bis zum nächsten Mal!\n"
    exit 0
fi


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 1 — SYSTEMCHECK
# ═════════════════════════════════════════════════════════════════════════════
step "1 von 7 — Systemcheck"
divider

KERNEL=$(uname -r)
ARCH=$(uname -m)
OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unbekannt")

echo ""
echo -e "  Betriebssystem : ${BOLD}${OS_PRETTY}${NC}"
echo -e "  Kernel         : ${BOLD}${KERNEL}${NC}"
echo -e "  Architektur    : ${BOLD}${ARCH}${NC}"
echo -e "  IP-Adresse     : ${BOLD}${RASPI_IP}${NC}"
echo ""

# Kernel ≥ 5.6 für natives WireGuard-Modul
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL" | cut -d. -f2)
if [[ $KERNEL_MAJOR -gt 5 ]] || [[ $KERNEL_MAJOR -eq 5 && $KERNEL_MINOR -ge 6 ]]; then
    ok "Kernel $KERNEL unterstützt WireGuard nativ (kein extra Modul nötig)"
else
    warn "Kernel $KERNEL ist älter als 5.6 — WireGuard-Modul möglicherweise fehlt"
    warn "Empfehlung: 'sudo apt install wireguard-dkms' manuell ausführen"
fi

# wireguard-tools prüfen (für wg show auf dem Host)
if command -v wg &>/dev/null; then
    ok "wireguard-tools sind installiert ($(wg --version))"
else
    info "wireguard-tools werden jetzt installiert..."
    apt-get install -y -qq wireguard-tools 2>/dev/null && ok "wireguard-tools installiert" || warn "wireguard-tools konnten nicht installiert werden — wird von wireguard-ui übernommen"
fi


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 2 — DOCKER INSTALLIEREN
# ═════════════════════════════════════════════════════════════════════════════
step "2 von 7 — Docker"
divider

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "?")
    ok "Docker $DOCKER_VER ist bereits installiert"
    ok "Docker Compose $COMPOSE_VER ist bereits installiert"
else
    if ask_yn "Docker CE ist nicht installiert. Jetzt installieren?"; then
        info "Installiere Docker CE..."
        bash "$SCRIPT_DIR/install-docker.sh"
        ok "Docker installiert"
    else
        error "Docker wird benötigt. Breche ab."
    fi
fi

# IP-Forwarding setzen
info "Setze IP-Forwarding (IPv4 + IPv6)..."
tee /etc/sysctl.d/99-vpn-forward.conf > /dev/null << 'SYSCTL'
# PI-VPN: IP-Forwarding für WireGuard Site-to-Site
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.src_valid_mark = 1
# IPv6 Privacy Extensions deaktivieren (stabile SLAAC-Adresse für DDNS)
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
SYSCTL
sysctl --system > /dev/null 2>&1
ok "IP-Forwarding aktiv"


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 3 — WIREGUARD-UI KONFIGURATION
# ═════════════════════════════════════════════════════════════════════════════
step "3 von 7 — WireGuard-UI Konfiguration"
divider
echo ""
echo -e "  Die folgenden Einstellungen gelten für die ${BOLD}wireguard-ui WebUI${NC}."
echo -e "  Danach richtest du die eigentliche VPN-Verbindung in der WebUI ein."
echo ""

# Benutzername
ask "Benutzername für die wireguard-ui WebUI:" "admin" WGUI_USERNAME
[[ -z "$WGUI_USERNAME" ]] && WGUI_USERNAME="admin"
ok "Benutzername: $WGUI_USERNAME"

# Passwort
while true; do
    ask "Passwort für die WebUI (min. 12 Zeichen):" "<wird nicht angezeigt>" WGUI_PASSWORD "noecho"
    if validate_password "$WGUI_PASSWORD"; then
        ask "Passwort wiederholen:" "" WGUI_PASSWORD_CONFIRM "noecho"
        if [[ "$WGUI_PASSWORD" == "$WGUI_PASSWORD_CONFIRM" ]]; then
            ok "Passwort gesetzt"
            break
        else
            warn "Passwörter stimmen nicht überein — bitte erneut eingeben."
        fi
    else
        warn "Passwort zu kurz (min. 12 Zeichen) — bitte erneut eingeben."
    fi
done

# Session-Secret automatisch generieren
if command -v openssl &>/dev/null; then
    SESSION_SECRET=$(openssl rand -hex 32)
    ok "Session-Secret automatisch generiert (openssl rand -hex 32)"
else
    SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 64)
    ok "Session-Secret generiert"
fi


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 4 — NETZWERK-EINSTELLUNGEN
# ═════════════════════════════════════════════════════════════════════════════
step "4 von 7 — Netzwerk & VPN-Parameter"
divider
echo ""
echo -e "  ${BOLD}VPN-IP dieses Raspberry Pi${NC}"
echo -e "  ${DIM}Das ist die IP im WireGuard-Tunnel-Subnetz (10.10.0.0/24).${NC}"
echo -e "  ${DIM}OPNsense (Server) hat 10.10.0.1 — dieser Raspi bekommt 10.10.0.2.${NC}"
echo ""

ask "Tunnel-IP dieses Raspberry Pi:" "10.10.0.2/24" WGUI_SERVER_ADDR
[[ -z "$WGUI_SERVER_ADDR" ]] && WGUI_SERVER_ADDR="10.10.0.2/24"
ok "VPN-IP: $WGUI_SERVER_ADDR"

blank
echo -e "  ${BOLD}MTU (Maximum Transmission Unit)${NC}"
echo -e "  ${DIM}Vodafone Kabel (DS-Lite) mit IPv6: 1280 ist der sichere Wert.${NC}"
echo -e "  ${DIM}Verhindert Fragmentierung im Tunnel.${NC}"
echo ""

ask "MTU:" "1280" WGUI_MTU
[[ -z "$WGUI_MTU" ]] && WGUI_MTU="1280"
ok "MTU: $WGUI_MTU"

blank
echo -e "  ${BOLD}DNS-Server für VPN-Clients${NC}"
echo -e "  ${DIM}10.10.0.1 = OPNsense (empfohlen, löst Heimnetz-Hostnamen auf).${NC}"
echo -e "  ${DIM}Mehrere Einträge mit Komma trennen.${NC}"
echo ""

ask "DNS:" "10.10.0.1,1.1.1.1" WGUI_DNS
[[ -z "$WGUI_DNS" ]] && WGUI_DNS="10.10.0.1,1.1.1.1"
ok "DNS: $WGUI_DNS"

blank
echo -e "  ${BOLD}Heimnetz am Nebenwohnsitz (Fritzbox-LAN)${NC}"
echo -e "  ${DIM}Wird für die iptables MASQUERADE-Regel benötigt,${NC}"
echo -e "  ${DIM}damit alle Geräte in der Fritzbox den VPN-Tunnel nutzen können.${NC}"
echo ""

ask "LAN-Subnetz am Nebenwohnsitz:" "192.168.20.0/24" LAN_SUBNET
[[ -z "$LAN_SUBNET" ]] && LAN_SUBNET="192.168.20.0/24"
ok "LAN-Subnetz: $LAN_SUBNET"

blank
echo -e "  ${BOLD}Netzwerk-Interface des Raspberry Pi${NC}"
echo -e "  ${DIM}Das Interface zum Fritzbox-LAN (LAN-Kabel = eth0, WLAN = wlan0).${NC}"
echo -e "  ${DIM}Aktuelle Interfaces:${NC}"
ip link show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | tr -d ':'
echo ""

ask "LAN-Interface:" "eth0" LAN_IFACE
[[ -z "$LAN_IFACE" ]] && LAN_IFACE="eth0"
ok "Interface: $LAN_IFACE"


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 5 — DDNS KONFIGURATION
# ═════════════════════════════════════════════════════════════════════════════
step "5 von 7 — DDNS (optional)"
divider
echo ""
echo -e "  ${BOLD}ddns-go${NC} hält automatisch einen ${BOLD}AAAA-Record${NC} mit der aktuellen"
echo -e "  IPv6-Adresse dieses Raspberry Pi aktuell."
echo ""
echo -e "  ${DIM}Nützlich wenn OPNsense Firewall-Regeln auf die Client-IPv6${NC}"
echo -e "  ${DIM}matchen soll, oder wenn der Raspi selbst als Endpoint dient.${NC}"
echo ""

SETUP_DDNS=false
if ask_yn "DDNS für diesen Raspberry Pi einrichten?"; then
    SETUP_DDNS=true

    blank
    echo -e "  ${BOLD}DDNS-Provider${NC}"
    echo -e "  ${DIM}Unterstützt werden u.a.: Cloudflare, DeSEC, Duck DNS, AliDNS, ...${NC}"
    echo -e "  ${DIM}Vollständige Liste: https://github.com/jeessy2/ddns-go${NC}"
    echo -e "  ${DIM}→ Konfiguration erfolgt nach dem Start über die WebUI (Port 9876).${NC}"
    echo ""
    warn "DDNS-Konfiguration (API-Token, Domain, Provider) findet nach dem"
    warn "Container-Start in der ddns-go WebUI statt: http://${RASPI_IP}:9876"
else
    info "DDNS übersprungen. Container wird trotzdem gestartet."
    info "Konfiguration jederzeit über http://${RASPI_IP}:9876 möglich."
fi


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 6 — ZUSAMMENFASSUNG & .ENV ERSTELLEN
# ═════════════════════════════════════════════════════════════════════════════
step "6 von 7 — Zusammenfassung & Konfiguration speichern"
divider
echo ""
echo -e "  ${BOLD}Folgende Werte werden in .env gespeichert:${NC}"
echo ""
echo -e "  Benutzername      : ${BOLD}${WGUI_USERNAME}${NC}"
echo -e "  Passwort          : ${BOLD}$(echo "$WGUI_PASSWORD" | sed 's/./*/g')${NC}"
echo -e "  Session-Secret    : ${BOLD}$(echo "$SESSION_SECRET" | cut -c1-8)...${NC} (automatisch generiert)"
echo -e "  Tunnel-IP (Raspi) : ${BOLD}${WGUI_SERVER_ADDR}${NC}"
echo -e "  DNS               : ${BOLD}${WGUI_DNS}${NC}"
echo -e "  MTU               : ${BOLD}${WGUI_MTU}${NC}"
echo -e "  LAN-Subnetz       : ${BOLD}${LAN_SUBNET}${NC}"
echo -e "  LAN-Interface     : ${BOLD}${LAN_IFACE}${NC}"
echo ""

if ! ask_yn "Alles korrekt? Jetzt speichern und Container starten?"; then
    warn "Abgebrochen. Führe das Skript erneut aus um Werte zu ändern."
    exit 1
fi

# Datenverzeichnisse anlegen
info "Erstelle Datenverzeichnisse..."
mkdir -p "$DOCKER_DIR/data/wireguard"
mkdir -p "$DOCKER_DIR/data/db"
mkdir -p "$DOCKER_DIR/data/ddns-go"
chmod 700 "$DOCKER_DIR/data/wireguard"
ok "Verzeichnisse erstellt"

# PostUp/PostDown für iptables-MASQUERADE (LAN-Routing)
POSTUP="iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${LAN_IFACE} -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${LAN_IFACE} -j MASQUERADE"
POSTDOWN="iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${LAN_IFACE} -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${LAN_IFACE} -j MASQUERADE"

# .env schreiben
info "Schreibe .env..."
cat > "$ENV_FILE" << ENVFILE
# =============================================================================
# PI-VPN Nebenwohnsitz — generiert vom Setup-Wizard am $(date '+%d.%m.%Y %H:%M')
# NIEMALS in Git committen!
# =============================================================================

# WireGuard-UI Login
WGUI_USERNAME=${WGUI_USERNAME}
WGUI_PASSWORD=${WGUI_PASSWORD}

# Session-Secret (automatisch generiert)
SESSION_SECRET=${SESSION_SECRET}

# Tunnel-Interface dieses Raspberry Pi
WGUI_SERVER_INTERFACE_ADDRESSES=${WGUI_SERVER_ADDR}
WGUI_SERVER_LISTEN_PORT=51820
WGUI_MTU=${WGUI_MTU}
WGUI_DNS=${WGUI_DNS}
WGUI_PERSISTENT_KEEPALIVE=25
WGUI_CONFIG_FILE_PATH=/etc/wireguard/wg0.conf
WGUI_MANAGE_START=true
WGUI_MANAGE_RESTART=true

# Routing: LAN-Subnetz Nebenwohnsitz (${LAN_SUBNET}) über wg0
# Wird in der wireguard-ui WebUI unter PostUp/PostDown eingetragen:
# PostUp:   ${POSTUP}
# PostDown: ${POSTDOWN}
LAN_SUBNET=${LAN_SUBNET}
LAN_IFACE=${LAN_IFACE}
ENVFILE

chmod 600 "$ENV_FILE"
ok ".env gespeichert: $ENV_FILE"


# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 7 — CONTAINER STARTEN & PRÜFEN
# ═════════════════════════════════════════════════════════════════════════════
step "7 von 7 — Container starten"
divider
blank

info "Starte Docker-Stack in $DOCKER_DIR ..."
cd "$DOCKER_DIR"
docker compose up -d

# Kurz warten bis Container bereit sind
info "Warte auf Container-Start (10 Sekunden)..."
sleep 10

# Status prüfen
blank
WGUI_STATUS=$(docker inspect -f '{{.State.Status}}' wireguard-ui 2>/dev/null || echo "nicht gefunden")
DDNS_STATUS=$(docker inspect -f '{{.State.Status}}' ddns-go 2>/dev/null || echo "nicht gefunden")

[[ "$WGUI_STATUS" == "running" ]] && ok "wireguard-ui läuft" || warn "wireguard-ui Status: $WGUI_STATUS"
[[ "$DDNS_STATUS" == "running" ]] && ok "ddns-go läuft"      || warn "ddns-go Status: $DDNS_STATUS"


# ═════════════════════════════════════════════════════════════════════════════
# FERTIG — NÄCHSTE SCHRITTE
# ═════════════════════════════════════════════════════════════════════════════
blank
echo ""
divider
echo ""
echo -e "  ${BOLD}${GREEN}✔ Setup abgeschlossen!${NC}"
echo ""
divider
echo ""
echo -e "  ${BOLD}Nächste Schritte in der wireguard-ui WebUI:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} WebUI öffnen:"
echo -e "     ${BOLD}http://${RASPI_IP}:5000${NC}"
echo -e "     Login: ${WGUI_USERNAME} / (dein Passwort)"
echo ""
echo -e "  ${CYAN}2.${NC} ${BOLD}\"WireGuard Server\"${NC} → Einstellungen prüfen:"
echo -e "     • Server Address  : ${WGUI_SERVER_ADDR}"
echo -e "     • Listen Port     : 51820"
echo -e "     • MTU             : ${WGUI_MTU}"
echo -e "     • DNS             : ${WGUI_DNS}"
echo -e "     • Post Up         :"
echo -e "       ${DIM}${POSTUP}${NC}"
echo -e "     • Post Down       :"
echo -e "       ${DIM}${POSTDOWN}${NC}"
echo -e "     → ${BOLD}\"Save\"${NC} klicken"
echo ""
echo -e "  ${CYAN}3.${NC} ${BOLD}\"Wireguard Clients\"${NC} → ${BOLD}\"+New Client\"${NC} (= OPNsense als Peer):"
echo -e "     • Name            : OPNsense-Hauptwohnsitz"
echo -e "     • Public Key      : <Öffentlichen Schlüssel aus OPNsense einfügen>"
echo -e "       $(echo -e "${DIM}OPNsense → VPN → WireGuard → Lokal → wg-server → Schlüssel${NC}")"
echo -e "     • Allocated IPs   : 10.10.0.1/32"
echo -e "     • Allowed IPs:"
echo -e "       ${BOLD}Split-Tunnel${NC}: 10.10.0.0/24, 192.168.10.0/24"
echo -e "       ${BOLD}Full-Tunnel${NC} : 0.0.0.0/0, ::/0  (alle Streaming-Dienste)"
echo -e "     • Endpoint        : vpn-home.DEINE-DOMAIN.de:51820"
echo -e "     • Keepalive       : 25"
echo -e "     → ${BOLD}\"Save\"${NC} → ${BOLD}\"Apply Config\"${NC}"
echo ""
echo -e "  ${CYAN}4.${NC} Tunnel prüfen:"
echo -e "     ${DIM}sudo docker exec wireguard-ui wg show${NC}"
echo -e "     (Latest handshake sollte erscheinen sobald OPNsense verbindet)"
echo ""

if $SETUP_DDNS; then
    echo -e "  ${CYAN}5.${NC} ${BOLD}DDNS${NC} konfigurieren:"
    echo -e "     ${BOLD}http://${RASPI_IP}:9876${NC}"
    echo -e "     Provider, API-Token und Hostname (AAAA) eintragen."
    echo ""
fi

divider
echo ""
echo -e "  ${DIM}Logs:   sudo docker compose -f $DOCKER_DIR/docker-compose.yml logs -f${NC}"
echo -e "  ${DIM}Status: sudo bash $PROJECT_ROOT/scripts/manage/status.sh${NC}"
echo -e "  ${DIM}Backup: sudo bash $PROJECT_ROOT/scripts/manage/backup.sh${NC}"
echo ""
divider
echo ""
