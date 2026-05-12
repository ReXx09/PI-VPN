#!/usr/bin/env bash
# =============================================================================
# PI-VPN — Zentrales Menü (TUI)
# Grafische Terminal-Oberfläche für alle PI-VPN Funktionen
#
# Copyright (c) 2026 Bocki — MIT License
# https://github.com/ReXx09/PI-VPN
#
# Ausführen als: sudo bash /opt/pi-vpn/menu.sh
#
# Funktionen:
#   • Setup & Installation   — Wizard, Docker, Init
#   • Status & Monitoring    — VPN-Status, Logs, Interface
#   • Container-Verwaltung   — Start/Stop/Restart, Backup
#   • Konfiguration          — .env bearbeiten, git pull
#   • Reset & Deinstallation — Interaktiver Reset (reset.sh)
#
# Benötigt: whiptail (vorinstalliert auf Raspberry Pi OS Bookworm)
#           Fallback: einfaches Textmenü
# =============================================================================

set -uo pipefail

# ─── Pfade ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR/scripts/setup"
MANAGE_DIR="$SCRIPT_DIR/scripts/manage"
DOCKER_DIR="$SCRIPT_DIR/docker/nebenwohnsitz"
ENV_FILE="$DOCKER_DIR/.env"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

# ─── Diagnose-Konfiguration ───────────────────────────────────────────────────
# Diese Werte anpassen oder als Umgebungsvariable vorab setzen:
#   export VPN_HOST=vpn.meine-domain.de
#   export HAUPT_GW=192.168.x.1
VPN_HOST="${VPN_HOST:-vpn.deine-domain.de}"   # DDNS-Hostname des WireGuard-Servers
HAUPT_GW="${HAUPT_GW:-<HAUPT-GW>}"            # LAN-Gateway des Hauptwohnsitzes

# ─── Root-Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen: sudo bash $0"; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "Nur für Linux (Raspberry Pi OS)."; exit 1; }

# ─── Farben (für Text-Fallback) ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── whiptail prüfen ──────────────────────────────────────────────────────────
HAS_WHIPTAIL=false
command -v whiptail &>/dev/null && HAS_WHIPTAIL=true

# ─── Hilfsfunktionen ──────────────────────────────────────────────────────────
press_enter() {
    echo ""
    echo -e "  ${DIM}[Enter] drücken um ins Menü zurückzukehren…${NC}"
    read -r
}

vpn_status() {
    if ip link show wg0 &>/dev/null 2>&1; then
        local HS
        HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true
        if [[ -n "$HS" && "$HS" != "0" ]]; then
            echo "VPN: AKTIV ✔"
        else
            echo "VPN: wg0 UP (kein Handshake)"
        fi
    else
        echo "VPN: INAKTIV ✘"
    fi
}

container_status() {
    if ! command -v docker &>/dev/null; then
        echo "Docker: nicht inst."
        return
    fi
    local WG DDNS
    WG=$(docker inspect -f '{{.State.Running}}' wireguard-ui 2>/dev/null || echo "false")
    DDNS=$(docker inspect -f '{{.State.Running}}' ddns-go 2>/dev/null || echo "false")
    if [[ "$WG" == "true" && "$DDNS" == "true" ]]; then
        echo "Container: LAUFEN ✔"
    elif [[ "$WG" == "true" || "$DDNS" == "true" ]]; then
        echo "Container: TEILWEISE ⚠"
    else
        echo "Container: GESTOPPT ✘"
    fi
}

ddns_status() {
    if ! command -v docker &>/dev/null; then
        echo "DDNS: ?"
        return
    fi
    local STATE=""
    STATE=$(docker inspect -f '{{.State.Running}}' ddns-go 2>/dev/null || echo "false")
    if [[ "$STATE" != "true" ]]; then
        echo "DDNS: GESTOPPT ✘"
        return
    fi
    # Letzte Log-Zeilen auf Fehler prüfen
    local LAST=""
    LAST=$(docker logs ddns-go --tail 5 2>&1 || true)
    LAST=$(echo "$LAST" | tr '[:upper:]' '[:lower:]' || true)
    if echo "$LAST" | grep -qE "error|fail" 2>/dev/null; then
        echo "DDNS: FEHLER ⚠"
        return
    fi
    # Domain aus ddns-go Konfig-Datei lesen (.ddns_go_config.yaml im Volume)
    local CONF="$DOCKER_DIR/data/ddns-go/.ddns_go_config.yaml"
    local DOMAIN=""
    if [[ -f "$CONF" ]]; then
        DOMAIN=$(grep -i 'domainname' "$CONF" 2>/dev/null \
            | awk -F': ' '{print $2}' | tr -d '"' | xargs 2>/dev/null | head -c 30 || true)
    fi
    if [[ -n "$DOMAIN" ]]; then
        echo "DDNS: $DOMAIN ✔"
    else
        echo "DDNS: nicht konfiguriert"
    fi
}

raspi_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "?.?.?.?"
}

vpn_peer_ip() {
    # Erste konfigurierte Peer-IP aus wg0 (z.B. OPNsense)
    wg show wg0 allowed-ips 2>/dev/null | awk '{print $2}' | cut -d'/' -f1 | grep -v '^$' | head -1
}

# =============================================================================
# WHIPTAIL — Grafisches TUI-Menü
# =============================================================================

# ─── Hauptmenü ────────────────────────────────────────────────────────────────
main_menu_whiptail() {
    while true; do
        local VPN_ST CONT_ST DDNS_ST STATUS_LINE
        VPN_ST=$(vpn_status)
        CONT_ST=$(container_status)
        DDNS_ST=$(ddns_status)
        STATUS_LINE="  ${VPN_ST}  |  ${CONT_ST}  |  ${DDNS_ST}"

        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN | Zentrales Menue  |  $(hostname)  |  © 2026 Bocki" \
            --menu "${STATUS_LINE}\n\nWähle eine Kategorie:" \
            26 84 10 \
            "1" "  🔧  Setup & Installation" \
            "2" "  📊  Status & Monitoring" \
            "3" "  🐳  VPN-Dienste verwalten" \
            "4" "  ⚙️  Konfiguration & Updates" \
            "5" "  🔄  Reset & Deinstallation" \
            "6" "  🌐  WebUI-Adressen anzeigen" \
            "7" "  🔬  Diagnose & Tools" \
            "8" "  💾  Backup & Wiederherstellen" \
            "0" "  ❌  Beenden" \
            3>&1 1>&2 2>&3) || break

        case "$CHOICE" in
            1) menu_setup_wt ;;
            2) menu_status_wt ;;
            3) menu_container_wt ;;
            4) menu_config_wt ;;
            5) menu_reset_wt ;;
            6) show_webui_addresses_wt ;;
            7) menu_diag_wt ;;
            8) menu_backup_wt ;;
            0|"") break ;;
        esac
    done
}

# ─── Untermenü: Setup ─────────────────────────────────────────────────────────
menu_setup_wt() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN | Setup & Installation" \
            --menu "\nWelche Aktion soll ausgeführt werden?" \
            20 68 6 \
            "1" "  Vollständige Installation       (setup-wizard.sh)" \
            "2" "  Dashboard nachinstallieren  (install-dashboard.sh)" \
            "3" "  Nur Docker CE installieren     (install-docker.sh)" \
            "4" "  Verzeichnisse anlegen                    (init.sh)" \
            "0" "  ← Zurück zum Hauptmenü" \
            3>&1 1>&2 2>&3) || return

        case "$CHOICE" in
            1)
                clear
                bash "$SETUP_DIR/setup-wizard.sh"
                press_enter
                ;;
            2)
                clear
                bash "$SETUP_DIR/install-dashboard.sh"
                press_enter
                ;;
            3)
                clear
                bash "$SETUP_DIR/install-docker.sh"
                press_enter
                ;;
            4)
                clear
                bash "$SETUP_DIR/init.sh"
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# ─── Untermenü: Status ────────────────────────────────────────────────────────
menu_status_wt() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN | Status & Monitoring" \
            --menu "\nWas soll angezeigt werden?" \
            20 68 7 \
            "1" "  Vollständiger VPN-Status         (status.sh)" \
            "2" "  wireguard-ui Logs  (letzte 60 Zeilen)" \
            "3" "  ddns-go Logs       (letzte 60 Zeilen)" \
            "4" "  WireGuard Interface               (wg show)" \
            "5" "  Laufende Container               (docker ps)" \
            "6" "  IP-Routing-Tabelle         (ip route show)" \
            "0" "  ← Zurück zum Hauptmenü" \
            3>&1 1>&2 2>&3) || return

        case "$CHOICE" in
            1)
                clear
                bash "$MANAGE_DIR/status.sh"
                press_enter
                ;;
            2)
                clear
                echo -e "${BOLD}wireguard-ui Logs (letzte 60 Zeilen):${NC}\n"
                docker logs wireguard-ui --tail 60 2>&1 \
                    || echo -e "${RED}✘${NC}  Container 'wireguard-ui' nicht gefunden."
                press_enter
                ;;
            3)
                clear
                echo -e "${BOLD}ddns-go Logs (letzte 60 Zeilen):${NC}\n"
                docker logs ddns-go --tail 60 2>&1 \
                    || echo -e "${RED}✘${NC}  Container 'ddns-go' nicht gefunden."
                press_enter
                ;;
            4)
                clear
                echo -e "${BOLD}WireGuard Interface (wg show):${NC}\n"
                if command -v wg &>/dev/null; then
                    wg show 2>/dev/null || echo "  Kein aktives WireGuard-Interface."
                else
                    echo "  wg-tools nicht installiert."
                fi
                press_enter
                ;;
            5)
                clear
                echo -e "${BOLD}Laufende Docker-Container:${NC}\n"
                docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
                    || echo "  Docker nicht verfügbar."
                press_enter
                ;;
            6)
                clear
                echo -e "${BOLD}IP-Routing-Tabelle:${NC}\n"
                ip route show 2>/dev/null
                echo ""
                echo -e "${BOLD}IPv6-Routing:${NC}\n"
                ip -6 route show 2>/dev/null
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# ─── Untermenü: Container-Verwaltung ──────────────────────────────────────────
menu_container_wt() {
    while true; do
        local WG_STATE DDNS_STATE STATUS_INFO WG_ICON DDNS_ICON
        WG_STATE=$(docker inspect -f '{{.State.Status}}' wireguard-ui 2>/dev/null || echo "nicht gefunden")
        DDNS_STATE=$(docker inspect -f '{{.State.Status}}' ddns-go 2>/dev/null || echo "nicht gefunden")
        [[ "$WG_STATE" == "running" ]] && WG_ICON="✔" || WG_ICON="✘"
        [[ "$DDNS_STATE" == "running" ]] && DDNS_ICON="✔" || DDNS_ICON="✘"
        STATUS_INFO="  wireguard-ui: ${WG_STATE} ${WG_ICON}  |  ddns-go: ${DDNS_STATE} ${DDNS_ICON}"

        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN | VPN-Dienste verwalten" \
            --menu "${STATUS_INFO}\n\nWelche Aktion?" \
            22 72 7 \
            "1" "  Alle Container starten" \
            "2" "  Alle Container stoppen" \
            "3" "  Alle Container neu starten" \
            "4" "  wireguard-ui neu starten" \
            "5" "  ddns-go neu starten" \
            "6" "  Live-Logs verfolgen  (Ctrl+C zum Beenden)" \
            "0" "  ← Zurück zum Hauptmenü" \
            3>&1 1>&2 2>&3) || return

        case "$CHOICE" in
            1)
                clear
                echo -e "${BOLD}Starte Container…${NC}\n"
                docker compose -f "$COMPOSE_FILE" up -d \
                    && echo -e "\n${GREEN}✔  Container gestartet${NC}" \
                    || echo -e "\n${RED}✘  Fehler beim Starten${NC}"
                press_enter
                ;;
            2)
                if whiptail --title "Container stoppen" \
                    --yesno "Alle Container stoppen?\n\nDer VPN-Tunnel wird dabei unterbrochen." \
                    10 60; then
                    clear
                    echo -e "${BOLD}Stoppe Container…${NC}\n"
                    docker compose -f "$COMPOSE_FILE" stop \
                        && echo -e "\n${GREEN}✔  Container gestoppt${NC}" \
                        || echo -e "\n${RED}✘  Fehler${NC}"
                    press_enter
                fi
                ;;
            3)
                clear
                echo -e "${BOLD}Starte Container neu…${NC}\n"
                docker compose -f "$COMPOSE_FILE" restart \
                    && echo -e "\n${GREEN}✔  Container neugestartet${NC}" \
                    || echo -e "\n${RED}✘  Fehler${NC}"
                press_enter
                ;;
            4)
                clear
                echo -e "${BOLD}Starte wireguard-ui neu…${NC}\n"
                docker restart wireguard-ui \
                    && echo -e "\n${GREEN}✔  wireguard-ui neugestartet${NC}" \
                    || echo -e "\n${RED}✘  Container nicht gefunden${NC}"
                press_enter
                ;;
            5)
                clear
                echo -e "${BOLD}Starte ddns-go neu…${NC}\n"
                docker restart ddns-go \
                    && echo -e "\n${GREEN}✔  ddns-go neugestartet${NC}" \
                    || echo -e "\n${RED}✘  Container nicht gefunden${NC}"
                press_enter
                ;;
            6)
                clear
                echo -e "${BOLD}Live-Logs (Ctrl+C zum Beenden):${NC}\n"
                docker compose -f "$COMPOSE_FILE" logs -f --tail 20 2>&1 || true
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# ─── Untermenü: Konfiguration ─────────────────────────────────────────────────
menu_config_wt() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN -- Konfiguration & Updates" \
            --menu "\nWas soll bearbeitet werden?" \
            20 68 6 \
            "1" "  .env-Datei bearbeiten              (nano)" \
            "2" "  docker-compose.yml anzeigen" \
            "3" "  Updates vom GitHub holen      (git pull)" \
            "4" "  WireGuard-Konfig anzeigen    (wg0.conf)" \
            "5" "  Raspberry Pi Systeminformationen" \
            "0" "  ← Zurück zum Hauptmenü" \
            3>&1 1>&2 2>&3) || return

        case "$CHOICE" in
            1)
                if [[ -f "$ENV_FILE" ]]; then
                    nano "$ENV_FILE"
                else
                    whiptail --title "Fehler" --msgbox \
                        ".env-Datei nicht gefunden!\n\nFühre zuerst den Setup-Wizard aus:\n  sudo bash /opt/pi-vpn/menu.sh → Setup & Installation" \
                        12 62
                fi
                ;;
            2)
                clear
                echo -e "${BOLD}docker-compose.yml:${NC}\n"
                cat "$COMPOSE_FILE" 2>/dev/null \
                    || echo "  Datei nicht gefunden: $COMPOSE_FILE"
                press_enter
                ;;
            3)
                clear
                echo -e "${BOLD}Updates vom GitHub holen (git pull)…${NC}\n"
                cd "$SCRIPT_DIR" && git pull \
                    && echo -e "\n${GREEN}✔  Aktualisiert${NC}" \
                    || echo -e "\n${YELLOW}⚠  git pull fehlgeschlagen (Token abgelaufen?)${NC}"
                press_enter
                ;;
            4)
                clear
                local WG_CONF="$DOCKER_DIR/data/wireguard/wg0.conf"
                echo -e "${BOLD}WireGuard-Konfig (wg0.conf):${NC}\n"
                if [[ -f "$WG_CONF" ]]; then
                    cat "$WG_CONF"
                else
                    echo "  wg0.conf nicht gefunden: $WG_CONF"
                    echo "  (Erst nach dem Setup-Wizard vorhanden)"
                fi
                press_enter
                ;;
            5)
                clear
                echo -e "${BOLD}Raspberry Pi Systeminformationen:${NC}\n"
                echo -e "  ${CYAN}Hostname:${NC}      $(hostname)"
                echo -e "  ${CYAN}IP-Adresse:${NC}    $(raspi_ip)"
                echo -e "  ${CYAN}Betriebssystem:${NC}$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
                echo -e "  ${CYAN}Kernel:${NC}        $(uname -r)"
                echo -e "  ${CYAN}Uptime:${NC}        $(uptime -p 2>/dev/null || uptime)"
                echo -e "  ${CYAN}Speicher:${NC}"
                free -h | grep Mem | awk '{printf "    gesamt: %s  frei: %s  verw.: %s\n", $2, $4, $3}'
                echo -e "  ${CYAN}Festplatte:${NC}"
                df -h / | tail -1 | awk '{printf "    gesamt: %s  frei: %s  verw.: %s\n", $2, $4, $5}'
                echo -e "  ${CYAN}Docker:${NC}        $(docker --version 2>/dev/null || echo 'nicht installiert')"
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# ─── Untermenü: Reset ─────────────────────────────────────────────────────────
menu_reset_wt() {
    whiptail \
        --title "PI-VPN | Reset & Deinstallation" \
        --yesno \
        "Das Reset-Skript führt dich interaktiv durch folgende Schritte:\n\n\
  ① wg0-Tunnel sofort trennen\n\
  ② Docker-Container stoppen und entfernen\n\
  ③ Docker-Volumes löschen (Keys, Peers, wireguard-ui DB)\n\
  ④ Docker-Images entfernen (optional)\n\
  ⑤ .env-Datei löschen (Passwörter/Secrets)\n\
  ⑥ IP-Forwarding zurücksetzen (optional)\n\
  ⑦ Docker CE deinstallieren (optional)\n\
  ⑧ Projekt-Verzeichnis löschen (optional)\n\n\
Jede Stufe wird einzeln bestätigt.\n\nJetzt das Reset-Skript starten?" \
        24 70 || return

    clear
    bash "$MANAGE_DIR/reset.sh"
    press_enter
}

# ─── WebUI-Adressen anzeigen ──────────────────────────────────────────────────
show_webui_addresses_wt() {
    local IP
    IP=$(raspi_ip)
    whiptail \
        --title "PI-VPN | WebUI-Adressen" \
        --msgbox \
        "  Adressen im lokalen Netzwerk des Nebenwohnsitzes:\n\n\
  wireguard-ui  →  http://${IP}:5000\n\
  ddns-go       →  http://${IP}:9876\n\
  Dashboard     →  http://${IP}:8080\n\n\
  ──────────────────────────────────────────────\n\
  Standard-Login wireguard-ui:\n\
    Benutzer:  admin  (oder .env: WGUI_USERNAME)\n\
    Passwort:  aus .env: WGUI_PASSWORD" \
        19 64
}

# ─── Untermenü: Diagnose & Tools ─────────────────────────────────────────────
menu_diag_wt() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN | Diagnose & Tools" \
            --menu "\nVerbindungstests und Diagnose-Werkzeuge:" \
            24 72 10 \
            "1" "  🔧  System-Autofix  (prüfen & automatisch beheben)" \
            "2" "  Alle Tests auf einmal" \
            "3" "  WireGuard Handshake prüfen" \
            "4" "  DNS-Auflösung testen  ($VPN_HOST)" \
            "5" "  IPv6-Adresse prüfen" \
            "6" "  Ping VPN-Peer  (aus wg0)" \
            "7" "  Ping Heimnetz-Gateway  ($HAUPT_GW)" \
            "8" "  tcpdump UDP 51820  (live, Ctrl+C zum Beenden)" \
            "9" "  Tools installieren  (tcpdump, dnsutils, nmap)" \
            "0" "  ← Zurück zum Hauptmenü" \
            3>&1 1>&2 2>&3) || return

        case "$CHOICE" in
            1)
                clear
                ipv6_autofix
                press_enter
                ;;
            2)
                clear
                echo -e "${BOLD}═══ Vollständiger Diagnose-Report ═══${NC}\n"
                if ! ip link show wg0 &>/dev/null; then
                    echo -e "  ${RED}✘  wg0-Interface nicht aktiv.${NC}"
                    echo -e "  ${DIM}→ Container starten: Menu 3 → Alle Container starten${NC}"
                else
                    wg show wg0 2>/dev/null
                    echo ""
                    local HS
                    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
                    if [[ -n "$HS" && "$HS" != "0" ]]; then
                        local AGO=$(( $(date +%s) - HS ))
                        echo -e "  ${GREEN}✔  Letzter Handshake vor ${AGO}s${NC}"
                        [[ $AGO -gt 180 ]] && echo -e "  ${YELLOW}⚠  Handshake älter als 3 Minuten — Verbindung möglicherweise unterbrochen${NC}"
                    else
                        echo -e "  ${RED}✘  Kein Handshake — Gegenstelle nicht verbunden${NC}"
                        echo -e "  ${DIM}→ Prüfe: Endpoint, Firewall, Port 51820${NC}"
                    fi
                fi
                press_enter
                ;;
            3)
                clear
                echo -e "${BOLD}DNS-Auflösung: ${VPN_HOST}${NC}\n"
                if ! command -v dig &>/dev/null; then
                    echo -e "  ${YELLOW}⚠  'dig' nicht installiert → Option 1 wählen${NC}"
                else
                    echo -e "  ${CYAN}A-Record (IPv4):${NC}"
                    dig "$VPN_HOST" A +short 2>/dev/null | sed 's/^/    /' || echo "    (kein Ergebnis)"
                    echo ""
                    echo -e "  ${CYAN}AAAA-Record (IPv6):${NC}"
                    dig "$VPN_HOST" AAAA +short 2>/dev/null | sed 's/^/    /' || echo "    (kein Ergebnis)"
                    echo ""
                    echo -e "  ${CYAN}Aktuelle IPv6 dieses Raspi:${NC}"
                    ip -6 addr show eth0 2>/dev/null | grep 'scope global' | awk '{print "    " $2}' || echo "    (nicht ermittelbar)"
                fi
                press_enter
                ;;
            4)
                clear
                local PEER_IP; PEER_IP=$(vpn_peer_ip)
                echo -e "${BOLD}Ping VPN-Peer (${PEER_IP:-kein Peer konfiguriert}):${NC}\n"
                if [[ -z "$PEER_IP" ]]; then
                    echo -e "  ${YELLOW}⚠  Kein Peer in wg0 gefunden — Container gestartet?${NC}"
                elif ip link show wg0 &>/dev/null; then
                    ping -c 4 -W 2 "$PEER_IP" 2>/dev/null \
                        && echo -e "\n  ${GREEN}✔  VPN-Peer erreichbar — Tunnel aktiv${NC}" \
                        || echo -e "\n  ${RED}✘  VPN-Peer nicht erreichbar — Tunnel unterbrochen?${NC}"
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv — kein Tunnel aufgebaut${NC}"
                fi
                press_enter
                ;;
            5)
                clear
                echo -e "${BOLD}Ping Heimnetz-Gateway (${HAUPT_GW}):${NC}\n"
                if ip link show wg0 &>/dev/null; then
                    ping -c 4 -W 2 "$HAUPT_GW" 2>/dev/null \
                        && echo -e "\n  ${GREEN}✔  Hauptwohnsitz-Gateway erreichbar${NC}" \
                        || echo -e "\n  ${RED}✘  Nicht erreichbar — Routing oder iptables-Regeln prüfen${NC}"
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv — kein Tunnel aufgebaut${NC}"
                fi
                press_enter
                ;;
            6)
                clear
                echo -e "${BOLD}IPv6-Adresse dieses Raspi:${NC}\n"
                ip -6 addr show eth0 2>/dev/null | grep -E 'scope (global|link)' | while read -r line; do
                    echo "  $line"
                done
                echo ""
                echo -e "  ${CYAN}Öffentliche IPv6 (extern):${NC}"
                curl -6 -s --max-time 5 ifconfig.co 2>/dev/null | sed 's/^/    /' \
                    || echo -e "    ${YELLOW}⚠  Kein IPv6-Internet erreichbar${NC}"
                echo ""
                echo -e "  ${CYAN}AAAA in DNS (${VPN_HOST}):${NC}"
                if command -v dig &>/dev/null; then
                    dig "$VPN_HOST" AAAA +short 2>/dev/null | sed 's/^/    /' || echo "    (nicht auflösbar)"
                else
                    echo -e "    ${DIM}dig nicht installiert → Option 1${NC}"
                fi
                press_enter
                ;;
            7)
                clear
                if ! command -v tcpdump &>/dev/null; then
                    echo -e "  ${YELLOW}⚠  tcpdump nicht installiert.${NC}"
                    echo -e "  ${DIM}→ Option 1 wählen um Tools zu installieren${NC}"
                else
                    echo -e "${BOLD}tcpdump — lausche auf UDP Port 51820 (eth0)${NC}"
                    echo -e "${DIM}Aktiviere jetzt WireGuard auf dem Gegenstück. Ctrl+C zum Beenden.${NC}\n"
                    tcpdump -i eth0 udp port 51820 -n 2>&1 || true
                fi
                press_enter
                ;;
            8)
                clear
                echo -e "${BOLD}═══ Vollständiger Diagnose-Report ═══${NC}\n"
                # 1. wg show
                echo -e "${CYAN}[1/4] WireGuard Status:${NC}"
                if ip link show wg0 &>/dev/null; then
                    wg show wg0 2>/dev/null
                    local HS
                    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
                    if [[ -n "$HS" && "$HS" != "0" ]]; then
                        local AGO=$(( $(date +%s) - HS ))
                        echo -e "  ${GREEN}✔  Handshake vor ${AGO}s${NC}"
                    else
                        echo -e "  ${RED}✘  Kein Handshake${NC}"
                    fi
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv${NC}"
                fi
                echo ""
                # 2. DNS
                echo -e "${CYAN}[2/4] DNS (${VPN_HOST}):${NC}"
                if command -v dig &>/dev/null; then
                    local A AAAA
                    A=$(dig "$VPN_HOST" A +short 2>/dev/null)
                    AAAA=$(dig "$VPN_HOST" AAAA +short 2>/dev/null)
                    [[ -n "$A" ]]    && echo -e "  A:    ${GREEN}$A${NC}"    || echo -e "  A:    ${YELLOW}(kein Eintrag)${NC}"
                    [[ -n "$AAAA" ]] && echo -e "  AAAA: ${GREEN}$AAAA${NC}" || echo -e "  AAAA: ${YELLOW}(kein Eintrag)${NC}"
                else
                    echo -e "  ${DIM}dig nicht installiert → Option 1${NC}"
                fi
                echo ""
                # 3. Ping-Tests
                echo -e "${CYAN}[3/4] Erreichbarkeit:${NC}"
                if ip link show wg0 &>/dev/null; then
                    local PEER_IP; PEER_IP=$(vpn_peer_ip)
                    if [[ -n "$PEER_IP" ]]; then
                        ping -c 2 -W 1 "$PEER_IP"   &>/dev/null && echo -e "  VPN-Peer ${PEER_IP}: ${GREEN}✔ erreichbar${NC}" || echo -e "  VPN-Peer ${PEER_IP}: ${RED}✘ nicht erreichbar${NC}"
                    else
                        echo -e "  ${DIM}Kein Peer konfiguriert${NC}"
                    fi
                    ping -c 2 -W 1 "$HAUPT_GW"  &>/dev/null && echo -e "  HW-GW ${HAUPT_GW}: ${GREEN}✔ erreichbar${NC}" || echo -e "  HW-GW ${HAUPT_GW}: ${RED}✘ nicht erreichbar${NC}"
                else
                    echo -e "  ${DIM}wg0 nicht aktiv — Pings übersprungen${NC}"
                fi
                echo ""
                # 4. IPv6
                echo -e "${CYAN}[4/4] IPv6:${NC}"
                local MY_IPV6
                MY_IPV6=$(curl -6 -s --max-time 5 ifconfig.co 2>/dev/null)
                [[ -n "$MY_IPV6" ]] && echo -e "  Öffentlich: ${GREEN}$MY_IPV6${NC}" || echo -e "  Öffentlich: ${RED}nicht erreichbar${NC}"
                echo ""
                echo -e "${BOLD}═══ Report Ende ═══${NC}"
                press_enter
                ;;
            3)
                clear
                echo -e "${BOLD}WireGuard Handshake-Status:${NC}\n"
                if ! ip link show wg0 &>/dev/null; then
                    echo -e "  ${RED}✘  wg0-Interface nicht aktiv.${NC}"
                    echo -e "  ${DIM}→ Container starten: Menu 3 → Alle Container starten${NC}"
                else
                    wg show wg0 2>/dev/null
                    echo ""
                    local HS
                    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
                    if [[ -n "$HS" && "$HS" != "0" ]]; then
                        local AGO=$(( $(date +%s) - HS ))
                        echo -e "  ${GREEN}✔  Letzter Handshake vor ${AGO}s${NC}"
                        [[ $AGO -gt 180 ]] && echo -e "  ${YELLOW}⚠  Handshake älter als 3 Minuten — Verbindung möglicherweise unterbrochen${NC}"
                    else
                        echo -e "  ${RED}✘  Kein Handshake — Gegenstelle nicht verbunden${NC}"
                        echo -e "  ${DIM}→ Prüfe: Endpoint, Firewall, Port 51820${NC}"
                    fi
                fi
                press_enter
                ;;
            4)
                clear
                echo -e "${BOLD}DNS-Auflösung: ${VPN_HOST}${NC}\n"
                if ! command -v dig &>/dev/null; then
                    echo -e "  ${YELLOW}⚠  'dig' nicht installiert → Option 9 wählen${NC}"
                else
                    echo -e "  ${CYAN}A-Record (IPv4):${NC}"
                    dig "$VPN_HOST" A +short 2>/dev/null | sed 's/^/    /' || echo "    (kein Ergebnis)"
                    echo ""
                    echo -e "  ${CYAN}AAAA-Record (IPv6):${NC}"
                    dig "$VPN_HOST" AAAA +short 2>/dev/null | sed 's/^/    /' || echo "    (kein Ergebnis)"
                    echo ""
                    echo -e "  ${CYAN}Aktuelle IPv6 dieses Raspi:${NC}"
                    ip -6 addr show eth0 2>/dev/null | grep 'scope global' | awk '{print "    " $2}' || echo "    (nicht ermittelbar)"
                fi
                press_enter
                ;;
            5)
                clear
                echo -e "${BOLD}IPv6-Adresse dieses Raspi:${NC}\n"
                ip -6 addr show eth0 2>/dev/null | grep -E 'scope (global|link)' | while read -r line; do
                    echo "  $line"
                done
                echo ""
                echo -e "  ${CYAN}Öffentliche IPv6 (extern):${NC}"
                curl -6 -s --max-time 5 ifconfig.co 2>/dev/null | sed 's/^/    /' \
                    || echo -e "    ${YELLOW}⚠  Kein IPv6-Internet erreichbar${NC}"
                echo ""
                echo -e "  ${CYAN}AAAA in DNS (${VPN_HOST}):${NC}"
                if command -v dig &>/dev/null; then
                    dig "$VPN_HOST" AAAA +short 2>/dev/null | sed 's/^/    /' || echo "    (nicht auflösbar)"
                else
                    echo -e "    ${DIM}dig nicht installiert → Option 9${NC}"
                fi
                press_enter
                ;;
            6)
                clear
                local PEER_IP; PEER_IP=$(vpn_peer_ip)
                echo -e "${BOLD}Ping VPN-Peer (${PEER_IP:-kein Peer konfiguriert}):${NC}\n"
                if [[ -z "$PEER_IP" ]]; then
                    echo -e "  ${YELLOW}⚠  Kein Peer in wg0 gefunden — Container gestartet?${NC}"
                elif ip link show wg0 &>/dev/null; then
                    ping -c 4 -W 2 "$PEER_IP" 2>/dev/null \
                        && echo -e "\n  ${GREEN}✔  VPN-Peer erreichbar — Tunnel aktiv${NC}" \
                        || echo -e "\n  ${RED}✘  VPN-Peer nicht erreichbar — Tunnel unterbrochen?${NC}"
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv — kein Tunnel aufgebaut${NC}"
                fi
                press_enter
                ;;
            7)
                clear
                echo -e "${BOLD}Ping Heimnetz-Gateway (${HAUPT_GW}):${NC}\n"
                if ip link show wg0 &>/dev/null; then
                    ping -c 4 -W 2 "$HAUPT_GW" 2>/dev/null \
                        && echo -e "\n  ${GREEN}✔  Hauptwohnsitz-Gateway erreichbar${NC}" \
                        || echo -e "\n  ${RED}✘  Nicht erreichbar — Routing oder iptables-Regeln prüfen${NC}"
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv — kein Tunnel aufgebaut${NC}"
                fi
                press_enter
                ;;
            8)
                clear
                if ! command -v tcpdump &>/dev/null; then
                    echo -e "  ${YELLOW}⚠  tcpdump nicht installiert.${NC}"
                    echo -e "  ${DIM}→ Option 9 wählen um Tools zu installieren${NC}"
                else
                    echo -e "${BOLD}tcpdump — lausche auf UDP Port 51820 (eth0)${NC}"
                    echo -e "${DIM}Aktiviere jetzt WireGuard auf dem Gegenstück. Ctrl+C zum Beenden.${NC}\n"
                    tcpdump -i eth0 udp port 51820 -n 2>&1 || true
                fi
                press_enter
                ;;
            9)
                clear
                echo -e "${BOLD}Tools installieren…${NC}\n"
                local TO_INSTALL=""
                command -v tcpdump &>/dev/null || TO_INSTALL="$TO_INSTALL tcpdump"
                command -v dig    &>/dev/null || TO_INSTALL="$TO_INSTALL dnsutils"
                command -v nmap   &>/dev/null || TO_INSTALL="$TO_INSTALL nmap"
                if [[ -z "$TO_INSTALL" ]]; then
                    echo -e "  ${GREEN}✔  Alle Tools bereits installiert:${NC}"
                    echo -e "     tcpdump $(tcpdump --version 2>&1 | head -1)"
                    echo -e "     dig     $(dig -v 2>&1 | head -1)"
                    echo -e "     nmap    $(nmap --version 2>&1 | head -1)"
                else
                    echo -e "  Installiere:${YELLOW}$TO_INSTALL${NC}\n"
                    apt-get install -y $TO_INSTALL \
                        && echo -e "\n  ${GREEN}✔  Installation erfolgreich${NC}" \
                        || echo -e "\n  ${RED}✘  Fehler bei der Installation${NC}"
                fi
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# =============================================================================
# TEXT-FALLBACK — einfaches Textmenü (ohne whiptail)
# =============================================================================

# IPv6-Autofix-Funktion (geteilt von whiptail + text)
ipv6_autofix() {
    local FIXES=0
    local ERRORS=0
    local TOTAL=11

    echo -e "${BOLD}═══ System-Autofix & Diagnose ═══${NC}\n"

    # ─ Schritt 1: eth0 Link-Status ──────────────────────────────────────────
    echo -e "${CYAN}[1/$TOTAL] Netzwerk-Interface (eth0):${NC}"
    if ! ip link show eth0 &>/dev/null; then
        echo -e "  ${RED}✘  eth0 existiert nicht — physisches Problem?${NC}"
        (( ERRORS++ ))
    else
        local ETH_STATE
        ETH_STATE=$(ip link show eth0 | grep -oP '(?<=state )\w+')
        if [[ "$ETH_STATE" == "UP" ]]; then
            echo -e "  ${GREEN}✔  UP${NC}"
        else
            echo -e "  ${YELLOW}⚠  eth0 ist $ETH_STATE — aktiviere…${NC}"
            ip link set eth0 up
            sleep 2
            ETH_STATE=$(ip link show eth0 | grep -oP '(?<=state )\w+')
            [[ "$ETH_STATE" == "UP" ]] \
                && echo -e "  ${GREEN}✔  Aktiviert${NC}" \
                || echo -e "  ${RED}✘  Konnte nicht aktiviert werden${NC}"
            (( FIXES++ ))
        fi
    fi
    echo ""

    # ─ Schritt 2: Docker-Daemon ──────────────────────────────────────────────
    echo -e "${CYAN}[2/$TOTAL] Docker-Daemon:${NC}"
    if ! systemctl is-active --quiet docker; then
        echo -e "  ${RED}✘  Docker läuft nicht — starte…${NC}"
        systemctl start docker &>/dev/null
        sleep 3
        if systemctl is-active --quiet docker; then
            echo -e "  ${GREEN}✔  Docker gestartet${NC}"
        else
            echo -e "  ${RED}✘  Docker konnte nicht gestartet werden — Container-Checks übersprungen${NC}"
            (( ERRORS++ ))
        fi
        (( FIXES++ ))
    else
        echo -e "  ${GREEN}✔  Läuft${NC}"
    fi
    echo ""

    # ─ Schritt 3: Zeit-Synchronisation (NTP) ────────────────────────────────
    echo -e "${CYAN}[3/$TOTAL] Zeit-Synchronisation (NTP):${NC}"
    local TIMESYNCED
    TIMESYNCED=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
    if [[ "$TIMESYNCED" == "yes" ]]; then
        echo -e "  ${GREEN}✔  NTP synchronisiert${NC}"
    elif [[ "$TIMESYNCED" == "unknown" ]]; then
        echo -e "  ${YELLOW}⚠  Nicht prüfbar (timedatectl fehlt?)${NC}"
    else
        echo -e "  ${YELLOW}⚠  NTP nicht sync — starte timesyncd neu…${NC}"
        systemctl restart systemd-timesyncd &>/dev/null
        sleep 5
        TIMESYNCED=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
        if [[ "$TIMESYNCED" == "yes" ]]; then
            echo -e "  ${GREEN}✔  NTP jetzt synchronisiert${NC}"
        else
            echo -e "  ${YELLOW}⚠  Noch nicht sync — WireGuard-Handshake scheitert bei Zeitdrift >5 Min!${NC}"
        fi
        (( FIXES++ ))
    fi
    echo ""

    # ─ Schritt 4: IP-Forwarding (IPv4 + IPv6) ───────────────────────────────
    echo -e "${CYAN}[4/$TOTAL] IP-Forwarding:${NC}"
    local IPV4_FWD IPV6_FWD FWD_FIXED=0
    IPV4_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    IPV6_FWD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "?")
    if [[ "$IPV4_FWD" != "1" ]]; then
        echo -e "  ${YELLOW}⚠  IPv4-Forwarding aus — aktiviere…${NC}"
        sysctl -w net.ipv4.ip_forward=1 &>/dev/null
        grep -q 'net.ipv4.ip_forward' /etc/sysctl.d/99-wg-forward.conf 2>/dev/null \
            || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-wg-forward.conf
        FWD_FIXED=1
    fi
    if [[ "$IPV6_FWD" != "1" ]]; then
        echo -e "  ${YELLOW}⚠  IPv6-Forwarding aus — aktiviere…${NC}"
        sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
        grep -q 'net.ipv6.conf.all.forwarding' /etc/sysctl.d/99-wg-forward.conf 2>/dev/null \
            || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-wg-forward.conf
        FWD_FIXED=1
    fi
    if [[ $FWD_FIXED -eq 1 ]]; then
        echo -e "  ${GREEN}✔  Forwarding aktiviert und dauerhaft gesichert${NC}"
        (( FIXES++ ))
    else
        echo -e "  ${GREEN}✔  IPv4: ein  |  IPv6: ein${NC}"
    fi
    echo ""

    # ─ Schritt 5: Privacy Extensions ────────────────────────────────────────
    echo -e "${CYAN}[5/$TOTAL] Privacy Extensions (eth0):${NC}"
    local TEMPADDR
    TEMPADDR=$(sysctl -n net.ipv6.conf.eth0.use_tempaddr 2>/dev/null || echo "?")
    if [[ "$TEMPADDR" == "0" ]]; then
        echo -e "  ${GREEN}✔  Deaktiviert — IPv6 bleibt stabil${NC}"
    elif [[ "$TEMPADDR" == "?" ]]; then
        echo -e "  ${YELLOW}⚠  Nicht prüfbar${NC}"
    else
        echo -e "  ${YELLOW}⚠  Privacy Extensions aktiv (use_tempaddr=$TEMPADDR) — deaktiviere dauerhaft…${NC}"
        echo 'net.ipv6.conf.eth0.use_tempaddr = 0' > /etc/sysctl.d/99-no-tempaddr.conf
        sysctl -w net.ipv6.conf.eth0.use_tempaddr=0 &>/dev/null
        echo -e "  ${GREEN}✔  Behoben${NC}"
        (( FIXES++ ))
    fi
    echo ""

    # ─ Schritt 6: Aktuelle IPv6-Adresse ─────────────────────────────────────
    echo -e "${CYAN}[6/$TOTAL] Aktuelle IPv6-Adresse:${NC}"
    local CURRENT_IPV6
    CURRENT_IPV6=$(ip -6 addr show eth0 2>/dev/null \
        | grep 'scope global' \
        | grep -v 'temporary' \
        | awk '{print $2}' | cut -d'/' -f1 | head -1)
    if [[ -z "$CURRENT_IPV6" ]]; then
        echo -e "  ${RED}✘  Keine globale IPv6 auf eth0!${NC}"
        echo -e "  ${DIM}→ IPv6 in Fritzbox aktiv? DHCP6 / RA aktiviert?${NC}"
        (( ERRORS++ ))
    else
        echo -e "  ${GREEN}✔  $CURRENT_IPV6${NC}"
    fi
    echo ""

    # ─ Schritt 7: DDNS-Record vs. aktuelle IPv6 ─────────────────────────────
    echo -e "${CYAN}[7/$TOTAL] DDNS-Abgleich ($VPN_HOST):${NC}"
    if ! command -v dig &>/dev/null; then
        echo -e "  ${YELLOW}⚠  'dig' nicht installiert — übersprungen${NC}"
        echo -e "  ${DIM}→ Option 1 im Diagnosemenü: Tools installieren${NC}"
    else
        local DNS_IPV6
        DNS_IPV6=$(dig "$VPN_HOST" AAAA +short 2>/dev/null | head -1)
        if [[ -z "$DNS_IPV6" ]]; then
            echo -e "  ${RED}✘  Kein AAAA-Record für $VPN_HOST!${NC}"
            echo -e "  ${DIM}→ ddns-go konfiguriert? http://$(raspi_ip):9876${NC}"
            (( ERRORS++ ))
        elif [[ "$DNS_IPV6" == "$CURRENT_IPV6" ]]; then
            echo -e "  ${GREEN}✔  DNS stimmt überein: $DNS_IPV6${NC}"
        else
            echo -e "  ${YELLOW}⚠  Abweichung!${NC}"
            echo -e "     DNS:   $DNS_IPV6"
            echo -e "     Raspi: $CURRENT_IPV6"
            echo -e "  ${CYAN}→ ddns-go wird neugestartet um Update zu erzwingen…${NC}"
            docker restart ddns-go &>/dev/null \
                && echo -e "  ${GREEN}✔  ddns-go neugestartet (Update läuft ~30s)${NC}" \
                || echo -e "  ${RED}✘  Neustart fehlgeschlagen${NC}"
            (( FIXES++ ))
        fi
    fi
    echo ""

    # ─ Schritt 8: wireguard-ui Container ────────────────────────────────────
    echo -e "${CYAN}[8/$TOTAL] wireguard-ui Container:${NC}"
    local WUI_RUNNING
    WUI_RUNNING=$(docker inspect -f '{{.State.Running}}' wireguard-ui 2>/dev/null || echo "false")
    if [[ "$WUI_RUNNING" == "true" ]]; then
        local WUI_RESTARTS
        WUI_RESTARTS=$(docker inspect -f '{{.RestartCount}}' wireguard-ui 2>/dev/null || echo "0")
        echo -e "  ${GREEN}✔  Läuft${NC}  ${DIM}(Restarts: $WUI_RESTARTS)${NC}"
        [[ "$WUI_RESTARTS" -gt 5 ]] && echo -e "  ${YELLOW}⚠  $WUI_RESTARTS Neustarts — Logs prüfen: docker logs wireguard-ui${NC}"
    else
        echo -e "  ${RED}✘  wireguard-ui gestoppt — starte…${NC}"
        docker compose -f "$COMPOSE_FILE" up -d wireguard-ui &>/dev/null \
            && echo -e "  ${GREEN}✔  Gestartet — wg0 braucht ~10s${NC}" \
            || { echo -e "  ${RED}✘  Fehler beim Starten${NC}"; (( ERRORS++ )); }
        (( FIXES++ ))
    fi
    echo ""

    # ─ Schritt 9: wg0 Interface & Handshake ─────────────────────────────────
    echo -e "${CYAN}[9/$TOTAL] WireGuard Interface (wg0):${NC}"
    if ip link show wg0 &>/dev/null; then
        local HS
        HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$HS" && "$HS" != "0" ]]; then
            local AGO=$(( $(date +%s) - HS ))
            if [[ $AGO -lt 300 ]]; then
                echo -e "  ${GREEN}✔  UP — Handshake vor ${AGO}s${NC}"
            else
                echo -e "  ${YELLOW}⚠  UP — letzter Handshake vor ${AGO}s (>5 Min)${NC}"
                echo -e "  ${DIM}→ OPNsense-Tunnel prüfen oder neu starten${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠  UP aber noch kein Handshake${NC}"
            echo -e "  ${DIM}→ Warte auf OPNsense, oder Tunnel auf OPNsense-Seite neu starten${NC}"
        fi
    else
        echo -e "  ${RED}✘  wg0 nicht aktiv — starte wireguard-ui neu…${NC}"
        docker restart wireguard-ui &>/dev/null \
            && echo -e "  ${GREEN}✔  wireguard-ui neugestartet — wg0 kommt gleich${NC}" \
            || echo -e "  ${RED}✘  Fehlgeschlagen${NC}"
        (( FIXES++ ))
    fi
    echo ""

    # ─ Schritt 10: ddns-go Container & API-Status ───────────────────────────
    echo -e "${CYAN}[10/$TOTAL] ddns-go Container:${NC}"
    local DDNS_RUNNING
    DDNS_RUNNING=$(docker inspect -f '{{.State.Running}}' ddns-go 2>/dev/null || echo "false")
    if [[ "$DDNS_RUNNING" == "true" ]]; then
        local LAST_LOG
        LAST_LOG=$(docker logs ddns-go --tail 5 2>&1 | tr '[:upper:]' '[:lower:]')
        local DDNS_RESTARTS
        DDNS_RESTARTS=$(docker inspect -f '{{.RestartCount}}' ddns-go 2>/dev/null || echo "0")
        if echo "$LAST_LOG" | grep -qE "401|403|unauthorized|forbidden"; then
            echo -e "  ${RED}✘  Cloudflare API-Fehler (Token ungültig / abgelaufen)!${NC}"
            echo -e "  ${DIM}→ Token in ddns-go WebUI erneuern: http://$(raspi_ip):9876${NC}"
            (( ERRORS++ ))
        elif echo "$LAST_LOG" | grep -qE "error|fail"; then
            echo -e "  ${YELLOW}⚠  Fehler in Logs — starte neu…${NC}"
            docker restart ddns-go &>/dev/null \
                && echo -e "  ${GREEN}✔  Neugestartet${NC}" \
                || echo -e "  ${RED}✘  Fehlgeschlagen${NC}"
            (( FIXES++ ))
        else
            echo -e "  ${GREEN}✔  Läuft ohne Fehler${NC}  ${DIM}(Restarts: $DDNS_RESTARTS)${NC}"
        fi
    else
        echo -e "  ${RED}✘  ddns-go gestoppt — starte…${NC}"
        docker compose -f "$COMPOSE_FILE" up -d ddns-go &>/dev/null \
            && echo -e "  ${GREEN}✔  Gestartet${NC}" \
            || { echo -e "  ${RED}✘  Fehler${NC}"; (( ERRORS++ )); }
        (( FIXES++ ))
    fi
    echo ""

    # ─ Schritt 11: Disk-Speicher ─────────────────────────────────────────────
    echo -e "${CYAN}[11/$TOTAL] Disk-Speicher:${NC}"
    local DISK_USE
    DISK_USE=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
    if [[ -z "$DISK_USE" ]]; then
        echo -e "  ${YELLOW}⚠  Nicht prüfbar${NC}"
    elif [[ "$DISK_USE" -ge 95 ]]; then
        echo -e "  ${RED}✘  Kritisch: ${DISK_USE}% belegt!${NC}"
        echo -e "  ${DIM}→ docker system prune -f  kann Platz freigeben${NC}"
        (( ERRORS++ ))
    elif [[ "$DISK_USE" -ge 85 ]]; then
        echo -e "  ${YELLOW}⚠  ${DISK_USE}% belegt — bald voll${NC}"
        echo -e "  ${DIM}→ docker system prune -f empfohlen${NC}"
    else
        echo -e "  ${GREEN}✔  ${DISK_USE}% belegt${NC}"
    fi
    echo ""

    # ─ Zusammenfassung ───────────────────────────────────────────────────────
    echo -e "${BOLD}═══ Ergebnis ═══${NC}"
    if [[ $ERRORS -eq 0 && $FIXES -eq 0 ]]; then
        echo -e "  ${GREEN}✔  Alles in Ordnung — keine Probleme gefunden${NC}"
    elif [[ $ERRORS -eq 0 ]]; then
        echo -e "  ${GREEN}✔  $FIXES Problem(e) automatisch behoben${NC}"
        echo -e "  ${DIM}→ Warte ~60s, dann OPNsense-Tunnel neu starten damit Handshake klappt${NC}"
    else
        echo -e "  ${YELLOW}⚠  $FIXES behoben — $ERRORS Fehler benötigen manuelle Prüfung (siehe oben)${NC}"
        [[ $FIXES -gt 0 ]] && echo -e "  ${DIM}→ Warte ~60s, dann OPNsense-Tunnel neu starten${NC}"
    fi
}

divider_text() { echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"; }

banner_text() {
    clear
    blank
    echo -e "${BOLD}\033[0;36m"
    echo "  ██████╗ ██╗      ██╗   ██╗██████╗ ███╗   ██╗"
    echo "  ██╔══██╗██║      ██║   ██║██╔══██╗████╗  ██║"
    echo "  ██████╔╝██║█████╗██║   ██║██████╔╝██╔██╗ ██║"
    echo "  ██╔═══╝ ██║╚════╝╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║"
    echo "  ██║     ██║       ╚████╔╝ ██║     ██║ ╚████║"
    echo "  ╚═╝     ╚═╝        ╚═══╝  ╚═╝     ╚═╝  ╚═══╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}Site-to-Site WireGuard — Zentrales Menü${NC}"
    echo -e "  ${DIM}$(vpn_status)  |  $(container_status)  |  $(ddns_status)  |  $(hostname)${NC}"
    blank
    echo -e "  ${DIM}© 2026 Bocki — MIT License — github.com/ReXx09/PI-VPN${NC}"
    divider_text
}

main_menu_text() {
    while true; do
        banner_text
        blank
        echo -e "  ${BOLD}[1]${NC}  🔧  Setup & Installation"
        echo -e "  ${BOLD}[2]${NC}  📊  Status & Monitoring"
        echo -e "  ${BOLD}[3]${NC}  🐳  Container-Verwaltung"
        echo -e "  ${BOLD}[4]${NC}  ⚙️  Konfiguration & Updates"
        echo -e "  ${BOLD}[5]${NC}  🔄  Reset & Deinstallation"
        echo -e "  ${BOLD}[6]${NC}  🌐  WebUI-Adressen anzeigen"
        echo -e "  ${BOLD}[7]${NC}  🔬  Diagnose & Tools"
        echo -e "  ${BOLD}[8]${NC}  💾  Backup & Wiederherstellen"
        blank
        divider_text
        echo -e "  ${BOLD}[0]${NC}  Beenden"
        blank
        echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r CHOICE
        case "$CHOICE" in
            1) text_setup ;;
            2) text_status ;;
            3) text_container ;;
            4) text_config ;;
            5) text_reset ;;
            6)
                blank
                echo -e "  ${BOLD}wireguard-ui:${NC}  http://$(raspi_ip):5000"
                echo -e "  ${BOLD}ddns-go:${NC}       http://$(raspi_ip):9876"
                echo -e "  ${BOLD}Dashboard:${NC}     http://$(raspi_ip):8080"
                press_enter
                ;;
            7) text_diag ;;
            8) text_backup ;;
            0|q|Q|exit|quit) break ;;
            *) echo -e "  ${RED}Ungültige Auswahl.${NC}"; sleep 1 ;;
        esac
    done
}

# ─── Untermenü: Backup & Wiederherstellen (whiptail) ─────────────────────────
menu_backup_wt() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail \
            --title "PI-VPN | Backup & Wiederherstellen" \
            --menu "\nWas möchtest du tun?" \
            16 68 3 \
            "1" "  Backup erstellen        (backup.sh)" \
            "2" "  Backup wiederherstellen (restore.sh)" \
            "0" "  ← Zurück zum Hauptmenü" \
            3>&1 1>&2 2>&3) || return

        case "$CHOICE" in
            1) clear; bash "$MANAGE_DIR/backup.sh"; press_enter ;;
            2) clear; bash "$MANAGE_DIR/restore.sh"; press_enter ;;
            0|"") return ;;
        esac
    done
}

# ─── Untermenü: Backup & Wiederherstellen (Text-Fallback) ────────────────────
text_backup() {
    while true; do
        clear; blank
        echo -e "  ${BOLD}[BACKUP] Backup & Wiederherstellen${NC}"; blank
        echo -e "  ${BOLD}[1]${NC}  Backup erstellen        (backup.sh)"
        echo -e "  ${BOLD}[2]${NC}  Backup wiederherstellen (restore.sh)"
        blank; echo -e "  ${BOLD}[0]${NC}  ← Zurück"
        blank; echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r C
        case "$C" in
            1) clear; bash "$MANAGE_DIR/backup.sh"; press_enter ;;
            2) clear; bash "$MANAGE_DIR/restore.sh"; press_enter ;;
            0|"") return ;;
        esac
    done
}

text_setup() {
    while true; do
        clear; blank
        echo -e "  ${BOLD}[SETUP] Setup & Installation${NC}"; blank
        echo -e "  ${BOLD}[1]${NC}  Vollständige Installation       (setup-wizard.sh)"
        echo -e "  ${BOLD}[2]${NC}  Dashboard nachinstallieren  (install-dashboard.sh)"
        echo -e "  ${BOLD}[3]${NC}  Nur Docker CE installieren     (install-docker.sh)"
        echo -e "  ${BOLD}[4]${NC}  Verzeichnisse anlegen                    (init.sh)"
        blank; echo -e "  ${BOLD}[0]${NC}  ← Zurück"
        blank; echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r C
        case "$C" in
            1) clear; bash "$SETUP_DIR/setup-wizard.sh"; press_enter ;;
            2) clear; bash "$SETUP_DIR/install-dashboard.sh"; press_enter ;;
            3) clear; bash "$SETUP_DIR/install-docker.sh"; press_enter ;;
            4) clear; bash "$SETUP_DIR/init.sh"; press_enter ;;
            0|"") return ;;
        esac
    done
}

text_status() {
    while true; do
        clear; blank
        echo -e "  ${BOLD}[STATUS] Status & Monitoring${NC}"; blank
        echo -e "  ${BOLD}[1]${NC}  Vollständiger VPN-Status (status.sh)"
        echo -e "  ${BOLD}[2]${NC}  wireguard-ui Logs"
        echo -e "  ${BOLD}[3]${NC}  ddns-go Logs"
        echo -e "  ${BOLD}[4]${NC}  WireGuard Interface (wg show)"
        echo -e "  ${BOLD}[5]${NC}  Container-Übersicht (docker ps)"
        echo -e "  ${BOLD}[6]${NC}  IP-Routing-Tabelle"
        blank; echo -e "  ${BOLD}[0]${NC}  ← Zurück"
        blank; echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r C
        case "$C" in
            1) clear; bash "$MANAGE_DIR/status.sh"; press_enter ;;
            2) clear; docker logs wireguard-ui --tail 60 2>&1; press_enter ;;
            3) clear; docker logs ddns-go --tail 60 2>&1; press_enter ;;
            4) clear; wg show 2>/dev/null || echo "wg0 nicht aktiv."; press_enter ;;
            5) clear; docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; press_enter ;;
            6) clear; ip route show; blank; ip -6 route show; press_enter ;;
            0|"") return ;;
        esac
    done
}

text_container() {
    while true; do
        clear; blank
        echo -e "  ${BOLD}[CONTAINER] VPN-Dienste verwalten${NC}"
        echo -e "  ${DIM}wireguard-ui: $(docker inspect -f '{{.State.Status}}' wireguard-ui 2>/dev/null || echo 'n/a')  |  ddns-go: $(docker inspect -f '{{.State.Status}}' ddns-go 2>/dev/null || echo 'n/a')${NC}"; blank
        echo -e "  ${BOLD}[1]${NC}  Alle Container starten"
        echo -e "  ${BOLD}[2]${NC}  Alle Container stoppen"
        echo -e "  ${BOLD}[3]${NC}  Alle Container neu starten"
        echo -e "  ${BOLD}[4]${NC}  wireguard-ui neu starten"
        echo -e "  ${BOLD}[5]${NC}  ddns-go neu starten"
        echo -e "  ${BOLD}[6]${NC}  Live-Logs (Ctrl+C zum Beenden)"
        blank; echo -e "  ${BOLD}[0]${NC}  ← Zurück"
        blank; echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r C
        case "$C" in
            1) clear; docker compose -f "$COMPOSE_FILE" up -d; press_enter ;;
            2)
                echo -ne "  ${YELLOW}Wirklich stoppen? [j/N]${NC} "; read -r YN
                [[ "$YN" =~ ^[jJyY] ]] && { clear; docker compose -f "$COMPOSE_FILE" stop; press_enter; }
                ;;
            3) clear; docker compose -f "$COMPOSE_FILE" restart; press_enter ;;
            4) clear; docker restart wireguard-ui; press_enter ;;
            5) clear; docker restart ddns-go; press_enter ;;
            6) clear; docker compose -f "$COMPOSE_FILE" logs -f --tail 20 2>&1 || true; press_enter ;;
            0|"") return ;;
        esac
    done
}

text_config() {
    while true; do
        clear; blank
        echo -e "  ${BOLD}[CONFIG] Konfiguration & Updates${NC}"; blank
        echo -e "  ${BOLD}[1]${NC}  .env-Datei bearbeiten (nano)"
        echo -e "  ${BOLD}[2]${NC}  docker-compose.yml anzeigen"
        echo -e "  ${BOLD}[3]${NC}  Updates holen (git pull)"
        echo -e "  ${BOLD}[4]${NC}  wg0.conf anzeigen"
        echo -e "  ${BOLD}[5]${NC}  Systeminformationen"
        blank; echo -e "  ${BOLD}[0]${NC}  ← Zurück"
        blank; echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r C
        case "$C" in
            1)
                if [[ -f "$ENV_FILE" ]]; then
                    nano "$ENV_FILE"
                else
                    echo -e "\n  ${RED}✘${NC}  .env nicht gefunden — zuerst Wizard ausführen."
                    press_enter
                fi
                ;;
            2) clear; cat "$COMPOSE_FILE" 2>/dev/null; press_enter ;;
            3) clear; cd "$SCRIPT_DIR" && git pull; press_enter ;;
            4)
                clear
                local WG_CONF="$DOCKER_DIR/data/wireguard/wg0.conf"
                [[ -f "$WG_CONF" ]] && cat "$WG_CONF" || echo "wg0.conf nicht gefunden: $WG_CONF"
                press_enter
                ;;
            5)
                clear; blank
                echo -e "  ${CYAN}Hostname:${NC}  $(hostname)"
                echo -e "  ${CYAN}IP:${NC}        $(raspi_ip)"
                echo -e "  ${CYAN}OS:${NC}        $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
                echo -e "  ${CYAN}Kernel:${NC}    $(uname -r)"
                echo -e "  ${CYAN}Uptime:${NC}    $(uptime -p 2>/dev/null || uptime)"
                free -h | grep Mem | awk '{printf "  \033[0;36mSpeicher:\033[0m  %s gesamt  %s frei\n", $2, $4}'
                df -h / | tail -1 | awk '{printf "  \033[0;36mDisk /:\033[0m    %s gesamt  %s frei (%s)\n", $2, $4, $5}'
                echo -e "  ${CYAN}Docker:${NC}    $(docker --version 2>/dev/null || echo 'nicht inst.')"
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

text_diag() {
    while true; do
        clear; blank
        echo -e "  ${BOLD}[DIAGNOSE] Diagnose & Tools${NC}"; blank
        echo -e "  ${BOLD}[1]${NC}  🔧  System-Autofix  (prüfen & automatisch beheben)"
        echo -e "  ${BOLD}[2]${NC}  Alle Tests auf einmal"
        echo -e "  ${BOLD}[3]${NC}  WireGuard Handshake prüfen"
        echo -e "  ${BOLD}[4]${NC}  DNS-Auflösung testen  ($VPN_HOST)"
        echo -e "  ${BOLD}[5]${NC}  IPv6-Adresse prüfen"
        echo -e "  ${BOLD}[6]${NC}  Ping VPN-Peer  (aus wg0)"
        echo -e "  ${BOLD}[7]${NC}  Ping Heimnetz-Gateway  ($HAUPT_GW)"
        echo -e "  ${BOLD}[8]${NC}  tcpdump UDP 51820  (live, Ctrl+C)"
        echo -e "  ${BOLD}[9]${NC}  Tools installieren  (tcpdump, dnsutils, nmap)"
        blank; echo -e "  ${BOLD}[0]${NC}  ← Zurück"
        blank; echo -ne "  ${CYAN}▶${NC} Auswahl: "
        read -r C
        case "$C" in
            1)
                clear
                ipv6_autofix
                press_enter
                ;;
            2)
                clear
                echo -e "${BOLD}═══ Vollständiger Diagnose-Report ═══${NC}\n"
                echo -e "${CYAN}[1/4] WireGuard:${NC}"
                if ip link show wg0 &>/dev/null; then
                    wg show wg0 2>/dev/null
                    local HS; HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
                    [[ -n "$HS" && "$HS" != "0" ]] \
                        && echo -e "  ${GREEN}✔  Handshake vor $(( $(date +%s) - HS ))s${NC}" \
                        || echo -e "  ${RED}✘  Kein Handshake${NC}"
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv${NC}"
                fi
                echo -e "\n${CYAN}[2/4] DNS:${NC}"
                if command -v dig &>/dev/null; then
                    local A AAAA
                    A=$(dig "$VPN_HOST" A +short 2>/dev/null)
                    AAAA=$(dig "$VPN_HOST" AAAA +short 2>/dev/null)
                    [[ -n "$A" ]]    && echo -e "  A:    ${GREEN}$A${NC}"    || echo -e "  A:    ${YELLOW}(kein Eintrag)${NC}"
                    [[ -n "$AAAA" ]] && echo -e "  AAAA: ${GREEN}$AAAA${NC}" || echo -e "  AAAA: ${YELLOW}(kein Eintrag)${NC}"
                else
                    echo -e "  ${DIM}dig nicht installiert → Option 9${NC}"
                fi
                echo -e "\n${CYAN}[3/4] Erreichbarkeit:${NC}"
                if ip link show wg0 &>/dev/null; then
                    local PEER_IP; PEER_IP=$(vpn_peer_ip)
                    if [[ -n "$PEER_IP" ]]; then
                        ping -c 2 -W 1 "$PEER_IP"   &>/dev/null && echo -e "  VPN-Peer ${PEER_IP}: ${GREEN}✔${NC}" || echo -e "  VPN-Peer ${PEER_IP}: ${RED}✘${NC}"
                    else
                        echo -e "  ${DIM}Kein Peer konfiguriert${NC}"
                    fi
                    ping -c 2 -W 1 "$HAUPT_GW"  &>/dev/null && echo -e "  ${HAUPT_GW}: ${GREEN}✔${NC}" || echo -e "  ${HAUPT_GW}: ${RED}✘${NC}"
                else
                    echo -e "  ${DIM}wg0 nicht aktiv — übersprungen${NC}"
                fi
                echo -e "\n${CYAN}[4/4] IPv6:${NC}"
                local MY_IPV6; MY_IPV6=$(curl -6 -s --max-time 5 ifconfig.co 2>/dev/null)
                [[ -n "$MY_IPV6" ]] && echo -e "  ${GREEN}$MY_IPV6${NC}" || echo -e "  ${RED}nicht erreichbar${NC}"
                echo -e "\n${BOLD}═══ Report Ende ═══${NC}"
                press_enter
                ;;
            3)
                clear
                echo -e "${BOLD}WireGuard Handshake:${NC}\n"
                if ip link show wg0 &>/dev/null; then
                    wg show wg0 2>/dev/null
                    local HS
                    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
                    if [[ -n "$HS" && "$HS" != "0" ]]; then
                        local AGO=$(( $(date +%s) - HS ))
                        echo -e "\n  ${GREEN}✔  Handshake vor ${AGO}s${NC}"
                    else
                        echo -e "\n  ${RED}✘  Kein Handshake${NC}"
                    fi
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv${NC}"
                fi
                press_enter
                ;;
            4)
                clear
                echo -e "${BOLD}DNS: ${VPN_HOST}${NC}\n"
                if command -v dig &>/dev/null; then
                    echo -e "  ${CYAN}A-Record:${NC}";    dig "$VPN_HOST" A    +short 2>/dev/null | sed 's/^/    /'
                    echo -e "  ${CYAN}AAAA-Record:${NC}"; dig "$VPN_HOST" AAAA +short 2>/dev/null | sed 's/^/    /'
                    echo -e "  ${CYAN}Raspi IPv6:${NC}";  ip -6 addr show eth0 2>/dev/null | grep 'scope global' | awk '{print "    " $2}'
                else
                    echo -e "  ${YELLOW}⚠  dig nicht installiert → Option 9${NC}"
                fi
                press_enter
                ;;
            5)
                clear
                echo -e "${BOLD}IPv6-Adresse:${NC}\n"
                ip -6 addr show eth0 2>/dev/null | grep -E 'scope (global|link)' | sed 's/^/  /'
                echo -e "\n  ${CYAN}Öffentliche IPv6:${NC}"
                curl -6 -s --max-time 5 ifconfig.co 2>/dev/null | sed 's/^/    /' || echo -e "    ${YELLOW}nicht erreichbar${NC}"
                press_enter
                ;;
            6)
                clear
                local PEER_IP; PEER_IP=$(vpn_peer_ip)
                echo -e "${BOLD}Ping VPN-Peer (${PEER_IP:-kein Peer konfiguriert}):${NC}\n"
                if [[ -z "$PEER_IP" ]]; then
                    echo -e "  ${YELLOW}⚠  Kein Peer in wg0 gefunden — Container gestartet?${NC}"
                elif ip link show wg0 &>/dev/null; then
                    ping -c 4 -W 2 "$PEER_IP" 2>/dev/null \
                        && echo -e "\n  ${GREEN}✔  Erreichbar${NC}" \
                        || echo -e "\n  ${RED}✘  Nicht erreichbar${NC}"
                else
                    echo -e "  ${RED}✘  wg0 nicht aktiv${NC}"
                fi
                press_enter
                ;;
            7)
                clear
                echo -e "${BOLD}Ping ${HAUPT_GW} (Hauptwohnsitz):${NC}\n"
                ip link show wg0 &>/dev/null \
                    && { ping -c 4 -W 2 "$HAUPT_GW" 2>/dev/null \
                        && echo -e "\n  ${GREEN}✔  Erreichbar${NC}" \
                        || echo -e "\n  ${RED}✘  Nicht erreichbar — iptables prüfen${NC}"; } \
                    || echo -e "  ${RED}✘  wg0 nicht aktiv${NC}"
                press_enter
                ;;
            8)
                clear
                if command -v tcpdump &>/dev/null; then
                    echo -e "${BOLD}tcpdump UDP 51820 (Ctrl+C zum Beenden):${NC}\n"
                    tcpdump -i eth0 udp port 51820 -n 2>&1 || true
                else
                    echo -e "  ${YELLOW}⚠  tcpdump nicht installiert → Option 9${NC}"
                fi
                press_enter
                ;;
            9)
                clear
                echo -e "${BOLD}Tools installieren…${NC}\n"
                local TO_INSTALL=""
                command -v tcpdump &>/dev/null || TO_INSTALL="$TO_INSTALL tcpdump"
                command -v dig    &>/dev/null || TO_INSTALL="$TO_INSTALL dnsutils"
                command -v nmap   &>/dev/null || TO_INSTALL="$TO_INSTALL nmap"
                if [[ -z "$TO_INSTALL" ]]; then
                    echo -e "  ${GREEN}✔  Alle Tools bereits installiert${NC}"
                else
                    apt-get install -y $TO_INSTALL \
                        && echo -e "\n  ${GREEN}✔  Installation erfolgreich${NC}" \
                        || echo -e "\n  ${RED}✘  Fehler${NC}"
                fi
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

text_reset() {
    clear; blank
    echo -e "  ${YELLOW}⚠  Reset & Deinstallation${NC}"; blank
    echo -e "  Das Reset-Skript führt interaktiv durch alle 8 Schritte:"
    echo -e "  Tunnel trennen → Container → Volumes → Images → .env → Forwarding"
    echo -e "  → Docker deinstallieren → Projektverzeichnis löschen"
    blank
    echo -ne "  ${BOLD}Wirklich fortfahren?${NC} ${DIM}[j/N]${NC} "
    read -r YN
    if [[ "$YN" =~ ^[jJyY] ]]; then
        clear
        bash "$MANAGE_DIR/reset.sh"
        press_enter
    fi
}

# =============================================================================
# EINSTIEGSPUNKT
# =============================================================================
if $HAS_WHIPTAIL; then
    main_menu_whiptail
else
    main_menu_text
fi

clear
echo ""
echo -e "  ${DIM}PI-VPN beendet. Auf Wiedersehen!${NC}"
echo -e "  ${DIM}© 2026 Bocki — MIT License — https://github.com/ReXx09/PI-VPN${NC}"
echo ""
