#!/usr/bin/env bash
# =============================================================================
# PI-VPN — Dashboard nachinstallieren
# Baut das Web-Dashboard-Image und startet den Container.
#
# Copyright (c) 2026 Bocki — MIT License
# https://github.com/ReXx09/PI-VPN
#
# Ausführen als: sudo bash scripts/setup/install-dashboard.sh
#
# Was dieses Skript macht:
#   1. Prüft ob Docker verfügbar ist
#   2. Prüft ob die docker-compose.yml das Dashboard-Service enthält
#   3. Baut das Image (pi-vpn-dashboard:latest)
#   4. Startet den dashboard-Container
#   5. Zeigt die Dashboard-URL
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
blank()   { echo ""; }
divider() { echo -e "${DIM}────────────────────────────────────────────────────────${NC}"; }

# ─── Root-Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Bitte als root ausführen: sudo bash $0"
[[ "$(uname -s)" == "Linux" ]] || error "Nur für Linux (Raspberry Pi OS)."

# ─── Pfade ermitteln ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker/nebenwohnsitz"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"
DASHBOARD_DIR="$DOCKER_DIR/dashboard"

# ─── Banner ───────────────────────────────────────────────────────────────────
clear; blank
echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}  ║      PI-VPN Dashboard — Installer        ║${NC}"
echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════╝${NC}"
blank

# ─── Schritt 1: Docker prüfen ─────────────────────────────────────────────────
info "Prüfe Docker…"
command -v docker &>/dev/null   || error "Docker ist nicht installiert. Bitte zuerst install-docker.sh ausführen."
docker info &>/dev/null 2>&1    || error "Docker-Daemon läuft nicht. Bitte 'systemctl start docker' ausführen."
ok "Docker verfügbar"

# ─── Schritt 2: Dateien prüfen ────────────────────────────────────────────────
info "Prüfe Projektdateien…"
[[ -f "$COMPOSE_FILE" ]]                  || error "docker-compose.yml nicht gefunden: $COMPOSE_FILE"
[[ -d "$DASHBOARD_DIR" ]]                 || error "Dashboard-Verzeichnis fehlt: $DASHBOARD_DIR"
[[ -f "$DASHBOARD_DIR/Dockerfile" ]]      || error "Dockerfile fehlt: $DASHBOARD_DIR/Dockerfile"
[[ -f "$DASHBOARD_DIR/app.py" ]]          || error "app.py fehlt: $DASHBOARD_DIR/app.py"
grep -q "dashboard:" "$COMPOSE_FILE"      || error "Kein 'dashboard'-Service in docker-compose.yml gefunden."
ok "Alle Dateien vorhanden"

# ─── Schritt 3: VPN_HOST aus .env lesen (optional) ───────────────────────────
ENV_FILE="$DOCKER_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
    ok ".env geladen (VPN_HOST=${VPN_HOST:-<nicht gesetzt>})"
else
    warn ".env nicht gefunden — Dashboard startet ohne VPN_HOST (DDNS-Abgleich deaktiviert)"
fi

# ─── Schritt 4: Image bauen ───────────────────────────────────────────────────
blank; divider
echo -e "  ${BOLD}Baue Dashboard-Image…${NC}"
divider; blank

cd "$DOCKER_DIR"
BUILDKIT_PROGRESS=plain docker compose build dashboard

blank; ok "Image pi-vpn-dashboard:latest gebaut"

# ─── Schritt 5: Container starten ─────────────────────────────────────────────
blank
info "Starte dashboard-Container…"
docker compose up -d dashboard
ok "dashboard-Container läuft"

# ─── Schritt 6: Status + URL anzeigen ────────────────────────────────────────
blank; divider
RASPI_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<raspi-ip>")
echo -e "  ${GREEN}${BOLD}✔  Dashboard erfolgreich installiert!${NC}"
blank
echo -e "  ${BOLD}Dashboard-URL:${NC}    ${CYAN}http://${RASPI_IP}:8080${NC}"
blank
echo -e "  Container-Status:"
docker ps --filter "name=dashboard" --format "    {{.Names}}  {{.Status}}" 2>/dev/null || true
blank; divider; blank
