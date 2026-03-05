# PI-VPN — Site-to-Site WireGuard über IPv6

Raspberry Pi basiertes Site-to-Site VPN zwischen zwei Standorten mit **CGNAT/DS-Lite-kompatiblem IPv6-Tunnel**.

---

## Was ist PI-VPN?

PI-VPN ist ein vollständig automatisiertes Setup-System für ein **Site-to-Site VPN zwischen zwei Wohnstandorten** —
speziell entwickelt für Anschlüsse **ohne öffentliche IPv4-Adresse** (CGNAT / DS-Lite).

### Das Problem

Viele moderne Internetzugänge vergeben keine öffentliche IPv4-Adresse mehr:

- **Starlink** setzt CGNAT ein → kein erreichbares IPv4 von außen
- **Vodafone Kabel** nutzt DS-Lite → IPv4 liegt hinter einem Carrier-NAT

Klassische VPN-Setups, die eine feste öffentliche IPv4 voraussetzen, funktionieren hier **nicht**.

### Die Lösung

Beide Standorte haben **nativ IPv6** → PI-VPN baut den gesamten WireGuard-Tunnel
ausschließlich über IPv6 auf. DDNS sorgt dafür, dass sich die Gegenstelle auch bei
wechselnder IPv6-Adresse (Starlink vergbt neue Präfixe) immer findet.

### Was dieses Projekt liefert

| Komponente                  | Beschreibung                                                                 |
|-----------------------------|------------------------------------------------------------------------------|
| **menu.sh**                 | Grafische TUI-Oberfläche (whiptail) als zentraler Einstiegspunkt            |
| **setup-wizard.sh**         | Interaktiver 7-Stufen-Installer: Docker, WireGuard, .env, Container-Start   |
| **install-docker.sh**       | Standalone-Skript zum Installieren von Docker CE auf dem Raspberry Pi        |
| **init.sh**                 | Legt Verzeichnisstruktur und Berechtigungen an                               |
| **status.sh**               | Vollständiger VPN-Status: Tunnel, Container, DDNS, IP-Forwarding            |
| **backup.sh**               | Backup aller Konfigurationsdateien (Keys, Peers, .env, wg0.conf)            |
| **reset.sh**                | 8-stufiger interaktiver Reset für Neu-Tests und Deinstallation               |
| **docker-compose.yml**      | Fertig konfigurierter Stack: wireguard-ui + ddns-go                          |
| **Dokumentation (docs/)**   | Schritt-für-Schritt-Anleitungen für alle Komponenten                         |

### Architektur im Überblick

```
Hauptwohnsitz                          Nebenwohnsitz
────────────────────────────           ─────────────────────────────────────
OPNsense (WireGuard-Server)            Raspberry Pi (WireGuard-Client)
  • os-wireguard Plugin                  • wireguard-ui (Docker, Port 5000)
  • DDNS → Cloudflare AAAA               • ddns-go     (Docker, Port 9876)
  • VPN-IP: 10.10.0.1                    • VPN-IP: 10.10.0.2
  • LAN: 192.168.10.0/24                 • LAN: 192.168.20.0/24

         ◄══ WireGuard Tunnel über IPv6 (MTU 1280, Keepalive 25s) ══►
```

### Wofür eignet sich PI-VPN?

- **Fernzugriff auf das Heimnetz** — auf NAS, Drucker, Smarthome-Geräte am Hauptwohnsitz zugreifen
- **Gemeinsames Netzwerk** — Geräte an beiden Standorten kommunizieren direkt miteinander
- **Streaming via Starlink** — Full-Tunnel-Modus leitet den gesamten Datenverkehr am Nebenwohnsitz durch den Heimanschluss
- **Sicherer Kanal** — verschlüsseltes WireGuard-Protokoll, keine dritten Parteien (kein Cloud-VPN)

### Voraussetzungen auf einen Blick

| Was                     | Anforderung                                                   |
|-------------------------|---------------------------------------------------------------|
| Hauptwohnsitz           | OPNsense ≥ 21.7 mit `os-wireguard`-Plugin                    |
| Nebenwohnsitz           | Raspberry Pi 4 oder 5, Raspberry Pi OS Bookworm 64-bit        |
| Internetzugang          | IPv6 an beiden Standorten (CGNAT/DS-Lite kein Problem)        |
| DDNS                    | Cloudflare (empfohlen) oder anderer Anbieter mit AAAA-Support |
| GitHub-Zugang           | Fine-grained Token mit Read-Zugriff auf dieses Repo           |

---

## Netzwerkübersicht

```
┌──────────────────────────────────────────────────────┐
│              HAUPTWOHNSITZ                           │
│  Starlink (CGNAT, IPv6 nativ)                        │
│       │                                              │
│   OPNsense                                           │
│   ├── WireGuard-Plugin (Server, Port 51820)          │
│   ├── Dynamisches DNS → AAAA-Record (eingebaut)      │
│   └── LAN 192.168.10.0/24    VPN-IP: 10.10.0.1      │
│                                                      │
│       ➜ KEIN Raspberry Pi am Hauptwohnsitz nötig!   │
└─────────────────────┬────────────────────────────────┘
                      │  WireGuard Tunnel
                      │  über IPv6 (AAAA)
                      │  (kein öffentl. IPv4 nötig!)
┌─────────────────────┴────────────────────────────────┐
│              NEBENWOHNSITZ                           │
│  Vodafone Kabel (DS-Lite, IPv6 nativ)                │
│       │                                              │
│   Fritzbox 6660 → LAN 192.168.20.0/24               │
│       │                                              │
│   Raspberry Pi  ← EINZIGER RASPI                     │
│   [wireguard-client]  VPN-IP: 10.10.0.2             │
│   [ddns-go]           (optional)                     │
└──────────────────────────────────────────────────────┘
```

---

## Warum nur IPv6?

| Standort     | Provider        | IPv4-Problem         | IPv6         |
|-------------|-----------------|----------------------|--------------|
| Hauptwohnsitz| Starlink        | CGNAT (kein /32 WAN) | ✅ Nativ     |
| Nebenwohnsitz| Vodafone Kabel  | DS-Lite (kein /32)   | ✅ Nativ     |

Beide Anschlüsse haben **kein öffentlich erreichbares IPv4**, aber **natives IPv6**.  
→ WireGuard verbindet sich **ausschließlich via IPv6 (AAAA-Record über DDNS)**.

---

## Stack

### Hauptwohnsitz — OPNsense (kein Docker, kein Raspi)

| Funktion              | Wo konfiguriert                              |
|----------------------|----------------------------------------------|
| WireGuard-Server     | OPNsense → VPN → WireGuard (Plugin nativ)   |
| IPv6-DDNS (AAAA)     | OPNsense → Dienste → Dynamisches DNS        |

### Nebenwohnsitz — Raspberry Pi (Docker)

| Container    | Image                    | Funktion                        |
|-------------|-------------------------|---------------------------------|
| `wireguard` | `linuxserver/wireguard` | WireGuard-Client                |
| `ddns-go`   | `jeessy/ddns-go`        | IPv6-DDNS-Updater (optional)    |

---

## Verzeichnisstruktur

```
PI-VPN/
├── README.md
├── menu.sh                         # ← Zentrales Menü (TUI) — hier starten!
├── docker/
│   └── nebenwohnsitz/
│       ├── docker-compose.yml      # Einziger Docker-Stack (Raspi)
│       └── .env.example            # Umgebungsvariablen
├── config/
│   ├── server/
│   │   └── wg0.conf.example        # OPNsense Peer-Referenz
│   └── clients/
│       └── nebenwohnsitz.conf.example  # Raspi Client-Konfig
├── docs/
│   ├── Befehls-Referenz.md         # Alle Befehle direkt ohne Menü
│   ├── Netzwerkuebersicht.md       # Detaillierte Netzwerkplanung
│   ├── Setup-Anleitung.md          # Schritt-für-Schritt Guide
│   ├── OPNsense-WireGuard.md       # WireGuard-Plugin in OPNsense
│   └── Fritzbox-IPv6-Setup.md      # IPv6-Freigabe Nebenwohnsitz
└── scripts/
    ├── setup/
    │   ├── setup-wizard.sh         # Interaktiver 7-Stufen-Installer
    │   ├── install-docker.sh       # Docker auf Raspberry Pi installieren
    │   └── init.sh                 # Erstkonfiguration
    └── manage/
        ├── status.sh               # VPN-Status anzeigen
        ├── backup.sh               # Konfig-Backup
        └── reset.sh                # Interaktiver Reset / Deinstallation
```

---

## Schnellstart

### 1. OPNsense (Hauptwohnsitz) — WireGuard-Server einrichten
Siehe → [docs/OPNsense-WireGuard.md](docs/OPNsense-WireGuard.md)
- WireGuard-Plugin aktivieren, Schlüsselpaar generieren
- Peer `nebenwohnsitz` anlegen
- Dynamisches DNS einrichten (AAAA-Record)

### 2. Raspberry Pi (Nebenwohnsitz) — Zentrales Menü & Installer

```bash
# Repo klonen — DEIN_TOKEN durch den GitHub Fine-grained Token ersetzen
# (Token erstellen: github.com → Settings → Developer settings → Fine-grained tokens)
# Beispiel-Token-Format: github_pat_11ABCDEF_...
sudo git clone https://DEIN_TOKEN@github.com/ReXx09/PI-VPN.git /opt/pi-vpn

# Zentrales Menü starten — grafische TUI-Oberfläche für alle Funktionen
cd /opt/pi-vpn
sudo bash menu.sh
```

Das **zentrale Menü** (`menu.sh`) bietet eine grafische Terminal-Oberfläche (TUI)
mit allen Funktionen auf einen Blick:

| Menüpunkt               | Funktion                                                      |
|-------------------------|---------------------------------------------------------------|
| [SETUP]  Setup          | Wizard, Docker installieren, Verzeichnisse anlegen            |
| [STATUS] Monitoring     | VPN-Status, Container-Logs, wg show, Routing                  |
| [CONTAINER] Verwaltung  | Start / Stop / Restart, Live-Logs, Backup                     |
| [CONFIG] Konfiguration  | .env bearbeiten, git pull, Systeminformationen                |
| [RESET]  Deinstallation | Interaktiver Komplett-Reset für Neu-Tests                     |

> Alternativ direkt den Setup-Wizard starten:
> `sudo bash /opt/pi-vpn/scripts/setup/setup-wizard.sh`

---

## Streaming-Dienste (Split-Tunnel)

Um Streaming-Dienste vom Hauptwohnsitz auch am Nebenwohnsitz zu nutzen:
- Variante A: **Full-Tunnel** → alle Geräte routen via VPN (`AllowedIPs = 0.0.0.0/0, ::/0`)
- Variante B: **Split-Tunnel** → nur Heimnetz erreichbar, Streaming manuell per Proxy/DNS

Details → [docs/Setup-Anleitung.md](docs/Setup-Anleitung.md)

---

## Anforderungen

- **Hauptwohnsitz:** OPNsense ≥ 21.7 (WireGuard-Plugin verfügbar)
- **Nebenwohnsitz:** 1× Raspberry Pi 4 oder 5 mit Raspberry Pi OS Bookworm (64-bit)
- Docker ≥ 24.x & Docker Compose ≥ 2.x (nur auf dem Raspi)
- DDNS-Provider mit AAAA-Unterstützung (Cloudflare empfohlen)
  - Hauptwohnsitz: direkt in OPNsense unter Dienste → Dynamisches DNS
  - Nebenwohnsitz: ddns-go Container (optional)
