# PI-VPN — Befehls-Referenz (ohne Menü)

Alle Aktionen lassen sich direkt per Befehl aufrufen — ohne das zentrale Menü (`menu.sh`).
Diese Referenz entspricht 1:1 den Menüpunkten.

---

## Setup & Installation

```bash
# ① Vollständige Installation (interaktiver Wizard — empfohlen für Erstsetup)
sudo bash /opt/pi-vpn/scripts/setup/setup-wizard.sh

# ② Nur Docker CE installieren
sudo bash /opt/pi-vpn/scripts/setup/install-docker.sh

# ③ Nur Verzeichnisstruktur anlegen (init)
sudo bash /opt/pi-vpn/scripts/setup/init.sh
```

---

## Status & Monitoring

```bash
# Vollständiger VPN-Status (Tunnel, Container, DDNS, IP-Forwarding)
sudo bash /opt/pi-vpn/scripts/manage/status.sh

# WireGuard-Interface direkt abfragen
sudo wg show

# Laufende Container anzeigen
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Container-Logs
sudo docker logs wireguard-ui --tail 60
sudo docker logs ddns-go --tail 60

# Live-Logs beider Container verfolgen (Ctrl+C zum Beenden)
sudo docker compose -f /opt/pi-vpn/docker/nebenwohnsitz/docker-compose.yml logs -f --tail 20

# IP-Routing-Tabelle
ip route show
ip -6 route show
```

---

## Container-Verwaltung

```bash
# Alle Container starten
sudo docker compose -f /opt/pi-vpn/docker/nebenwohnsitz/docker-compose.yml up -d

# Alle Container stoppen
sudo docker compose -f /opt/pi-vpn/docker/nebenwohnsitz/docker-compose.yml stop

# Alle Container neu starten
sudo docker compose -f /opt/pi-vpn/docker/nebenwohnsitz/docker-compose.yml restart

# Nur wireguard-ui neu starten
sudo docker restart wireguard-ui

# Nur ddns-go neu starten
sudo docker restart ddns-go

# Konfig-Backup erstellen (Keys, Peers, wg0.conf, .env)
sudo bash /opt/pi-vpn/scripts/manage/backup.sh
```

> **Kurzform** — wenn du dich bereits im Compose-Verzeichnis befindest:
> ```bash
> cd /opt/pi-vpn/docker/nebenwohnsitz
> sudo docker compose up -d       # starten
> sudo docker compose stop        # stoppen
> sudo docker compose restart     # neu starten
> ```

---

## Konfiguration & Updates

```bash
# .env-Datei bearbeiten (Passwörter, IPs, DDNS-Token)
sudo nano /opt/pi-vpn/docker/nebenwohnsitz/.env

# docker-compose.yml anzeigen
cat /opt/pi-vpn/docker/nebenwohnsitz/docker-compose.yml

# Updates vom GitHub holen (Token muss noch gültig sein)
cd /opt/pi-vpn && sudo git pull

# WireGuard-Konfig anzeigen (erst nach Setup-Wizard vorhanden)
sudo cat /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf

# Raspberry Pi Systeminformationen
hostname
hostname -I
cat /etc/os-release | grep PRETTY_NAME
uname -r
uptime -p
free -h
df -h /
docker --version
```

---

## Reset & Deinstallation

```bash
# Interaktiver Reset (8 Stufen, jede einzeln bestätigbar)
sudo bash /opt/pi-vpn/scripts/manage/reset.sh
```

**Was reset.sh macht (jeder Schritt wird einzeln bestätigt):**

| Stufe | Aktion                                        |
|-------|-----------------------------------------------|
| ①    | wg0-Tunnel sofort trennen                     |
| ②    | Docker-Container stoppen und entfernen        |
| ③    | Docker-Volumes löschen (Keys, Peers, DB)      |
| ④    | Docker-Images entfernen                       |
| ⑤    | .env-Datei löschen                            |
| ⑥    | IP-Forwarding zurücksetzen (sysctl)           |
| ⑦    | Docker CE deinstallieren (optional)           |
| ⑧    | Projektverzeichnis /opt/pi-vpn löschen (opt.) |

```bash
# Nach einem Reset: Neu starten mit
sudo bash /opt/pi-vpn/menu.sh
# oder direkt:
sudo bash /opt/pi-vpn/scripts/setup/setup-wizard.sh
```

---

## WebUI-Adressen

| Dienst        | Adresse                       | Standard-Login              |
|---------------|-------------------------------|-----------------------------|
| wireguard-ui  | `http://<raspi-ip>:5000`      | im Setup-Wizard festgelegt  |
| ddns-go       | `http://<raspi-ip>:9876`      | kein Login (lokales Netz)   |

```bash
# Raspi-IP ermitteln
hostname -I | awk '{print $1}'
```

---

## Diagnose & Tools

> Entspricht **Menüpunkt 7 „🔬 Diagnose & Tools"** in `menu.sh`

```bash
# ── Tools installieren (falls nicht vorhanden) ───────────────────────────────
sudo apt-get install -y tcpdump dnsutils nmap

# ── WireGuard Handshake prüfen ───────────────────────────────────────────────
sudo wg show wg0
# Zeigt: latest handshake, Transfer-Bytes, Endpoint

# Alter des letzten Handshakes in Sekunden:
LAST=$(sudo wg show wg0 latest-handshakes | awk '{print $2}')
echo "Handshake vor $(( $(date +%s) - LAST )) Sekunden"

# ── DNS-Auflösung testen ─────────────────────────────────────────────────────
dig A    vpn.deine-domain.de +short   # Sollte leer sein (kein A-Record!)
dig AAAA vpn.deine-domain.de +short   # Muss 2001:db8:... zurückgeben

# ── Ping VPN-Gateway ─────────────────────────────────────────────────────────
ping -c 4 10.10.0.1              # Raspi selbst (VPN-Interface)
ping -c 4 10.10.0.3              # OPNsense (wenn verbunden)

# ── Ping Heimnetz-Gateways ───────────────────────────────────────────────────
ping -c 4 <NEBEN-GW>             # Fritzbox (Nebenwohnsitz — Gateway eintragen)
ping -c 4 <HAUPT-GW>             # OPNsense LAN (Hauptwohnsitz, nur via Tunnel)

# ── IPv6-Adresse prüfen ──────────────────────────────────────────────────────
ip -6 addr show eth0 | grep "scope global"   # Lokale IPv6 des Raspi
curl -6 -s ifconfig.co                        # Öffentliche IPv6 (sollte Raspi sein)

# ── tcpdump UDP 51820 live ───────────────────────────────────────────────────
sudo tcpdump -i eth0 udp port 51820 -n       # Zeigt ein-/ausgehende WG-Pakete

# ── Vollständiger Diagnose-Report ────────────────────────────────────────────
echo "=== wg show ===" && sudo wg show wg0
echo "=== DNS A ==" && dig A vpn.deine-domain.de +short
echo "=== DNS AAAA ==" && dig AAAA vpn.deine-domain.de +short
echo "=== Ping VPN-GW ==" && ping -c 2 10.10.0.1
echo "=== Ping Fritzbox ==" && ping -c 2 <NEBEN-GW>
echo "=== IPv6 lokal ===" && ip -6 addr show eth0 | grep "scope global"
echo "=== IPv6 öffentlich ===" && curl -6 -s --max-time 5 ifconfig.co
echo "=== IP-Forwarding ===" && sysctl net.ipv4.ip_forward
```

---

## Einzelne WireGuard-Befehle (low-level)

```bash
# WireGuard-Interface manuell hoch-/runterfahren
sudo wg-quick up /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf
sudo wg-quick down /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf

# Handshake-Zeitstempel anzeigen
sudo wg show wg0 latest-handshakes

# Peer-Transfer-Statistik
sudo wg show wg0 transfer

# Ping auf OPNsense WireGuard-Interface
ping 10.10.0.3

# Ping auf Hauptwohnsitz-LAN (wenn Tunnel aktiv)
ping <HAUPT-GW>

# Eigene öffentliche IP prüfen (Full-Tunnel: muss Starlink-IP sein)
curl -s https://ifconfig.me
```

---

## Schnell-Referenz (Spickzettel)

| Was                          | Befehl                                                                       |
|------------------------------|------------------------------------------------------------------------------|
| Menü öffnen                  | `sudo bash /opt/pi-vpn/menu.sh`                                              |
| VPN-Status                   | `sudo bash /opt/pi-vpn/scripts/manage/status.sh`                             |
| WireGuard-Status             | `sudo wg show`                                                               |
| Container-Status             | `sudo docker ps`                                                             |
| wireguard-ui Logs            | `sudo docker logs wireguard-ui --tail 60`                                    |
| ddns-go Logs                 | `sudo docker logs ddns-go --tail 60`                                         |
| Container neu starten        | `sudo docker compose -f /opt/pi-vpn/docker/nebenwohnsitz/docker-compose.yml restart` |
| nur wireguard-ui neustarten  | `sudo docker restart wireguard-ui`                                           |
| nur ddns-go neustarten       | `sudo docker restart ddns-go`                                                |
| .env bearbeiten              | `sudo nano /opt/pi-vpn/docker/nebenwohnsitz/.env`                            |
| Backup erstellen             | `sudo bash /opt/pi-vpn/scripts/manage/backup.sh`                             |
| Updates holen                | `cd /opt/pi-vpn && sudo git pull`                                            |
| Alles zurücksetzen           | `sudo bash /opt/pi-vpn/scripts/manage/reset.sh`                              |
| Setup-Wizard                 | `sudo bash /opt/pi-vpn/scripts/setup/setup-wizard.sh`                        |
