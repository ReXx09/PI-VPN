#!/usr/bin/env bash
# =============================================================================
# backup.sh — Konfigurationsbackup für PI-VPN
# Sichert WireGuard-Konfigs, DB und .env-Dateien (OHNE private Schlüssel im Namen)
# Ausführen als: sudo bash scripts/manage/backup.sh
#
# Copyright (c) 2026 Bocki — MIT License
# https://github.com/ReXx09/PI-VPN
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="$BACKUP_DIR/pi-vpn-backup_$TIMESTAMP.tar.gz"

# ─── Export-Verzeichnis (für den pi-User erreichbar, z.B. via SFTP) ──────────
EXPORT_DIR="/home/pi/pi-vpn-backup"
EXPORT_USER="${SUDO_USER:-pi}"

# ─── Nextcloud-Konfiguration (aus .env lesen falls vorhanden) ────────────────
ENV_FILE="$PROJECT_ROOT/docker/nebenwohnsitz/.env"
NC_URL=""          # https://cloud.deine-domain.de
NC_USER=""         # Nextcloud-Benutzername
NC_PASS=""         # Nextcloud App-Passwort (NICHT dein Login-Passwort)
NC_PATH=""         # Zielordner auf Nextcloud z.B. /PI-VPN-Backups
if [[ -f "$ENV_FILE" ]]; then
    NC_URL=$(grep  -E '^NC_URL='  "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
    NC_USER=$(grep -E '^NC_USER=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
    NC_PASS=$(grep -E '^NC_PASS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
    NC_PATH=$(grep -E '^NC_PATH=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
fi

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

# ─── Export-Kopie für SFTP-Zugriff (pi-User / FileZilla) ─────────────────────
# /opt/pi-vpn/backups/ ist root-only → Kopie nach /home/pi/pi-vpn-backup/
# damit der pi-User die Datei per SFTP/FileZilla herunterladen kann.
mkdir -p "$EXPORT_DIR"
chmod 755 "$EXPORT_DIR"
chown "${EXPORT_USER}:${EXPORT_USER}" "$EXPORT_DIR" 2>/dev/null || true

EXPORT_FILE="$EXPORT_DIR/pi-vpn-backup_${TIMESTAMP}.tar.gz"
cp "$BACKUP_FILE" "$EXPORT_FILE"
chmod 640 "$EXPORT_FILE"
chown "${EXPORT_USER}:${EXPORT_USER}" "$EXPORT_FILE" 2>/dev/null || true

# Alte Exporte aufräumen (behalte letzte 10)
ls -t "$EXPORT_DIR"/pi-vpn-backup_*.tar.gz 2>/dev/null \
    | tail -n +11 \
    | xargs -r rm --

echo ""
info "Backup abgeschlossen!"
warn "SICHERHEITSHINWEIS: Das Backup enthält private WireGuard-Schlüssel."
warn "Backup-Verzeichnis (root):      $BACKUP_DIR"
info "Kopie für SFTP-Download:        $EXPORT_FILE"
info "SFTP-Pfad (FileZilla/WinSCP):   /home/${EXPORT_USER}/pi-vpn-backup/"

# ─── Nextcloud WebDAV Upload (optional) ──────────────────────────────────────
if [[ -n "$NC_URL" && -n "$NC_USER" && -n "$NC_PASS" ]]; then
    # Zielordner normalisieren: führenden / sicherstellen, keinen doppelten //
    NC_PATH="${NC_PATH:-/PI-VPN-Backups}"
    NC_PATH="/${NC_PATH#/}"
    BASENAME="$(basename "$EXPORT_FILE")"

    # WebDAV-URL zusammensetzen: <NC_URL>/remote.php/dav/files/<NC_USER><NC_PATH>/
    WEBDAV_BASE="${NC_URL%/}/remote.php/dav/files/${NC_USER}${NC_PATH}"
    WEBDAV_URL="${WEBDAV_BASE}/${BASENAME}"

    echo ""
    info "Nextcloud: Lade Backup hoch…"
    info "Ziel: ${WEBDAV_URL}"

    # Zielordner per MKCOL anlegen (ignoriert 405 = existiert bereits)
    HTTP_MKCOL=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${NC_USER}:${NC_PASS}" \
        -X MKCOL \
        "${WEBDAV_BASE}/" 2>/dev/null || true)
    [[ "$HTTP_MKCOL" =~ ^(201|405|301|302)$ ]] || \
        warn "MKCOL Ordner-Anlage: HTTP $HTTP_MKCOL (wird ignoriert — Upload trotzdem versucht)"

    # Datei hochladen via HTTP PUT
    HTTP_PUT=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${NC_USER}:${NC_PASS}" \
        -T "$EXPORT_FILE" \
        --max-time 120 \
        "${WEBDAV_URL}" 2>/dev/null || true)

    if [[ "$HTTP_PUT" =~ ^(200|201|204)$ ]]; then
        ok "Nextcloud: Upload erfolgreich (HTTP $HTTP_PUT)"
        info "Nextcloud-Pfad: ${NC_PATH}/${BASENAME}"

        # Alte Backups auf Nextcloud aufräumen (behalte letzte 10)
        info "Nextcloud: Bereinige alte Backups (behalte letzte 10)…"
        REMOTE_LIST=$(curl -s \
            -u "${NC_USER}:${NC_PASS}" \
            -X PROPFIND \
            -H "Depth: 1" \
            "${WEBDAV_BASE}/" 2>/dev/null \
            | grep -oP "(?<=<d:href>)[^<]+pi-vpn-backup_[^<]+\.tar\.gz" \
            | sort -r || true)

        COUNT=0
        while IFS= read -r REMOTE_FILE; do
            (( COUNT++ ))
            if [[ $COUNT -gt 10 ]]; then
                DEL_URL="${NC_URL%/}${REMOTE_FILE}"
                HTTP_DEL=$(curl -s -o /dev/null -w "%{http_code}" \
                    -u "${NC_USER}:${NC_PASS}" \
                    -X DELETE \
                    "$DEL_URL" 2>/dev/null || true)
                [[ "$HTTP_DEL" =~ ^(204|200)$ ]] \
                    && info "Nextcloud: gelöscht: $(basename "$REMOTE_FILE")" \
                    || warn "Nextcloud: Löschen fehlgeschlagen: $(basename "$REMOTE_FILE") (HTTP $HTTP_DEL)"
            fi
        done <<< "$REMOTE_LIST"
    else
        warn "Nextcloud: Upload fehlgeschlagen (HTTP $HTTP_PUT)"
        warn "Prüfe: NC_URL, NC_USER, NC_PASS in .env — App-Passwort verwenden!"
        warn "Backup ist lokal gespeichert: $EXPORT_FILE"
    fi
else
    echo ""
    info "Nextcloud: nicht konfiguriert (NC_URL/NC_USER/NC_PASS in .env setzen)"
fi

echo ""
echo "Backup wiederherstellen:"
echo "  tar -xzf $BACKUP_FILE -C $PROJECT_ROOT"
