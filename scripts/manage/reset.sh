#!/usr/bin/env bash
# =============================================================================
# PI-VPN Reset / Deinstallation
# Setzt den Raspberry Pi (Nebenwohnsitz) vollständig zurück
#
# Ausführen als: sudo bash scripts/manage/reset.sh
#
# Was dieses Skript erledigt — interaktiv wählbar:
#   1.  WireGuard-Tunnel (wg0) sofort trennen
#   2.  Docker-Container stoppen und entfernen (wireguard-ui, ddns-go)
#   3.  Docker-Volumes löschen (WireGuard-Keys, Peers, wireguard-ui DB)
#   4.  Docker-Images entfernen (Release neue Downloads beim nächsten Start)
#   5.  .env-Datei löschen (Passwörter / Secrets)
#   6.  Docker CE vollständig deinstallieren (optional)
#   7.  Projekt-Verzeichnis /opt/pi-vpn löschen (optional)
#   8.  IP-Forwarding rückgängig machen (sysctl)
#
# Nach dem Reset kann der Setup-Wizard neu gestartet werden:
#   sudo bash scripts/setup/setup-wizard.sh
# =============================================================================

set -uo pipefail

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
skip()    { echo -e "  ${DIM}–  $* (übersprungen)${NC}"; }
divider() { echo -e "${DIM}────────────────────────────────────────────────────────${NC}"; }
blank()   { echo ""; }

ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local answer
    blank
    echo -ne "  ${BOLD}${prompt}${NC} ${DIM}[j/n, Vorgabe: ${default}]${NC} ${CYAN}▶${NC} "
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[jJyY] ]]
}

# ─── Root-Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Bitte als root ausführen: sudo bash $0"
[[ "$(uname -s)" == "Linux" ]] || error "Dieses Skript ist nur für Linux (Raspberry Pi OS)."

# ─── Pfade ermitteln ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker/nebenwohnsitz"
ENV_FILE="$DOCKER_DIR/.env"

# ═════════════════════════════════════════════════════════════════════════════
# BANNER
# ═════════════════════════════════════════════════════════════════════════════
clear
blank
echo -e "${BOLD}${RED}"
echo "  ██████╗ ███████╗███████╗███████╗████████╗"
echo "  ██╔══██╗██╔════╝██╔════╝██╔════╝╚══██╔══╝"
echo "  ██████╔╝█████╗  ███████╗█████╗     ██║   "
echo "  ██╔══██╗██╔══╝  ╚════██║██╔══╝     ██║   "
echo "  ██║  ██║███████╗███████║███████╗   ██║   "
echo "  ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝   ╚═╝   "
echo -e "${NC}"
echo -e "  ${BOLD}PI-VPN Reset / Deinstallation${NC}"
echo -e "  ${DIM}Raspberry Pi — Nebenwohnsitz${NC}"
blank
divider
blank
echo -e "  Dieses Skript entfernt alle oder ausgewählte Komponenten"
echo -e "  des PI-VPN-Stacks, damit du sauber neu starten kannst."
blank
echo -e "  ${YELLOW}Achtung:${NC} Laufende VPN-Verbindungen werden unterbrochen."
blank
divider

# ─── Keine --force-Option, sicherheitshalber immer fragen ────────────────────
if ! ask_yn "Wirklich fortfahren und den Reset starten?" "n"; then
    blank
    echo -e "  Abgebrochen. Keine Änderungen vorgenommen."
    blank
    exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 1 — WireGuard-Tunnel trennen
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 1: WireGuard-Tunnel trennen${NC}"
divider

if ip link show wg0 &>/dev/null; then
    info "wg0-Interface gefunden, trenne Tunnel …"
    wg-quick down wg0 2>/dev/null || ip link delete wg0 2>/dev/null || true
    ok "wg0 wurde getrennt und entfernt"
else
    skip "Kein aktives wg0-Interface vorhanden"
fi

# wireguard-ui selbst könnte wg0 beim Stopp noch mal hochziehen → Container
# werden daher im nächsten Schritt gestoppt, bevor wg0 ein zweites Mal auftaucht.

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 2 — Docker-Container stoppen und entfernen
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 2: Docker-Container stoppen und entfernen${NC}"
divider

if command -v docker &>/dev/null; then
    if ask_yn "Container stoppen und entfernen (wireguard-ui, ddns-go)?" "j"; then

        if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
            info "Fahre Docker Compose Stack herunter …"
            docker compose -f "$DOCKER_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null || true
            ok "docker compose down abgeschlossen"
        fi

        # Sicherheitsnetz: einzelne Container direkt entfernen falls noch da
        for CONTAINER in wireguard-ui ddns-go; do
            if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
                docker rm -f "$CONTAINER" 2>/dev/null || true
                ok "Container '${CONTAINER}' entfernt"
            fi
        done

        # wg0 nach Container-Stop erneut prüfen (wireguard-ui hinterlässt es manchmal)
        sleep 1
        if ip link show wg0 &>/dev/null; then
            ip link delete wg0 2>/dev/null || true
            ok "wg0 nach Container-Stop nochmals entfernt"
        fi
    else
        skip "Container bleiben bestehen"
    fi
else
    skip "Docker ist nicht installiert"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 3 — Docker-Volumes löschen
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 3: Docker-Volumes löschen${NC}"
divider
echo -e "  ${DIM}Volumes enthalten: WireGuard-Keys, Peer-Konfigurationen,"
echo -e "  wireguard-ui-Datenbank, ddns-go-Einstellungen${NC}"

if command -v docker &>/dev/null; then
    if ask_yn "Docker-Volumes für wireguard-ui und ddns-go löschen?" "j"; then

        # Compose-Volumes
        if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
            docker compose -f "$DOCKER_DIR/docker-compose.yml" down -v 2>/dev/null || true
        fi

        # Benannte Volumes direkt suchen und löschen
        for VOL_PATTERN in wireguard wgui ddns-go ddnsgo nebenwohnsitz; do
            while IFS= read -r vol; do
                [[ -z "$vol" ]] && continue
                docker volume rm "$vol" 2>/dev/null && ok "Volume '${vol}' gelöscht" || true
            done < <(docker volume ls --format '{{.Name}}' | grep -i "$VOL_PATTERN" 2>/dev/null)
        done

        ok "Volumes-Bereinigung abgeschlossen"
    else
        skip "Volumes werden behalten"
    fi
else
    skip "Docker ist nicht installiert"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 4 — Docker-Images entfernen
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 4: Docker-Images entfernen${NC}"
divider
echo -e "  ${DIM}Images: ngoduykhanh/wireguard-ui, jeessy/ddns-go${NC}"

if command -v docker &>/dev/null; then
    if ask_yn "Docker-Images löschen (werden beim nächsten Start neu geladen)?" "n"; then
        for IMAGE in "ngoduykhanh/wireguard-ui" "jeessy/ddns-go"; do
            if docker image inspect "$IMAGE" &>/dev/null; then
                docker rmi "$IMAGE" 2>/dev/null && ok "Image '${IMAGE}' gelöscht" || warn "Image '${IMAGE}' konnte nicht gelöscht werden"
            else
                skip "Image '${IMAGE}' nicht vorhanden"
            fi
        done
    else
        skip "Images bleiben erhalten (kein erneuter Download nötig)"
    fi
else
    skip "Docker ist nicht installiert"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 5 — .env-Datei löschen
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 5: .env-Datei löschen${NC}"
divider
echo -e "  ${DIM}Enthält: Passwörter, SESSION_SECRET und alle Konfigurationswerte${NC}"

if [[ -f "$ENV_FILE" ]]; then
    if ask_yn ".env-Datei löschen? (Passwörter und Secrets werden entfernt)" "j"; then
        rm -f "$ENV_FILE"
        ok ".env gelöscht"
    else
        skip ".env bleibt erhalten"
    fi
else
    skip ".env-Datei nicht gefunden (bereits gelöscht oder noch nicht erstellt)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 6 — IP-Forwarding zurücksetzen
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 6: IP-Forwarding zurücksetzen${NC}"
divider

if ask_yn "IP-Forwarding deaktivieren? (sysctl + /etc/sysctl.d/99-wg.conf entfernen)" "n"; then
    # Sofort deaktivieren
    sysctl -w net.ipv4.ip_forward=0 &>/dev/null || true
    sysctl -w net.ipv6.conf.all.forwarding=0 &>/dev/null || true

    # Drop-in-Datei des Wizards entfernen
    if [[ -f /etc/sysctl.d/99-wg.conf ]]; then
        rm -f /etc/sysctl.d/99-wg.conf
        ok "sysctl-Drop-in /etc/sysctl.d/99-wg.conf entfernt"
    fi

    # Aus /etc/sysctl.conf entfernen, falls dort eingetragen
    if grep -q "ip_forward\|ipv6.*forwarding" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/net\.ipv4\.ip_forward/d' /etc/sysctl.conf
        sed -i '/net\.ipv6\.conf\.all\.forwarding/d' /etc/sysctl.conf
        ok "Forwarding-Einträge aus /etc/sysctl.conf entfernt"
    fi

    ok "IP-Forwarding deaktiviert"
else
    skip "IP-Forwarding bleibt aktiv"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 7 — Docker CE vollständig deinstallieren (optional)
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 7: Docker CE deinstallieren (optional)${NC}"
divider
echo -e "  ${YELLOW}Achtung:${NC} Entfernt Docker CE, Compose und alle verbleibenden"
echo -e "  Container, Images und Volumes auf diesem System."

if command -v docker &>/dev/null; then
    if ask_yn "Docker CE komplett deinstallieren?" "n"; then
        info "Stoppe alle laufenden Container …"
        docker stop $(docker ps -q) 2>/dev/null || true

        info "Deinstalliere Docker-Pakete …"
        apt-get purge -y \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin \
            docker-ce-rootless-extras 2>/dev/null || true

        apt-get autoremove -y 2>/dev/null || true

        # Docker-Daten entfernen
        if ask_yn "Auch /var/lib/docker und /etc/docker löschen? (alle Docker-Daten)" "n"; then
            rm -rf /var/lib/docker /etc/docker /var/run/docker.sock
            ok "/var/lib/docker und /etc/docker gelöscht"
        fi

        ok "Docker CE deinstalliert"
    else
        skip "Docker CE bleibt installiert"
    fi
else
    skip "Docker CE ist nicht installiert"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCHRITT 8 — Projekt-Verzeichnis /opt/pi-vpn löschen (optional)
# ═════════════════════════════════════════════════════════════════════════════
blank
echo -e "${BOLD}${BLUE}┌─── Schritt 8: Projekt-Verzeichnis löschen (optional)${NC}"
divider

INSTALL_DIR="/opt/pi-vpn"

if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "  Gefunden: ${BOLD}${INSTALL_DIR}${NC}"
    echo -e "  ${YELLOW}Achtung:${NC} Enthält alle Skripte, Konfigurationen und ggf. Backups."
    echo -e "  Nach dem Löschen ist ein erneuter ${BOLD}git clone${NC} nötig."

    if ask_yn "Verzeichnis ${INSTALL_DIR} löschen?" "n"; then
        # Backup-Verzeichnis separat anbieten
        if [[ -d "$INSTALL_DIR/backups" ]]; then
            if ask_yn "Auch Backups in ${INSTALL_DIR}/backups löschen?" "n"; then
                rm -rf "$INSTALL_DIR"
                ok "${INSTALL_DIR} inkl. Backups gelöscht"
            else
                cp -r "$INSTALL_DIR/backups" /tmp/pi-vpn-backups-$(date +%Y%m%d_%H%M%S)
                ok "Backups gesichert nach /tmp/pi-vpn-backups-*"
                rm -rf "$INSTALL_DIR"
                ok "${INSTALL_DIR} gelöscht (Backups bleiben unter /tmp)"
            fi
        else
            rm -rf "$INSTALL_DIR"
            ok "${INSTALL_DIR} gelöscht"
        fi
    else
        skip "Verzeichnis bleibt erhalten"
    fi
else
    skip "${INSTALL_DIR} nicht gefunden (Projekt evtl. an anderem Ort)"

    # Prüfen ob Skript von einem anderen Ort läuft
    if [[ "$PROJECT_ROOT" != "$INSTALL_DIR" ]]; then
        echo -e "  ${DIM}Aktuelles Projekt-Verzeichnis: ${PROJECT_ROOT}${NC}"
        if ask_yn "Projekt-Verzeichnis ${PROJECT_ROOT} löschen?" "n"; then
            if ask_yn "Wirklich? Dies löscht alle Skripte und Konfigurationen!" "n"; then
                cd / && rm -rf "$PROJECT_ROOT"
                ok "${PROJECT_ROOT} gelöscht"
                echo ""
                echo -e "  ${BOLD}Hinweis:${NC} Da der Skriptpfad gelöscht wurde, wird das Skript jetzt beendet."
                blank
                divider
                exit 0
            else
                skip "Verzeichnis bleibt erhalten"
            fi
        fi
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# ABSCHLUSS
# ═════════════════════════════════════════════════════════════════════════════
blank
divider
blank
echo -e "  ${BOLD}${GREEN}✔  Reset abgeschlossen!${NC}"
blank
echo -e "  ${CYAN}Nächste Schritte:${NC}"
blank
echo -e "  ${BOLD}Neu installieren (Setup-Wizard):${NC}"
echo -e "  ${DIM}# Falls Verzeichnis noch vorhanden:${NC}"
echo -e "  sudo bash /opt/pi-vpn/scripts/setup/setup-wizard.sh"
blank
echo -e "  ${DIM}# Oder frisch klonen:${NC}"
echo -e "  git clone https://<TOKEN>@github.com/ReXx09/PI-VPN.git /opt/pi-vpn"
echo -e "  sudo bash /opt/pi-vpn/scripts/setup/setup-wizard.sh"
blank
echo -e "  ${BOLD}Status prüfen (nach Neuinstallation):${NC}"
echo -e "  sudo bash /opt/pi-vpn/scripts/manage/status.sh"
blank
divider
blank
