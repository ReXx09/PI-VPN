#!/usr/bin/env bash
# =============================================================================
# init.sh — Erstinitialisierung des PI-VPN Projekts
# Erstellt Verzeichnisstruktur, .env-Dateien und .gitignore
# Ausführen als: sudo bash scripts/setup/init.sh
# (Alternativ: setup-wizard.sh übernimmt diese Schritte automatisch)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Nur Nebenwohnsitz — Hauptwohnsitz nutzt OPNsense nativ (kein Docker dort)
STANDORT="nebenwohnsitz"
if [[ "${1:-}" == "hauptwohnsitz" ]]; then
    error "Hauptwohnsitz nutzt OPNsense nativ — kein Docker-Stack nötig."
fi

DOCKER_DIR="$PROJECT_ROOT/docker/$STANDORT"

# ─── Datenverzeichnisse anlegen ───────────────────────────────────────────────
info "Erstelle Datenverzeichnisse für $STANDORT..."
mkdir -p "$DOCKER_DIR/data/wireguard"
mkdir -p "$DOCKER_DIR/data/ddns-go"

# ─── .env anlegen (falls noch nicht vorhanden) ────────────────────────────────
ENV_FILE="$DOCKER_DIR/.env"
ENV_EXAMPLE="$DOCKER_DIR/.env.example"

if [[ -f "$ENV_FILE" ]]; then
    warn ".env existiert bereits — wird nicht überschrieben."
else
    if [[ -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        info ".env aus .env.example erstellt → bitte anpassen: nano $ENV_FILE"
    else
        warn ".env.example nicht gefunden — .env muss manuell erstellt werden."
    fi
fi

# ─── .gitignore erstellen ─────────────────────────────────────────────────────
GITIGNORE="$PROJECT_ROOT/.gitignore"
if [[ ! -f "$GITIGNORE" ]]; then
    info "Erstelle .gitignore..."
    cat > "$GITIGNORE" << 'EOF'
# Sensible Konfigurationsdateien — NIEMALS committen!
.env
**/.env
**/data/wireguard/wg0.conf
**/data/wireguard/privatekey
**/data/wireguard/server_privatekey
**/data/db/
**/data/ddns-go/

# Betriebssystem
.DS_Store
Thumbs.db

# Backups
backups/
*.bak
EOF
fi

# ─── Berechtigungen setzen ────────────────────────────────────────────────────
info "Setze Verzeichnisberechtigungen..."
chmod 700 "$DOCKER_DIR/data/wireguard"
chmod 700 "$DOCKER_DIR/data/ddns-go"

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
info "Initialisierung für '$STANDORT' abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo "  1. .env anpassen:  nano $ENV_FILE"
echo "  2. Stack starten:  cd $DOCKER_DIR && sudo docker compose up -d"
if [[ "$STANDORT" == "hauptwohnsitz" ]]; then
    echo "  3. WebUI öffnen:   http://$(hostname -I | awk '{print $1}'):5000"
    echo "  4. DDNS-WebUI:     http://$(hostname -I | awk '{print $1}'):9876"
fi
