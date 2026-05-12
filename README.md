# PI-VPN — Site-to-Site WireGuard über IPv6

Raspberry Pi basiertes Site-to-Site VPN zwischen zwei Standorten mit **CGNAT/DS-Lite-kompatiblem IPv6-Tunnel**.

      '' Dies Ist ein persönliches Projekt und für Hilfreiche Tips und Ideen natürlich offen '' 
      '' Ich weis um die Problematik mit CG-NAT und DS-Lite und hoffe mit diesem Projekt, Euch etwas Helfen zu können ;) ''

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
| **install-dashboard.sh**    | Dashboard separat nachinstallieren                                           |
| **init.sh**                 | Legt Verzeichnisstruktur und Berechtigungen an                               |
| **status.sh**               | Vollständiger VPN-Status: Tunnel, Container, DDNS, IP-Forwarding            |
| **backup.sh**               | Backup aller Konfigurationsdateien + optionaler Nextcloud-Upload             |
| **restore.sh**              | Backup-Wiederherstellung aus lokalem Archiv                                  |
| **reset.sh**                | 8-stufiger interaktiver Reset für Neu-Tests und Deinstallation               |
| **docker-compose.yml**      | Fertig konfigurierter Stack: wireguard-ui + ddns-go + Dashboard              |
| **Dokumentation (docs/)**   | Schritt-für-Schritt-Anleitungen für alle Komponenten                         |

### Architektur im Überblick

```
Nebenwohnsitz                          Hauptwohnsitz
─────────────────────────────────────  ────────────────────────────
Raspberry Pi (WireGuard-SERVER)        OPNsense (WireGuard-CLIENT)
  • wireguard-ui (Docker, Port 5000)     • os-wireguard Plugin
  • ddns-go     (Docker, Port 9876)      • VPN-IP: 10.10.0.3/24
  • VPN-IP: 10.10.0.1/24                • LAN: <HAUPT-LAN>
  • LAN: <NEBEN-LAN>
  • DDNS → vpn.deine-domain.de (AAAA)

         ◄══ WireGuard Tunnel über IPv6 (MTU 1420, Keepalive 25s) ══►
              OPNsense verbindet aktiv outbound (Starlink blockiert inbound!)
```

### Wofür eignet sich PI-VPN?

- **Fernzugriff auf das Heimnetz** — auf NAS, Drucker, Smarthome-Geräte am Hauptwohnsitz zugreifen
- **Gemeinsames Netzwerk** — Geräte an beiden Standorten kommunizieren direkt miteinander
- **Streaming via Starlink** — Full-Tunnel-Modus leitet den gesamten Datenverkehr am Nebenwohnsitz durch den Heimanschluss
- **Sicherer Kanal** — verschlüsseltes WireGuard-Protokoll, keine dritten Parteien (kein Cloud-VPN)

### Voraussetzungen auf einen Blick

| Was                     | Anforderung                                                   |
|-------------------------|---------------------------------------------------------------|
| Hauptwohnsitz           | OPNsense ≥ 21.7 mit `os-wireguard`-Plugin (Client-Modus)     |
| Nebenwohnsitz           | Raspberry Pi 4 oder 5, Raspberry Pi OS Bookworm 64-bit        |
| Internetzugang          | IPv6 an beiden Standorten (CGNAT/DS-Lite kein Problem)        |
| DDNS                    | Cloudflare (empfohlen) oder anderer Anbieter mit AAAA-Support — läuft auf dem Raspi via ddns-go |
| GitHub-Zugang           | Fine-grained Token mit Read-Zugriff auf dieses Repo           |

---

## Netzwerkübersicht

```
┌──────────────────────────────────────────────────────┐
│              NEBENWOHNSITZ                           │
│  Vodafone Kabel (DS-Lite, IPv6 nativ)                │
│       │                                              │
│   Fritzbox 6660 → LAN <NEBEN-LAN>                    │
│       │                                              │
│   Raspberry Pi  ← EINZIGER RASPI                     │
│   [wireguard-ui — SERVER]  VPN-IP: 10.10.0.1         │
│   [ddns-go]  → vpn.deine-domain.de (AAAA)            │
│                                                      │
│       ⬆ WireGuard Tunnel über IPv6 (UDP 51820)      │
│         OPNsense verbindet aktiv outbound            │
└─────────────────────┬────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────┐
│              HAUPTWOHNSITZ                           │
│  Starlink (CGNAT IPv4, IPv6 nativ)                   │
│  ⚠️ Blockiert eingehende IPv6 → OPNsense muss Client  │
│       │                                              │
│   OPNsense                                           │
│   ├── WireGuard-Plugin (CLIENT, verbindet outbound)  │
│   ├── KEIN eigenes DDNS (Services hat keinen Dienst) │
│   └── LAN <HAUPT-LAN>      VPN-IP: 10.10.0.3         │
│                                                      │
│   Handy (WireGuard-Client, 10.10.0.2/32)             │
└──────────────────────────────────────────────────────┘
```
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

| Container       | Image                          | Funktion                               |
|----------------|-------------------------------|----------------------------------------|
| `wireguard-ui` | `ngoduykhanh/wireguard-ui`    | WireGuard-Server-Verwaltung + WebUI    |
| `ddns-go`      | `jeessy/ddns-go`              | IPv6-DDNS-Updater (AAAA-Record)        |
| `dashboard`    | lokal gebaut (Flask/Alpine)   | Echtzeit-Monitoring-Dashboard :8080    |

---

## Verzeichnisstruktur

```
PI-VPN/
├── README.md
├── menu.sh                         # ← Zentrales Menü (TUI) — hier starten!
├── docker/
│   └── nebenwohnsitz/
│       ├── docker-compose.yml      # Einziger Docker-Stack (Raspi)
│       ├── .env.example            # Umgebungsvariablen (inkl. NC_* für Nextcloud)
│       └── dashboard/              # Echtzeit-Dashboard (Flask, Port 8080)
│           ├── app.py
│           ├── Dockerfile
│           └── static/index.html
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
    │   ├── install-dashboard.sh    # Dashboard separat nachinstallieren
    │   └── init.sh                 # Erstkonfiguration
    └── manage/
        ├── status.sh               # VPN-Status anzeigen
        ├── backup.sh               # Konfig-Backup + Nextcloud-Upload
        ├── restore.sh              # Backup-Wiederherstellung
        └── reset.sh                # Interaktiver Reset / Deinstallation
```

---

## Schnellstart

### 1. OPNsense (Hauptwohnsitz) — WireGuard-Server einrichten
Siehe → [docs/OPNsense-WireGuard.md](docs/OPNsense-WireGuard.md)
- WireGuard-Plugin aktivieren, Schlüsselpaar generieren
- Peer `nebenwohnsitz` anlegen
- Dynamisches DNS einrichten (AAAA-Record)

### 2. Raspberry Pi (Nebenwohnsitz) — Installation

#### Option A — git clone (empfohlen)

```bash
# Repo klonen (kein Token nötig, da public)
sudo git clone https://github.com/ReXx09/PI-VPN.git /opt/pi-vpn

# Zentrales Menü starten — grafische TUI-Oberfläche für alle Funktionen
cd /opt/pi-vpn
sudo bash menu.sh
```

#### Option B — ZIP-Download (ohne git)

```bash
# Aktuelles Release als ZIP herunterladen und entpacken
cd /tmp
wget https://github.com/ReXx09/PI-VPN/archive/refs/tags/v1.1.0.tar.gz
sudo mkdir -p /opt/pi-vpn
sudo tar -xzf v1.1.0.tar.gz --strip-components=1 -C /opt/pi-vpn

# Zentrales Menü starten
cd /opt/pi-vpn
sudo bash menu.sh
```

Das **zentrale Menü** (`menu.sh`) bietet eine grafische Terminal-Oberfläche (TUI)
mit allen Funktionen auf einen Blick:

| Menüpunkt                    | Funktion                                                          |
|------------------------------|-------------------------------------------------------------------|
| [1] Setup & Installation     | Wizard, Docker, Dashboard, Verzeichnisse anlegen                  |
| [2] Status & Monitoring      | VPN-Status, Container-Logs, wg show, Routing, Restore            |
| [3] VPN-Dienste verwalten    | Start/Stop/Restart, Dashboard neu bauen, Live-Logs                |
| [4] Konfiguration & Updates  | .env bearbeiten, git pull, Systeminformationen                    |
| [5] Reset & Deinstallation   | Interaktiver Komplett-Reset für Neu-Tests                         |
| [6] WebUI-Adressen           | Direkte Links zu wireguard-ui, ddns-go, Dashboard                 |
| [7] Diagnose & Tools         | 11-Stufen-Autofix, Handshake, DNS, IPv6, Ping, tcpdump            |
| [8] Backup & Wiederherstellen| Backup erstellen, Nextcloud-Upload konfigurieren, Restore         |

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

---

## Projekt unterstützen

PI-VPN ist ein privates Open-Source-Projekt, das in meiner Freizeit entwickelt und gepflegt wird.
Wenn dir das Projekt geholfen hat, deinen Standorten ein funktionierendes VPN ohne öffentliche IPv4 zu geben — freue ich mich sehr über eine kleine Unterstützung! 🙌

> **Hinweis:** Der offizielle „Sponsor"-Button von GitHub erscheint erst nach Genehmigung durch das **GitHub Sponsors Programm** (Bewerbung läuft). Bis dahin kannst du das Projekt auf folgenden Wegen unterstützen:

### Wie du helfen kannst

| Weg                    | Beschreibung                                                                 |
|------------------------|------------------------------------------------------------------------------|
| ⭐ **GitHub Star**      | Kostenlos & hilfreich — gibt dem Projekt Sichtbarkeit auf GitHub             |
| 🍴 **Fork & Contribute**| Verbesserungen, Bugfixes oder neue Features als Pull Request einreichen      |
| 🐛 **Issue melden**    | Fehler oder Verbesserungsvorschläge im [Issue-Tracker](https://github.com/ReXx09/PI-VPN/issues) melden |
| 💬 **Weiterempfehlen** | Das Projekt in Foren, Reddit oder Discord teilen                             |

### Warum deine Unterstützung wichtig ist

- Entwicklung & Pflege kostet Zeit — jeder Stern motiviert weiter
- Mehr Aufmerksamkeit → mehr Feedback → besseres Projekt für alle
- Dieses Projekt löst ein reales Problem (CGNAT / DS-Lite) für viele Menschen

---

*'' Dies ist ein persönliches Projekt und für hilfreiche Tipps und Ideen natürlich offen ''*
*'' Ich weiß um die Problematik mit CG-NAT und DS-Lite und hoffe, mit diesem Projekt euch etwas helfen zu können ''*
