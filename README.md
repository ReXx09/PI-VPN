# PI-VPN — Site-to-Site WireGuard über IPv6

Raspberry Pi basiertes Site-to-Site VPN zwischen zwei Standorten mit **CGNAT/DS-Lite-kompatiblem IPv6-Tunnel**.

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
│   ├── Netzwerkuebersicht.md       # Detaillierte Netzwerkplanung
│   ├── Setup-Anleitung.md          # Schritt-für-Schritt Guide
│   ├── OPNsense-WireGuard.md       # WireGuard-Plugin in OPNsense
│   └── Fritzbox-IPv6-Setup.md      # IPv6-Freigabe Nebenwohnsitz
└── scripts/
    ├── setup/
    │   ├── install-docker.sh       # Docker auf Raspberry Pi installieren
    │   └── init.sh                 # Erstkonfiguration
    └── manage/
        ├── status.sh               # VPN-Status anzeigen
        └── backup.sh               # Konfig-Backup
```

---

## Schnellstart

### 1. OPNsense (Hauptwohnsitz) — WireGuard-Server einrichten
Siehe → [docs/OPNsense-WireGuard.md](docs/OPNsense-WireGuard.md)
- WireGuard-Plugin aktivieren, Schlüsselpaar generieren
- Peer `nebenwohnsitz` anlegen
- Dynamisches DNS einrichten (AAAA-Record)

### 2. Raspberry Pi (Nebenwohnsitz) — Interaktiver Installer

```bash
# Repo klonen
cd /opt
sudo git clone https://github.com/ReXx09/PI-VPN.git pi-vpn

# Wizard starten — führt durch alles
cd pi-vpn
sudo bash scripts/setup/setup-wizard.sh
```

Der Wizard installiert Docker, fragt alle Einstellungen ab, generiert die `.env`
und startet die Container. Am Ende bekommst du genaue Anweisungen für die
wireguard-ui WebUI (welche Werte wo einzutragen sind).

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
