#!/usr/bin/env bash
# =============================================================================
# backup.sh — Konfigurationsbackup für PI-VPN
# Sichert WireGuard-Konfigs, DB und .env-Dateien (OHNE private Schlüssel im Namen)
# Ausführen als: sudo bash scripts/manage/backup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="$BACKUP_DIR/pi-vpn-backup_$TIMESTAMP.tar.gz"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Backup-Verzeichnis ───────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# ─── Backup erstellen ─────────────────────────────────────────────────────────
info "Erstelle Backup: $BACKUP_FILE"
info "Wichtig: Backup enthält private Schlüssel — sicher aufbewahren!"

# Dateien die gesichert werden:
BACKUP_ITEMS=()

for STANDORT in hauptwohnsitz nebenwohnsitz; do
    DIR="$PROJECT_ROOT/docker/$STANDORT"
    [[ -d "$DIR" ]] && BACKUP_ITEMS+=("docker/$STANDORT")
done

[[ -d "$PROJECT_ROOT/config" ]] && BACKUP_ITEMS+=("config")

if [[ ${#BACKUP_ITEMS[@]} -eq 0 ]]; then
    error "Keine zu sichernden Verzeichnisse gefunden."
fi

# Tar erstellen (relativ zu PROJECT_ROOT)
cd "$PROJECT_ROOT"
tar -czf "$BACKUP_FILE" \
    --exclude='**/data/ddns-go/cache*' \
    "${BACKUP_ITEMS[@]}"

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
info "Backup erstellt: $BACKUP_FILE ($BACKUP_SIZE)"

# ─── Alte Backups aufräumen (behalte die letzten 10) ─────────────────────────
info "Bereinige alte Backups (behalte letzte 10)..."
ls -t "$BACKUP_DIR"/pi-vpn-backup_*.tar.gz 2>/dev/null \
    | tail -n +11 \
    | xargs -r rm --

BACKUP_COUNT=$(ls "$BACKUP_DIR"/pi-vpn-backup_*.tar.gz 2>/dev/null | wc -l)
info "Vorhandene Backups: $BACKUP_COUNT"

echo ""
info "Backup abgeschlossen!"
warn "SICHERHEITSHINWEIS: Das Backup enthält private WireGuard-Schlüssel."
warn "Backup-Verzeichnis: $BACKUP_DIR (Berechtigungen: 700)"
echo ""
echo "Backup wiederherstellen:"
echo "  tar -xzf $BACKUP_FILE -C $PROJECT_ROOT"
