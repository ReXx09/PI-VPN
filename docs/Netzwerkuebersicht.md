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
│        │                                           │                               │
│   OPNsense Router                           Fritzbox 6660                          │
│   WAN: 2001:db8:A::/64                      WAN: 2001:db8:B::/64                  │
│   LAN: 192.168.10.0/24                      LAN: 192.168.20.0/24                  │
│        │                                           │                               │
│   ─────┼─────────────────────────────────────────┼──                              │
│        │                                           │                               │
│   Raspberry Pi #1 (Server)                  Raspberry Pi #2 (Client)              │
│   LAN: 192.168.10.50                        LAN: 192.168.20.50                    │
│   IPv6: 2001:db8:A::50   ◄══WG-Tunnel══►   IPv6: 2001:db8:B::50                 │
│   VPN:  10.10.0.1/24       UDP 51820         VPN:  10.10.0.2/24                  │
│                             via IPv6                                               │
│   [wireguard-ui :5000]                      [wireguard-client]                    │
│   [ddns-go      :9876]                      [ddns-go :9876]                       │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

---

## IP-Adressplan

### VPN-Subnetz (WireGuard-Tunnel)

| Rolle              | Hostname               | VPN-IP     |
|--------------------|------------------------|------------|
| Server (Haupt.)    | wg-server              | 10.10.0.1  |
| Client (Neben.)    | wg-nebenwohnsitz       | 10.10.0.2  |
| (Reserve)          | weitere Clients/Geräte | 10.10.0.3+ |

### Heimnetze (LAN)

| Standort       | Subnetz              | Router-IP      | Raspi-IP          |
|----------------|----------------------|----------------|-------------------|
| Hauptwohnsitz  | 192.168.10.0/24      | 192.168.10.1   | 192.168.10.50     |
| Nebenwohnsitz  | 192.168.20.0/24      | 192.168.20.1   | 192.168.20.50     |

> **Hinweis:** Passe diese Adressen an dein tatsächliches Heimnetz an.  
> OPNsense nutzt oft `192.168.1.0/24`, Fritzbox `192.168.178.0/24`.

### DDNS-Hostnamen

| Standort       | DDNS-Hostname              | Record-Typ | Aktualisiert durch |
|----------------|----------------------------|------------|--------------------|
| Hauptwohnsitz  | `vpn-home.deine-domain.de` | AAAA       | ddns-go (Raspi #1) |
| Nebenwohnsitz  | `vpn-neben.deine-domain.de`| AAAA       | ddns-go (Raspi #2) |

---

## Ports & Dienste

| Dienst         | Port  | Protokoll | Standort        | Erreichbar von         |
|----------------|-------|-----------|-----------------|------------------------|
| WireGuard      | 51820 | UDP       | Hauptwohnsitz   | Internet (IPv6)        |
| wireguard-ui   | 5000  | TCP       | Hauptwohnsitz   | LAN (nur intern)       |
| ddns-go WebUI  | 9876  | TCP       | beide           | LAN (nur intern)       |

> **Sicherheit:** wireguard-ui und ddns-go niemals direkt ins Internet freigeben!

---

## IPv6-Routing

### Warum nur IPv6?

```
IPv4-Situation:
  Starlink → CGNAT → OPNsense → Raspi
             ↑ Kein öffentliches IPv4!
             Portforwarding von außen nicht möglich.

  Vodafone Kabel → DS-Lite CGN → Fritzbox → Raspi
                   ↑ Ebenfalls kein öffentliches IPv4!

IPv6-Situation:
  Starlink → öffentliches /56 Prefix → OPNsense → Raspi bekommt globale IPv6
  Vodafone → öffentliches /60 Prefix → Fritzbox → Raspi bekommt globale IPv6
                                 ↑ DIREKT erreichbar!
```

### DDNS-Go — Warum zwingend?

IPv6-Prefixes von Starlink und Vodafone sind **dynamisch** — sie wechseln regelmäßig.
ddns-go überwacht das Interface und aktualisiert den DNS-AAAA-Record sofort bei Änderung.

WireGuard löst den DNS-Namen beim Start auf. Ändert sich die IP, muss der Tunnel
neu gestartet werden (ddns-go kann via Webhook oder Cron den Neustart triggern).

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
