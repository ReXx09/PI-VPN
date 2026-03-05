#!/usr/bin/env bash
# =============================================================================
# install-docker.sh — Docker CE auf Raspberry Pi OS Bookworm installieren
# Ausführen als: sudo bash scripts/setup/install-docker.sh
# =============================================================================

set -euo pipefail

# Farben für Ausgabe
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Nur auf Linux ausführbar
[[ "$(uname -s)" == "Linux" ]] || error "Dieses Skript ist nur für Linux (Raspberry Pi OS)."

info "Docker CE Installation startet..."

# Alte Versionen entfernen
info "Entferne veraltete Docker-Pakete (falls vorhanden)..."
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Abhängigkeiten installieren
info "Installiere Abhängigkeiten..."
apt-get update -qq
apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Docker GPG-Key hinzufügen
info "Füge Docker-GPG-Schlüssel hinzu..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Docker-Repository hinzufügen
info "Füge Docker-Repository hinzu..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker installieren
info "Installiere Docker CE und Docker Compose Plugin..."
apt-get update -qq
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Docker-Dienst aktivieren
info "Aktiviere und starte Docker-Dienst..."
systemctl enable docker
systemctl start docker

# Aktuellen Benutzer zur docker-Gruppe hinzufügen
CURRENT_USER="${SUDO_USER:-$USER}"
if [[ "$CURRENT_USER" != "root" ]]; then
    info "Füge Benutzer '$CURRENT_USER' zur docker-Gruppe hinzu..."
    usermod -aG docker "$CURRENT_USER"
    warn "Bitte neu einloggen damit die Gruppenzugehörigkeit wirkt!"
fi

# IPv4/IPv6-Forwarding aktivieren
info "Aktiviere IP-Forwarding..."
tee /etc/sysctl.d/99-vpn-forward.conf > /dev/null << 'EOF'
# PI-VPN: IP-Forwarding für WireGuard
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.src_valid_mark = 1

# IPv6 Privacy Extensions deaktivieren (stabile SLAAC-Adresse)
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOF
sysctl --system > /dev/null 2>&1

# Versionen ausgeben
info "Installation abgeschlossen!"
echo ""
docker --version
docker compose version
echo ""
info "Weiter mit: sudo bash scripts/setup/init.sh"
