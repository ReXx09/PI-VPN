# OPNsense-Setup — Hauptwohnsitz

## Ziel

Die OPNsense-Firewall muss:
1. Eingehende WireGuard-Verbindungen (IPv6, UDP 51820) zum Raspberry Pi durchlassen
2. Return-Traffic des VPN-Tunnels in das LAN routen
3. Das Nebenwohnsitz-LAN (`192.168.20.0/24`) über den Raspi erreichbar machen

---

## Netzwerktopologie

```
Starlink WAN (IPv6)
        │
   OPNsense
   ├── WAN: 2001:db8:xxxx::1/64  (Starlink IPv6, dynamisch)
   └── LAN: 192.168.10.1/24
              │
         Raspberry Pi (WireGuard-Server)
         LAN: 192.168.10.50/24   (statische LAN-IP!)
         IPv6: 2001:db8:xxxx::50  (stabiles Suffix mit SLAAC oder DHCPv6)
```

---

## Schritt 1 — Statische IPv6-Adresse für den Raspi

OPNsense → **Dienste → DHCPv6-Server**:
- Interface: LAN
- Einen statischen Host-Eintrag anlegen:
  - MAC-Adresse des Raspi
  - Festes IPv6-Suffix, z. B. `::50`

> Alternativ: Am Raspi `ip -6 addr` ausgeben und das Suffix der SLAAC-Adresse in OPNsense als statisch hinterlegen (Privacy Extensions deaktivieren: `sudo sysctl -w net.ipv6.conf.eth0.use_tempaddr=0`).

---

## Schritt 2 — IPv6-Firewall-Regel (WAN → Raspi)

OPNsense → **Firewall → Regeln → WAN**:

| Feld          | Wert                                              |
|---------------|---------------------------------------------------|
| Aktion        | Passieren                                         |
| Interface     | WAN                                               |
| Protokoll     | UDP                                               |
| Quelle        | Beliebig                                          |
| Ziel          | `[IPv6-Adresse des Raspi]` (z. B. `2001:db8::50`)|
| Ziel-Port     | `51820`                                           |
| Beschreibung  | WireGuard IPv6 eingehend                          |

> OPNsense blockiert standardmäßig eingehende WAN-Verbindungen — diese Regel ist zwingend erforderlich.

---

## Schritt 3 — NAT / Port-Weiterleitung (IPv4 optional)

Für **IPv6** ist kein NAT nötig, da jedes Gerät eine eigene öffentliche IPv6-Adresse erhält.  
Die oben angelegte Firewall-Regel genügt.

Für **IPv4 (CGNAT)**: Nicht möglich — daher ausschließlich IPv6 nutzen.

---

## Schritt 4 — Statische Route für Nebenwohnsitz-LAN

OPNsense → **System → Routen → Statische Routen**:

| Feld          | Wert                            |
|---------------|---------------------------------|
| Netzwerk      | `192.168.20.0/24`               |
| Gateway       | `192.168.10.50` (Raspi LAN-IP) |
| Beschreibung  | Nebenwohnsitz via WireGuard     |

| Feld          | Wert                            |
|---------------|---------------------------------|
| Netzwerk      | `10.10.0.0/24`                  |
| Gateway       | `192.168.10.50`                 |
| Beschreibung  | WireGuard VPN-Subnetz           |

---

## Schritt 5 — LAN-Firewall-Regel (Rückrichtung)

OPNsense → **Firewall → Regeln → LAN**:

| Feld          | Wert                                    |
|---------------|-----------------------------------------|
| Aktion        | Passieren                               |
| Quelle        | `192.168.20.0/24` (Nebenwohnsitz-LAN)  |
| Ziel          | `192.168.10.0/24` (Hauptwohnsitz-LAN) |
| Beschreibung  | VPN Site-to-Site Rückroute              |

---

## Schritt 6 — DNS-Weitergabe (optional, für Streaming)

OPNsense → **Dienste → Unbound DNS → Host-Overrides**:

Falls Streaming-Dienste per DNS gesteuert werden sollen:
- Überschreibe den FQDN des Streaming-Dienstes mit der jeweiligen IP

---

## Verifikation

```bash
# Von einem LAN-Gerät (Hauptwohnsitz):
ping 10.10.0.1      # WireGuard-Server
ping 10.10.0.2      # WireGuard-Client (Nebenwohnsitz)
ping 192.168.20.1   # Fritzbox am Nebenwohnsitz (wenn Route gesetzt)

# IPv6-Konnektivität des Raspi prüfen:
ping6 vpn-home.deine-domain.de
```
