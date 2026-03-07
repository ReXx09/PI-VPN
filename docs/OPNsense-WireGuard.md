# OPNsense WireGuard-Plugin — Hauptwohnsitz (Client)

OPNsense übernimmt die **Client-Rolle** im VPN. Der WireGuard-Server läuft auf dem **Raspberry Pi am Nebenwohnsitz**.

OPNsense verbindet sich aktiv nach außen zu `vpn.deine-domain.de:51820` — Starlink blockiert ausgehende Verbindungen nicht.

> **Wichtig:** OPNsense hat **keinen eigenen DDNS-Dienst** (nicht in Services vorhanden). Das DDNS (`vpn.deine-domain.de`) wird ausschließlich durch **ddns-go auf dem Raspberry Pi** aktualisiert.

---

## Netzwerk-Übersicht

| Standort | LAN | VPN-IP | Rolle |
|----------|-----|--------|-------|
| Nebenwohnsitz — Raspi | `<NEBEN-LAN>` | `10.10.0.1/24` | WireGuard Server |
| Hauptwohnsitz — OPNsense | `<HAUPT-LAN>` | `10.10.0.3/24` | WireGuard Client |
| Handy (Client) | — | `10.10.0.2/32` | WireGuard Client |

---

## Überblick: Ablauf in zwei Phasen

```
Phase 1 — Raspi (wireguard-ui):
  Client "OPNsense-Hauptwohnsitz" anlegen → .conf herunterladen
  → wireguard-ui generiert Schlüsselpaar und trägt Peer automatisch ein

Phase 2 — OPNsense:
  Werte aus der .conf in OPNsense Instance + Peer eintragen
  → kein manuelles Key-Handling, keine Hin-und-Her-Kopiererei
```

---

## Phase 1 — wireguard-ui auf dem Raspi

### Schritt 1 — WireGuard-Plugin in OPNsense installieren

**OPNsense → System → Plugins**

→ `os-wireguard` suchen → **[+] Installieren** → OPNsense neu starten.

*(Schon vor Phase 2 erledigen — der Neustart dauert)*

---

### Schritt 2 — OPNsense-Client in wireguard-ui anlegen

Öffne wireguard-ui auf dem Raspi: `http://<RASPI-LAN-IP>:5000`

**WireGuard Clients → + New Client**

| Feld | Wert | Erklärung |
|------|------|-----------|
| Name | `OPNsense-Hauptwohnsitz` | — |
| Email | *(leer lassen)* | — |
| IP Allocation | `10.10.0.3/32` | VPN-IP der OPNsense |
| Allowed IPs | `10.10.0.0/24, <NEBEN-LAN>` | Was OPNsense durch den Tunnel routen soll → VPN-Netz + **Neben**-LAN |
| Extra Allowed IPs | `<HAUPT-LAN>` | Damit der Raspi-Server Traffic ins Haupt-LAN zurück zu OPNsense routet |
| Use server DNS | ☐ | — |
| Enable after creation | ✅ | — |

→ **Submit**

> **Wichtig — Allowed IPs Logik:**
> - `Allowed IPs` → erscheint in der herunterladbaren `.conf` unter `[Peer] AllowedIPs` → steuert was OPNsense in den Tunnel schickt → muss das **Neben-LAN** enthalten
> - `Extra Allowed IPs` → wird in die Server-seitige `wg0.conf` eingetragen → steuert was der Raspi-Server zu OPNsense routet → muss das **Haupt-LAN** enthalten

---

### Schritt 3 — Konfiguration herunterladen & Config anwenden

1. In der Client-Liste den Eintrag `OPNsense-Hauptwohnsitz` suchen
2. Auf das **Download-Icon** klicken → `.conf`-Datei wird heruntergeladen
3. Oben rechts → **Apply Config** klicken (damit der neue Peer auf dem Raspi aktiv wird)

Die `.conf`-Datei sieht ungefähr so aus — **diese Werte brauchst du für Phase 2:**

```ini
[Interface]
Address    = 10.10.0.3/24
PrivateKey = <OPNSENSE-PRIVATE-KEY>          ← in OPNsense Instance eintragen
DNS        = 1.1.1.1

[Peer]
PublicKey           = <RASPI-SERVER-PUBLIC-KEY>   ← in OPNsense Peer eintragen
PresharedKey        = <PRESHARED-KEY>             ← falls vorhanden
AllowedIPs          = 10.10.0.0/24, <HAUPT-LAN>
Endpoint            = vpn.deine-domain.de:51820
PersistentKeepalive = 25
```

> **Hinweis:** OPNsense hat keinen `.conf`-Import-Button. Die Datei dient als Spickzettel — du überträgst die Werte manuell in die GUI-Felder.

---

## Phase 2 — OPNsense konfigurieren

### Schritt 4 — WireGuard Instance anlegen

**OPNsense → VPN → WireGuard → Instances → [+] Add**

| Feld | Wert | Quelle |
|------|------|--------|
| Enabled | ✅ | — |
| Name | `PIVPN` | — |
| Private key | *(aus `.conf` → `PrivateKey`)* | .conf `[Interface]` |
| Public key | *(wird automatisch berechnet — kein Eintrag nötig)* | — |
| Listen port | *(leer lassen — OPNsense ist Client)* | — |
| MTU | `1420` | — |
| DNS servers | *(leer lassen — OPNsense ist Router, kein DNS-Client)* | — |
| Tunnel address | `10.10.0.3/24` | .conf `Address` |
| Peers | *(nach Schritt 5 hier eintragen)* | — |
| Disable routes | ☐ | — |

→ **Save**

---

### Schritt 5 — Peer (Raspi-Server) anlegen

**OPNsense → VPN → WireGuard → Peers → [+] Add**

| Feld | Wert | Quelle |
|------|------|--------|
| Enabled | ✅ | — |
| Name | `Raspi-Nebenwohnsitz` | — |
| Public key | *(aus `.conf` → `PublicKey`)* | .conf `[Peer]` |
| Pre-shared key | *(aus `.conf` → `PresharedKey`, falls vorhanden)* | .conf `[Peer]` |
| Allowed IPs | `10.10.0.0/24, <NEBEN-LAN>` | — |
| Endpoint address | `vpn.deine-domain.de` | .conf `Endpoint` |
| Endpoint port | `51820` | .conf `Endpoint` |
| Instances | `PIVPN` | — |
| Keepalive interval | `25` | .conf `PersistentKeepalive` |

→ **Save**

---

### Schritt 6 — Instance mit Peer verknüpfen

**VPN → WireGuard → Instances → PIVPN → Bearbeiten**

→ Im Feld **Peers** den soeben angelegten `Raspi-Nebenwohnsitz` auswählen → **Save**

---

### Schritt 7 — WireGuard aktivieren

**OPNsense → VPN → WireGuard → General**

→ **Enable WireGuard** ✅ → **Save**

---

### Schritt 8 — Interface zuweisen

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

### Schritt 9 — Firewall-Regel auf PIVPN-Interface

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
ping <HAUPT-GW>
```

---

## Bekannte Probleme

| Problem | Ursache | Lösung |
|---------|---------|--------|
| Kein Handshake | Starlink blockiert eingehend | OPNsense verbindet outbound — Keepalive 25s stellt Verbindung sicher |
| `vpn.deine-domain.de` nicht auflösbar | DDNS nicht aktuell | ddns-go auf Raspi prüfen: `sudo docker logs ddns-go` |
| Traffic kommt nicht an | iptables auf Raspi fehlen | Post Up Script in wireguard-ui prüfen |
| OPNsense zeigt keine DDNS-Option | DDNS-Plugin nicht in OPNsense | Korrekt — DDNS läuft auf dem Raspi via ddns-go |
| Private Key wird nicht akzeptiert | Falsches Format | Aus der `.conf` kopieren — muss Base64-String sein (44 Zeichen) |
