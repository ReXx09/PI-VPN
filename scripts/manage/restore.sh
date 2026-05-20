#!/usr/bin/env bash
# =============================================================================
# PI-VPN — Backup wiederherstellen
# Stellt ein gesichertes Backup unter /opt/pi-vpn/ wieder her.
#
# Copyright (c) 2026 Bocki — MIT License
# https://github.com/ReXx09/PI-VPN
#
# Ausführen als: sudo bash scripts/manage/restore.sh
#
# Workflow:
#   1. Backup-Tar per SFTP/FileZilla von /home/pi/pi-vpn-backup/ herunterladen
#   2. Bei Wiederherstellung: Tar zurück nach /home/pi/pi-vpn-backup/ hochladen
#   3. Dieses Skript als root ausführen — es übernimmt alles
# =============================================================================

set -euo pipefail

# ─── Farben & Symbole ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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

# ─── Pfade ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker/nebenwohnsitz"

# Backup suchen: erst im Repo-Verzeichnis, dann im SFTP-Export-Ordner
SEARCH_DIRS=(
    "$PROJECT_ROOT/backups"
    "/home/pi/pi-vpn-backup"
    "/home/${SUDO_USER:-pi}/pi-vpn-backup"
    "/tmp"
)

# ─── Banner ───────────────────────────────────────────────────────────────────
clear; blank
echo -e "${BOLD}${RED}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}  ║      PI-VPN — Backup Wiederherstellen    ║${NC}"
echo -e "${BOLD}${RED}  ╚══════════════════════════════════════════╝${NC}"
blank

# ─── Backups suchen ───────────────────────────────────────────────────────────
declare -a FOUND_BACKUPS=()
declare -A SEEN_BACKUP_NAMES=()
for DIR in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$DIR" ]]; then
        while IFS= read -r -d '' f; do
            NAME="$(basename "$f")"
            # Gleichnamige Backups nur einmal anzeigen (Priorität: erstes Suchverzeichnis).
            if [[ -z "${SEEN_BACKUP_NAMES[$NAME]:-}" ]]; then
                FOUND_BACKUPS+=("$f")
                SEEN_BACKUP_NAMES[$NAME]=1
            fi
        done < <(find "$DIR" -maxdepth 1 -name "pi-vpn-backup_*.tar.gz" -print0 2>/dev/null | sort -rz)
    fi
done

if [[ ${#FOUND_BACKUPS[@]} -eq 0 ]]; then
    error "Keine Backup-Dateien gefunden.

  Gesuchte Pfade:
$(for D in "${SEARCH_DIRS[@]}"; do echo "    $D"; done)

  Backup per SFTP/FileZilla nach /home/pi/pi-vpn-backup/ hochladen,
  dann dieses Skript erneut ausführen."
fi

# ─── Backup auswählen ─────────────────────────────────────────────────────────
info "Verfügbare Backups:"
blank
for i in "${!FOUND_BACKUPS[@]}"; do
    F="${FOUND_BACKUPS[$i]}"
    SIZE=$(du -sh "$F" 2>/dev/null | cut -f1 || echo "?")
    DATE=$(basename "$F" | grep -oP '\d{8}_\d{6}' | sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)\(..\)/\3.\2.\1 \4:\5:\6/' || echo "")
    echo -e "    ${BOLD}[$((i+1))]${NC}  $(basename "$F")  ${DIM}(${SIZE}, ${DATE})${NC}"
done
blank

if [[ ${#FOUND_BACKUPS[@]} -eq 1 ]]; then
    SELECTED="${FOUND_BACKUPS[0]}"
    info "Nur ein Backup gefunden — wird automatisch verwendet."
else
    echo -ne "  ${CYAN}▶${NC} Auswahl [1-${#FOUND_BACKUPS[@]}]: "
    read -r CHOICE
    [[ "$CHOICE" =~ ^[0-9]+$ && "$CHOICE" -ge 1 && "$CHOICE" -le "${#FOUND_BACKUPS[@]}" ]] \
        || error "Ungültige Auswahl."
    SELECTED="${FOUND_BACKUPS[$((CHOICE-1))]}"
fi

blank
ok "Gewähltes Backup: $(basename "$SELECTED")"

# ─── Inhalt prüfen ────────────────────────────────────────────────────────────
blank; info "Inhalt des Backups:"
tar -tzf "$SELECTED" 2>/dev/null | sed 's/^/    /' | head -30 || error "Backup-Archiv beschädigt oder nicht lesbar."
blank

# ─── Bestätigung ──────────────────────────────────────────────────────────────
divider
warn "Bestehende Konfiguration wird überschrieben!"
warn "Betroffenes Verzeichnis: $PROJECT_ROOT"
blank
echo -ne "  ${BOLD}Fortfahren? [j/N]:${NC} "
read -r CONFIRM
[[ "${CONFIRM,,}" == "j" ]] || { echo -e "\n  Abgebrochen.\n"; exit 0; }

# ─── Container stoppen ────────────────────────────────────────────────────────
blank; info "Stoppe laufende Container…"
if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
    cd "$DOCKER_DIR"
    docker compose down 2>/dev/null && ok "Container gestoppt" || warn "docker compose down fehlgeschlagen (ignoriert)"
else
    warn "docker-compose.yml nicht gefunden — Container werden nicht gestoppt"
fi

# ─── Sicherheitskopie der aktuellen Konfiguration ────────────────────────────
if [[ -f "$DOCKER_DIR/.env" || -d "$DOCKER_DIR/data" ]]; then
    PRE_BACKUP="$PROJECT_ROOT/backups/pre-restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$PROJECT_ROOT/backups"
    info "Erstelle Sicherung der aktuellen Konfiguration: $PRE_BACKUP"
    cd "$PROJECT_ROOT"
    tar -czf "$PRE_BACKUP" \
        --exclude='backups' \
        docker/nebenwohnsitz/.env \
        docker/nebenwohnsitz/data \
        2>/dev/null || warn "Aktuelle Konfiguration konnte nicht vollständig gesichert werden (ignoriert)"
    ok "Aktuelle Konfiguration gesichert"
fi

# ─── Wiederherstellen ─────────────────────────────────────────────────────────
blank; info "Stelle Backup wieder her nach: $PROJECT_ROOT"
cd "$PROJECT_ROOT"
tar -xzf "$SELECTED" -C "$PROJECT_ROOT"
ok "Dateien wiederhergestellt"

# Berechtigungen korrigieren (root:root, Dateien 640, Verzeichnisse 750)
chmod -R 750 "$DOCKER_DIR/data" 2>/dev/null || true
find "$DOCKER_DIR/data" -type f -exec chmod 640 {} \; 2>/dev/null || true
ok "Berechtigungen korrigiert"

# ─── Container neu starten ────────────────────────────────────────────────────
blank; info "Starte Container…"
cd "$DOCKER_DIR"
BUILDKIT_PROGRESS=plain docker compose up -d
ok "Container gestartet"

# ─── Ergebnis ────────────────────────────────────────────────────────────────
blank; divider
echo -e "  ${GREEN}${BOLD}✔  Wiederherstellung abgeschlossen!${NC}"
blank
RASPI_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<raspi-ip>")
echo -e "  ${BOLD}wireguard-ui:${NC}  ${CYAN}http://${RASPI_IP}:5000${NC}"
echo -e "  ${BOLD}ddns-go:${NC}       ${CYAN}http://${RASPI_IP}:9876${NC}"
echo -e "  ${BOLD}Dashboard:${NC}     ${CYAN}http://${RASPI_IP}:8080${NC}"
blank
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || true
blank; divider; blank
