# Setup-Anleitung — PI-VPN Site-to-Site

## Voraussetzungen

- 2× Raspberry Pi 4 oder 5 mit **Raspberry Pi OS Bookworm 64-bit**
- Stabile LAN-Verbindung am jeweiligen Router (kein WLAN für den VPN-Raspi)
- DDNS-Provider-Account mit **AAAA-Record-Support** (Empfehlung: Cloudflare oder DeSEC)
- Zugang zu OPNsense (Hauptwohnsitz) und Fritzbox-Admin (Nebenwohnsitz)

---

## Phase 1 — Docker auf dem Raspberry Pi installieren

Auf dem Nebenwohnsitz-Raspi ausführen:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Oder mit dem mitgelieferten Skript:
```bash
sudo bash /opt/pi-vpn/scripts/setup/install-docker.sh
```

---

## ⚡ Schnellstart: Interaktiver Setup-Wizard

Der Wizard führt dich durch **alle Schritte automatisch** — empfohlener Einstieg:

```bash
cd /opt/pi-vpn
sudo bash scripts/setup/setup-wizard.sh
```

Der Wizard erledigt:
- Systemcheck (Kernel, Docker, WireGuard-Modul)
- Docker installieren (falls noch nicht vorhanden)
- IP-Forwarding + Kernel-Tweaks setzen
- Alle Konfigurationswerte interaktiv abfragen
- `.env` automatisch generieren
- Container starten
- Nächste Schritte für die wireguard-ui WebUI erklären

> Die manuelle Schritt-für-Schritt-Anleitung folgt unterhalb für Referenz.

---

## Phase 2 — IPv6 am System aktivieren

Auf **beiden Raspis**:

```bash
# Prüfen ob IPv6 verfügbar ist
ip -6 addr show

# Forwarding dauerhaft aktivieren
sudo tee /etc/sysctl.d/99-vpn-forward.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.src_valid_mark = 1
EOF

sudo sysctl --system
```

---

## Phase 3 — DDNS einrichten (Hauptwohnsitz zuerst)

### 3.1 DDNS-Go starten

```bash
cd /opt/pi-vpn/docker/hauptwohnsitz
cp .env.example .env
# .env anpassen (Passwörter etc.)
sudo docker compose up -d ddns-go
```

### 3.2 DDNS-Go konfigurieren

1. Browser öffnen: `http://<raspi-hauptwohnsitz-ip>:9876`
2. Anbieter wählen (z. B. **Cloudflare** oder **DeSEC**)
3. API-Token eingeben (Cloudflare: DNS-Edit-Permission)
4. Domain eingeben: z. B. `vpn-home.deine-domain.de`
5. **Record-Typ: AAAA** (IPv6!) auswählen
6. IPv6-Quelle: **Netzwerk-Interface** → `eth0` wählen
7. Intervall: 5 Minuten
8. Speichern → **Jetzt aktualisieren** klicken

> **Hinweis:** Starlink wechselt das IPv6-Prefix unregelmäßig (meist alle paar Stunden bis Tage). DDNS-go erkennt das automatisch.

### 3.3 DNS-Auflösung testen

```bash
# Von einem anderen Gerät / oder dem Raspi selbst
nslookup -type=AAAA vpn-home.deine-domain.de
# Sollte die aktuelle IPv6-Adresse des Starlink-Anschlusses zeigen
```

---

## Phase 4 — WireGuard-Server starten (Hauptwohnsitz)

```bash
cd /opt/pi-vpn/docker/hauptwohnsitz
sudo docker compose up -d wireguard-ui
```

### 4.1 Erst-Setup in der WebUI

1. Browser: `http://<raspi-hauptwohnsitz-ip>:5000`
2. Login mit `admin` / Passwort aus `.env`
3. Menü **"WireGuard Server"** → Einstellungen prüfen:
   - **Endpoint**: `vpn-home.deine-domain.de` (dein DDNS-Hostname)
   - **Listen Port**: `51820`
   - **Server Address**: `10.10.0.1/24`
   - **MTU**: `1280`
   - **DNS**: `10.10.0.1` (OPNsense) oder `1.1.1.1`
4. **"Save"** klicken → WireGuard startet automatisch

### 4.2 Peer (Nebenwohnsitz) anlegen

1. Tab **"Wireguard Clients"** → **"+ New Client"**
2. Name: `Nebenwohnsitz`
3. **Allocated IPs**: `10.10.0.2/32`
4. **Allowed IPs**: `10.10.0.2/32, 192.168.20.0/24`
5. **Use Server DNS**: aktivieren
6. **Persistent Keepalive**: `25`
7. **Apply Config** → Konfig wird aktiv

### 4.3 Client-Konfig exportieren

- Auf den Peer (Nebenwohnsitz) klicken → **"Download"**
- Datei `wg0.conf` auf dem Nebenwohnsitz-Raspi ablegen:
  ```
  /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf
  ```

---

## Phase 5 — OPNsense konfigurieren (Hauptwohnsitz)

Damit der WireGuard-Raspi Pakete aus dem LAN weiterleiten kann, muss OPNsense:

1. **Port-Forwarding (IPv6):**
   - Protokoll: UDP
   - Ziel-Port: 51820
   - Weiterleitung an: `[IPv6-Adresse des Raspi]:51820`

2. **Firewall-Regel WAN → Raspi:**
   - Interface: WAN (Starlink-seitig)
   - Protokoll: UDP
   - Ziel: `[Raspi IPv6-Adresse]` Port `51820`
   - Action: PASS

3. **Routing LAN → VPN-Subnetz:**
   - Route `10.10.0.0/24` und `192.168.20.0/24` über die Raspi-LAN-IP

→ Detaillierte OPNsense-Anleitung: [OPNsense-Setup.md](OPNsense-Setup.md)

---

## Phase 6 — WireGuard-Client starten (Nebenwohnsitz)

```bash
cd /opt/pi-vpn/docker/nebenwohnsitz

# Konfig-Verzeichnis anlegen und wg0.conf ablegen (aus Schritt 4.3)
mkdir -p data/wireguard
# Datei kopieren/einfügen...

sudo docker compose up -d wireguard
```

### 6.1 Verbindung prüfen

```bash
# Auf dem Nebenwohnsitz-Raspi:
sudo docker exec wireguard-client wg show

# Erwartete Ausgabe:
# interface: wg0
#   latest handshake: xx seconds ago
#   transfer: ...

# Ping zum Server
ping 10.10.0.1
```

---

## Phase 7 — Fritzbox IPv6-Freigabe (Nebenwohnsitz)

→ Detaillierte Fritzbox-Anleitung: [Fritzbox-IPv6-Setup.md](Fritzbox-IPv6-Setup.md)

Kurzfassung:
- **Heimnetz → Netzwerk → IPv6** → IPv6 aktivieren
- **Internet → Freigaben → Portfreigaben** → WireGuard UDP 51820 für den Raspi
- Fritzbox vergibt dem Raspi eine feste IPv6-Adresse (DHCPv6 mit DUID oder statisch)

---

## Streaming-Dienste nutzen

### Full-Tunnel (einfachste Methode)

In der Datei `/opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf`:
```ini
[Peer]
# AllowedIPs = 10.10.0.0/24, 192.168.10.0/24  ← auskommentieren
AllowedIPs = 0.0.0.0/0, ::/0                   ← aktivieren
```

Alle Geräte am Nebenwohnsitz, die ihren Gateway auf den Raspi zeigen,
routen ihren Traffic durch das Heimnetz Hauptwohnsitz.

### Split-Tunnel + Smart-DNS (fortgeschritten)

Nur den DNS-Resolver auf OPNsense umleiten; Streaming-Hosts via DNS-Overrides
auf die Hauptwohnsitz-IP zeigen lassen. Kein Full-Tunnel nötig.

---

## Nützliche Kommandos

```bash
# WireGuard-Status am Server
sudo docker exec wireguard-ui wg show

# DDNS-Log
sudo docker logs ddns-go --tail 50

# VPN neu starten
cd /opt/pi-vpn/docker/hauptwohnsitz
sudo docker compose restart wireguard-ui

# Backup erstellen
sudo bash /opt/pi-vpn/scripts/manage/backup.sh
```
