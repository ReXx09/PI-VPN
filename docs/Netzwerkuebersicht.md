# Netzwerkübersicht — PI-VPN Site-to-Site

## Gesamtarchitektur

```
┌──────────────────────────────── INTERNET (IPv6) ──────────────────────────────────┐
│                                                                                    │
│   HAUPTWOHNSITZ                              NEBENWOHNSITZ                        │
│   ─────────────                              ───────────────                       │
│                                                                                    │
│   Starlink-Dish                              Vodafone Kabel                        │
│   (CGNAT IPv4,                               (DS-Lite IPv4,                        │
│    IPv6 nativ)                                IPv6 nativ)                          │
│   ⚠️ Blockiert eingehende                         │                               │
│      IPv6-Verbindungen!                     Fritzbox 6660                          │
│        │                                    WAN: 2a0d:3344:…/64                   │
│   OPNsense Router                           LAN: 192.168.20.0/24                  │
│   LAN: 192.168.8.0/24                             │                               │
│   VPN:  10.10.0.3/24                        Raspberry Pi (EINZIGER RASPI)          │
│   Rolle: WireGuard CLIENT                   LAN: 192.168.20.x                     │
│        │                                    IPv6: 2a0d:3344:1511:8400::…          │
│        │                                    VPN:  10.10.0.1/24                    │
│        │                                    Rolle: WireGuard SERVER               │
│        │                                    [wireguard-ui :5000]                  │
│        │                                    [ddns-go      :9876]                  │
│        │                                           │                               │
│        └──────────── WG-Tunnel ══════════════════►│                               │
│                      OPNsense verbindet outbound   │                               │
│                      via vpn.rexxlab.uk:51820      │                               │
│                      UDP 51820, IPv6               │                               │
│                                                                                    │
│   Thomas-Handy (Client)                                                            │
│   VPN: 10.10.0.2/32          ─────────────────────┘                              │
│   Allowed: 10.10.0.0/24, 192.168.8.0/24                                           │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

> **Warum OPNsense Client statt Server?**
> Starlink blockiert eingehende IPv6-Verbindungen (UDP 51820).
> OPNsense verbindet deshalb aktiv *outbound* zum Raspi am Nebenwohnsitz —
> ausgehende Verbindungen werden von Starlink nicht blockiert.
> Der Raspi (Nebenwohnsitz) hat über Vodafone/Fritzbox eine öffentlich erreichbare IPv6.

---

## IP-Adressplan

### VPN-Subnetz (WireGuard-Tunnel)

| Rolle                    | Gerät               | VPN-IP        |
|--------------------------|---------------------|---------------|
| **Server**               | Raspi (Nebenwohns.) | `10.10.0.1/24`|
| Client — Handy           | Thomas-Handy        | `10.10.0.2/32`|
| Client — Router          | OPNsense (Hauptwohns.) | `10.10.0.3/24`|

### Heimnetze (LAN)

| Standort       | Subnetz              | Router/Gateway    |
|----------------|----------------------|-------------------|
| Hauptwohnsitz  | `192.168.8.0/24`     | `192.168.8.1` (OPNsense) |
| Nebenwohnsitz  | `192.168.20.0/24`    | `192.168.20.1` (Fritzbox) |

### DDNS-Hostname

| Hostname         | Record | Wert                          | Pflegt           |
|------------------|--------|-------------------------------|------------------|
| `vpn.rexxlab.uk` | `AAAA` | `2a0d:3344:1511:8400::…`     | ddns-go (Raspi)  |

> **Wichtig:** Kein A-Record! Starlink vergibt nur CGNAT-IPv4 (`145.224.73.8`) —
> von außen nicht erreichbar. Der A-Record in ddns-go muss **deaktiviert** sein.

---

## Ports & Dienste

| Dienst         | Port  | Protokoll | Standort        | Erreichbar von         |
|----------------|-------|-----------|-----------------|------------------------|
| WireGuard      | 51820 | UDP       | **Nebenwohnsitz** (Raspi) | Internet (IPv6) |
| wireguard-ui   | 5000  | TCP       | Nebenwohnsitz   | LAN (nur intern)       |
| ddns-go WebUI  | 9876  | TCP       | Nebenwohnsitz   | LAN (nur intern)       |

> **Sicherheit:** wireguard-ui und ddns-go niemals direkt ins Internet freigeben!

---

## IPv6-Routing

### Warum nur IPv6?

```
IPv4-Situation:
  Starlink → CGNAT → OPNsense
             ↑ Kein öffentliches IPv4! Kein Portforwarding möglich.

  Vodafone Kabel → DS-Lite CGN → Fritzbox → Raspi
                   ↑ Ebenfalls kein öffentliches IPv4!

IPv6-Situation:
  Starlink → öffentl. /56 Prefix → OPNsense bekommt globale IPv6
             ABER: Starlink blockiert eingehende UDP (z. B. Port 51820)!
             → OPNsense MUSS als Client (outbound) verbinden.

  Vodafone → öffentl. /60 Prefix → Fritzbox → Raspi bekommt globale IPv6
             Fritzbox leitet UDP 51820 direkt zum Raspi → DIREKT erreichbar!
```

### DDNS-Go — Warum zwingend?

IPv6-Prefixes von Vodafone sind **dynamisch** — sie wechseln täglich.
ddns-go auf dem Raspi überwacht `eth0` und aktualisiert den AAAA-Record bei Änderung sofort.

OPNsense löst `vpn.rexxlab.uk` beim Verbindungsaufbau auf und verbindet direkt zur aktuellen IPv6.

---

## Traffic-Fluss (Streaming-Beispiel)

### Full-Tunnel (Variante B in der Client-Konfig)

```
Gerät am Nebenwohnsitz
        │ AllowedIPs: 0.0.0.0/0
        ▼
   Raspi #2 (Client)
        │ wg0 Tunnel
        ▼
   Raspi #1 (Server) — 10.10.0.1
        │ MASQUERADE (PostUp iptables)
        ▼
   OPNsense → Starlink → Netflix/ARD/ZDF/...
   (Streaming-Dienst sieht: Standort Deutschland / Hauptwohnsitz-Anschluss)
```

### Split-Tunnel (Variante A — Standard)

```
Gerät am Nebenwohnsitz:
  - Traffic zu 192.168.10.0/24 → durch Tunnel (Heimnetz erreichbar)
  - Traffic zu 10.10.0.0/24   → durch Tunnel (VPN-Geräte erreichbar)
  - Alles andere (YouTube, Social Media...) → direkt via Vodafone (schneller)
```

---

## Sicherheitshinweise

- Die `wg0.conf` enthält **private Schlüssel** — nie in Git committen (`.gitignore`!)
- Die `.env`-Dateien enthalten Passwörter — nie in Git committen
- wireguard-ui ist nur im LAN erreichbar (kein WAN-Forwarding auf Port 5000)
- WireGuard verschlüsselt den gesamten Tunnel-Traffic mit ChaCha20-Poly1305
- Peer-Keys regelmäßig rotieren (wireguard-ui unterstützt Key-Neugenerierung)
