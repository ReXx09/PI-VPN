# Fritzbox 6660 Cable — IPv6-Setup (Nebenwohnsitz)

## Situation

**Vodafone Kabel mit DS-Lite:**
- Kein öffentliches IPv4 (RFC 1918 hinter CGN → kein Portforwarding IPv4 möglich)
- **Natives IPv6 vorhanden** (öffentliche /60 oder /56 Prefix-Delegation)

→ WireGuard funktioniert ausschließlich über IPv6.

---

## Schritt 1 — IPv6 in der Fritzbox aktivieren

**Fritzbox-Oberfläche:** `http://fritz.box`

→ **Heimnetz → Netzwerk → Registerkarte "IPv6"**

- **IPv6-Unterstützung aktivieren** ✅
- **DNS-Rebind-Schutz für IPv6 deaktivieren** (für VPN-DNS nötig) ✅
- Fritzbox delegiert IPv6-Prefixes an Heimnetzgeräte via SLAAC/DHCPv6

---

## Schritt 2 — Raspberry Pi mit fester IPv6 konfigurieren

### Option A: Stabile SLAAC-Adresse (empfohlen)

Privacy Extensions auf dem Raspi deaktivieren, damit die SLAAC-Adresse
vom MAC-Derivat abhängt (stabil über Reboots):

```bash
# Temporär (sofort wirksam):
sudo sysctl -w net.ipv6.conf.eth0.use_tempaddr=0

# Dauerhaft:
echo "net.ipv6.conf.eth0.use_tempaddr = 0" | sudo tee /etc/sysctl.d/99-no-tempaddr.conf
sudo sysctl --system
```

Danach die SLAAC-Adresse notieren:
```bash
ip -6 addr show eth0 | grep "scope global"
# Beispiel: 2a02:8071:xxxx:yyyy::1:50/64  ← diese Adresse merken
```

### Option B: DHCPv6 mit DUID (stabile Zuweisung via Fritzbox)

- Fritzbox → **Heimnetz → Netzwerk → Registerkarte "DHCP"**
- Gerät des Raspi suchen → **"Immer gleiche IPv6-Adresse zuweisen"** aktivieren

---

## Schritt 3 — IPv6-Portfreigabe für WireGuard

**Fritzbox → Internet → Freigaben → Portfreigaben**

→ **"Gerät für Freigaben hinzufügen"** → Raspberry Pi auswählen

| Feld                | Wert                        |
|---------------------|-----------------------------|
| Protokoll           | UDP                         |
| Port                | 51820                       |
| An Port             | 51820                       |
| IPv6-Gerät          | Raspberry Pi (Nebenwohnsitz)|
| Beschreibung        | WireGuard VPN               |

> **Hinweis:** Bei DS-Lite und aktiviertem IPv6 leitet die Fritzbox UDP 51820
> direkt an den Raspi weiter. Eine IPv4-Freigabe ist nicht möglich (DS-Lite).

---

## Schritt 4 — IPv6-Firewall der Fritzbox

Die Fritzbox 6660 hat eine eingebaute IPv6-Firewall. Seit Fritz!OS 7.x sind
**Portfreigaben für IPv6 aktiv** sobald der Schritt oben durchgeführt wurde.

Falls dennoch blockiert wird:
→ **Heimnetz → Netzwerk → Registerkarte "IPv6"**
→ **"Exposed Host für IPv6"** → Raspi auswählen (nur temporär zum Testen!)

---

## Schritt 5 — Statische Route für Hauptwohnsitz-LAN

Damit alle Fritzbox-Geräte das Hauptwohnsitz-LAN erreichen (nicht nur Raspi-Geräte):

**Fritzbox → Heimnetz → Netzwerk → Registerkarte "Statische Routen"**

| Feld         | Wert                                        |
|--------------|---------------------------------------------|
| IPv4-Netz    | `192.168.10.0` / `255.255.255.0`           |
| Gateway      | `192.168.20.50` (LAN-IP des Raspi)         |
| Beschreibung | Hauptwohnsitz via WireGuard                 |

| Feld         | Wert                                        |
|--------------|---------------------------------------------|
| IPv4-Netz    | `10.10.0.0` / `255.255.255.0`              |
| Gateway      | `192.168.20.50`                             |
| Beschreibung | WireGuard VPN-Subnetz                       |

---

## Schritt 6 — DDNS-Hostnamen testen

Der Nebenwohnsitz-Raspi muss den DDNS-Hostnamen des Hauptwohnsitzes auflösen können:

```bash
# Auf dem Nebenwohnsitz-Raspi:
nslookup -type=AAAA vpn-home.deine-domain.de
ping6 vpn-home.deine-domain.de
```

---

## Bekannte Probleme bei Vodafone DS-Lite

| Problem                              | Ursache                         | Lösung                              |
|-------------------------------------|---------------------------------|-------------------------------------|
| IPv6-Prefix wechselt täglich        | Vodafone Prefix-Rotation        | ddns-go greift das neue Prefix auf  |
| Kein IPv4-Portforwarding möglich    | DS-Lite CGN                     | Nur IPv6 verwenden (wie hier)       |
| WireGuard verbindet sich nicht      | Fritzbox-Firewall               | Schritte 3+4 erneut prüfen         |
| Raspi hat keine stabile IPv6        | Privacy Extensions aktiv        | Schritt 2 (use_tempaddr=0)          |

---

## Verifikation nach Setup

```bash
# Auf dem Nebenwohnsitz-Raspi:
sudo docker exec wireguard-client wg show

# Erwartete Ausgabe (Handshake und Traffic):
# peer: <SERVER_PUBLIC_KEY>
#   endpoint: [2001:db8:xxxx::1]:51820
#   latest handshake: 12 seconds ago
#   transfer: 1.23 MiB received, 456 KiB sent

# Ping zum Server-VPN-Interface:
ping 10.10.0.1

# Ping in das Hauptwohnsitz-LAN:
ping 192.168.10.1
```
