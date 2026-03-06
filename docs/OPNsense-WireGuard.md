# OPNsense WireGuard-Plugin — Hauptwohnsitz (Client)

OPNsense übernimmt die **Client-Rolle** im VPN. Der WireGuard-Server läuft auf dem **Raspberry Pi am Nebenwohnsitz**.

OPNsense verbindet sich aktiv nach außen zu `vpn.rexxlab.uk:51820` — Starlink blockiert ausgehende Verbindungen nicht.

> **Wichtig:** OPNsense hat **keinen eigenen DDNS-Dienst** (nicht in Services vorhanden). Das DDNS (`vpn.rexxlab.uk`) wird ausschließlich durch **ddns-go auf dem Raspberry Pi** aktualisiert.

---

## Netzwerk-Übersicht

| Standort | LAN | VPN-IP | Rolle |
|----------|-----|--------|-------|
| Nebenwohnsitz — Raspi | `192.168.20.0/24` | `10.10.0.1/24` | WireGuard Server |
| Hauptwohnsitz — OPNsense | `192.168.8.0/24` | `10.10.0.3/24` | WireGuard Client |
| Handy (Thomas-Handy) | — | `10.10.0.2/32` | WireGuard Client |

---

## Voraussetzung: WireGuard-Plugin installieren

**OPNsense → System → Plugins**

→ `os-wireguard` suchen → **[+] Installieren** → danach OPNsense neu starten.

---

## Schritt 1 — Public Key des Raspi ermitteln

Auf dem Raspberry Pi:

```bash
sudo wg show wg0 public-key
```

Diesen Public Key notieren — er wird in Schritt 3 (Peer) eingetragen.

---

## Schritt 2 — WireGuard Instance anlegen

**OPNsense → VPN → WireGuard → Instances → [+] Add**

| Feld | Wert |
|------|------|
| Enabled | ✅ |
| Name | `PIVPN` |
| Public key | *(Zahnrad-Icon klicken → Schlüsselpaar generieren)* |
| Private key | *(wird automatisch generiert)* |
| Listen port | *(leer lassen — OPNsense ist Client)* |
| MTU | `1420` |
| DNS servers | `192.168.8.1` *(OPNsense selbst)* |
| Tunnel address | `10.10.0.3/24` |
| Peers | *(nach Schritt 3 hier eintragen)* |
| Disable routes | ☐ |

→ **Save**

> **Hinweis:** Den generierten **Public Key der OPNsense-Instance** notieren — er muss in wireguard-ui auf dem Raspi als Peer eingetragen werden.

---

## Schritt 3 — Peer (Raspi) anlegen

**OPNsense → VPN → WireGuard → Peers → [+] Add**

| Feld | Wert |
|------|------|
| Enabled | ✅ |
| Name | `Raspi-Nebenwohnsitz` |
| Public key | *(Public Key des Raspi aus Schritt 1)* |
| Pre-shared key | *(optional — aus wireguard-ui kopieren falls gesetzt)* |
| Allowed IPs | `10.10.0.0/24, 192.168.20.0/24` |
| Endpoint address | `vpn.rexxlab.uk` |
| Endpoint port | `51820` |
| Instances | `PIVPN` *(die in Schritt 2 erstellte Instance)* |
| Keepalive interval | `25` |

→ **Save**

---

## Schritt 4 — Instance mit Peer verknüpfen

Zurück zu **VPN → WireGuard → Instances → PIVPN → Bearbeiten**

→ Im Feld **Peers** den soeben angelegten `Raspi-Nebenwohnsitz` auswählen → **Save**

---

## Schritt 5 — WireGuard aktivieren

**OPNsense → VPN → WireGuard → General**

→ **Enable WireGuard** ✅ → **Save**

---

## Schritt 6 — Interface zuweisen

**OPNsense → Interfaces → Assignments**

→ Neues Interface auf `wg1` zuweisen → **Add** → Interface öffnen:

| Feld | Wert |
|------|------|
| Enable Interface | ✅ |
| Description | `PIVPN` |
| Block private networks | ☐ |
| Block bogon networks | ☐ |
| IPv4 Configuration Type | `None` |
| IPv6 Configuration Type | `None` |

→ **Save** → **Apply changes**

---

## Schritt 7 — Firewall-Regel auf PIVPN-Interface

**OPNsense → Firewall → Rules → PIVPN → [+] Add**

| Feld | Wert |
|------|------|
| Action | `Pass` |
| Interface | `PIVPN` |
| Direction | `in` |
| TCP/IP Version | `IPv4` |
| Protocol | `any` |
| Source | `any` |
| Destination | `any` |
| Description | `VPN Traffic erlauben` |

→ **Save** → **Apply Changes**

> **Keine WAN-Regel nötig.** OPNsense baut die Verbindung selbst auf (outbound). Die Stateful Firewall lässt Return-Traffic automatisch durch.

---

## Schritt 8 — Raspi-Peer in wireguard-ui nachtragen

Auf dem Raspi in wireguard-ui (`http://<raspi-ip>:5000`):

**WireGuard Clients → + New Client**

| Feld | Wert |
|------|------|
| Name | `OPNsense-Hauptwohnsitz` |
| IP Allocation | `10.10.0.3/32` |
| Allowed IPs | `10.10.0.0/24, 192.168.8.0/24` |
| Public key | *(Public Key der OPNsense-Instance aus Schritt 2)* |
| Pre-shared key | *(falls in OPNsense gesetzt — hier identisch eintragen)* |

→ **Save** → **Apply Config**

---

## Verifikation

**In OPNsense → VPN → WireGuard → Status:**
- Instance `PIVPN` muss erscheinen
- Peer `Raspi-Nebenwohnsitz` sollte `latest handshake: X seconds ago` zeigen

**Auf dem Raspi:**
```bash
sudo wg show
# Peer OPNsense sollte latest handshake und transfer zeigen
```

**Ping-Test:**
```bash
# Vom Raspi → OPNsense VPN-IP:
ping 10.10.0.3

# Vom Raspi → Hauptwohnsitz LAN:
ping 192.168.8.1
```

---

## Bekannte Probleme

| Problem | Ursache | Lösung |
|---------|---------|--------|
| Kein Handshake | Starlink blockiert eingehend | OPNsense verbindet outbound — Keepalive 25s sicherstellt Verbindung |
| `vpn.rexxlab.uk` nicht auflösbar | DDNS nicht aktuell | ddns-go auf Raspi prüfen: `sudo docker logs ddns-go` |
| Traffic kommt nicht an | iptables auf Raspi fehlen | Post Up Script in wireguard-ui prüfen |
| OPNsense zeigt keine DDNS-Option | DDNS-Plugin nicht in OPNsense | Korrekt — DDNS läuft auf dem Raspi via ddns-go |
