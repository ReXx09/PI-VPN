# PI-VPN — Site-to-Site WireGuard über IPv6

Raspberry Pi basiertes Site-to-Site VPN zwischen zwei Standorten mit **CGNAT/DS-Lite-kompatiblem IPv6-Tunnel**.

---

## Netzwerkübersicht

```
┌─────────────────────────────────────────────────────┐
│              HAUPTWOHNSITZ                          │
│  Starlink (CGNAT) → OPNsense → LAN 192.168.10.0/24 │
│                          │                          │
│                    Raspberry Pi                     │
│              [wireguard-ui] [ddns-go]               │
│               WireGuard-Server  :51820              │
│                VPN-IP: 10.10.0.1                    │
└────────────────────┬────────────────────────────────┘
                     │  WireGuard Tunnel
                     │  über IPv6 (AAAA)
                     │  (kein öffentl. IPv4 nötig!)
┌────────────────────┴────────────────────────────────┐
│              NEBENWOHNSITZ                          │
│  Vodafone Kabel (DS-Lite) → Fritzbox 6660 →        │
│                          LAN 192.168.20.0/24        │
│                          │                          │
│                    Raspberry Pi                     │
│              [wireguard-client] [ddns-go]           │
│                VPN-IP: 10.10.0.2                    │
└─────────────────────────────────────────────────────┘
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

## Docker-Stack

### Hauptwohnsitz (WireGuard-Server)

| Container       | Image                          | Funktion                          |
|----------------|-------------------------------|-----------------------------------|
| `wireguard-ui`  | `ngoduykhanh/wireguard-ui`    | WireGuard-Verwaltung (WebUI)      |
| `ddns-go`       | `jeessy/ddns-go`              | IPv6-DDNS-Updater                 |

### Nebenwohnsitz (WireGuard-Client)

| Container       | Image                          | Funktion                          |
|----------------|-------------------------------|-----------------------------------|
| `wireguard`     | `linuxserver/wireguard`       | WireGuard-Client                  |
| `ddns-go`       | `jeessy/ddns-go`              | IPv6-DDNS-Updater (opt.)          |

---

## Verzeichnisstruktur

```
PI-VPN/
├── README.md
├── docker/
│   ├── hauptwohnsitz/
│   │   ├── docker-compose.yml      # Server-Stack
│   │   └── .env.example            # Umgebungsvariablen
│   └── nebenwohnsitz/
│       ├── docker-compose.yml      # Client-Stack
│       └── .env.example
├── config/
│   ├── server/
│   │   └── wg0.conf.example        # WireGuard Server-Konfig
│   └── clients/
│       └── nebenwohnsitz.conf.example  # Peer-Konfig
├── docs/
│   ├── Netzwerkuebersicht.md       # Detaillierte Netzwerkplanung
│   ├── Setup-Anleitung.md          # Schritt-für-Schritt Guide
│   ├── OPNsense-Setup.md           # Firewall-Regeln Hauptwohnsitz
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

### 1. Raspi vorbereiten (beide Standorte)
```bash
cd /opt
sudo git clone <dieses-repo> pi-vpn
cd pi-vpn
sudo bash scripts/setup/install-docker.sh
```

### 2. Hauptwohnsitz starten
```bash
cp docker/hauptwohnsitz/.env.example docker/hauptwohnsitz/.env
nano docker/hauptwohnsitz/.env      # Passwörter & DNS-Token setzen
cd docker/hauptwohnsitz
sudo docker compose up -d
# WebUI: http://<raspi-ip>:5000
# DDNS-UI: http://<raspi-ip>:9876
```

### 3. Nebenwohnsitz starten
```bash
cp docker/nebenwohnsitz/.env.example docker/nebenwohnsitz/.env
nano docker/nebenwohnsitz/.env
# WireGuard-Konfig aus der WebUI exportieren und nach
# /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf kopieren
cd docker/nebenwohnsitz
sudo docker compose up -d
```

---

## Streaming-Dienste (Split-Tunnel)

Um Streaming-Dienste vom Hauptwohnsitz auch am Nebenwohnsitz zu nutzen:
- Variante A: **Full-Tunnel** → alle Geräte routen via VPN (`AllowedIPs = 0.0.0.0/0, ::/0`)
- Variante B: **Split-Tunnel** → nur Heimnetz erreichbar, Streaming manuell per Proxy/DNS

Details → [docs/Setup-Anleitung.md](docs/Setup-Anleitung.md)

---

## Anforderungen

- Raspberry Pi 4 (oder 5) mit Raspberry Pi OS Bookworm (64-bit)
- Docker ≥ 24.x & Docker Compose ≥ 2.x
- DDNS-Provider mit AAAA-Unterstützung (z. B. Cloudflare, DeSEC, Duck DNS)
- IPv6 am Standort aktiv und per DDNS auflösbar
