# OPNsense WireGuard-Plugin — Hauptwohnsitz (Server)

OPNsense übernimmt die Server-Rolle vollständig über das **native WireGuard-Plugin**.
**Kein Raspberry Pi am Hauptwohnsitz nötig.**

---

## Voraussetzung: WireGuard-Plugin installieren

**OPNsense → System → Plugins**

→ `os-wireguard` suchen → **[+] Installieren** → danach OPNsense neu starten.

---

## Schritt 1 — Dynamisches DNS einrichten (IPv6 / AAAA)

Da Starlink ein dynamisches IPv6-Prefix vergibt muss der AAAA-Record automatisch aktualisiert werden.

**OPNsense → Dienste → Dynamisches DNS → [+] Hinzufügen**

| Feld            | Wert                                             |
|----------------|--------------------------------------------------|
| Dienst         | Cloudflare (oder DeSEC / Duck DNS)               |
| Interface      | WAN                                              |
| Hostname       | `vpn-home.deine-domain.de`                       |
| Token/Passwort | Cloudflare API-Token (DNS:Edit-Berechtigung)     |
| Protokoll      | **IPv6 (AAAA)**                                  |
| Intervall      | 5 Minuten                                        |

→ **Speichern** → **Einmalig aktualisieren** klicken und AAAA-Record prüfen.

> **Cloudflare Token erstellen:** dash.cloudflare.com → Profil → API-Token → Token erstellen → Vorlage "Zone DNS bearbeiten" → nur deine Zone wählen.

---

## Schritt 2 — WireGuard-Server konfigurieren

**OPNsense → VPN → WireGuard → Lokal → [+] Hinzufügen**

| Feld               | Wert                                     |
|-------------------|------------------------------------------|
| Name              | `wg-server`                              |
| Listen-Port       | `51820`                                  |
| Tunnel-Adressen   | `10.10.0.1/24`                           |
| MTU               | `1280` (Starlink IPv6 — verhindert Fragmentierung) |
| DNS               | `192.168.10.1` (OPNsense selbst als DNS) |

Schlüsselpaar wird automatisch generiert → **Speichern**.

---

## Schritt 3 — Peer (Nebenwohnsitz-Raspi) anlegen

Der Public Key des Raspi wird nach Schritt 4 hier eingetragen.

**OPNsense → VPN → WireGuard → Endpunkte → [+] Hinzufügen**

| Feld               | Wert                                          |
|-------------------|-----------------------------------------------|
| Name              | `nebenwohnsitz`                               |
| Öffentl. Schlüssel| (Public Key des Raspi — nach Schritt 4)       |
| Erlaubte IPs      | `10.10.0.2/32, 192.168.20.0/24`              |
| Keepalive         | `25`                                          |
| Endpunkt-Host     | (leer lassen — Client stellt Verbindung her) |

→ **Speichern**

---

## Schritt 4 — Public Key des Raspi ermitteln

Der `linuxserver/wireguard` Container generiert beim ersten Start automatisch ein Schlüsselpaar.

```bash
# Auf dem Raspberry Pi (nach erstem docker compose up -d):
sudo docker exec wireguard-client cat /config/wg_confs/wg0.conf | grep PrivateKey
# oder direkt den Public Key:
sudo docker exec wireguard-client sh -c "wg pubkey < /config/privatekey"
```

→ Diesen Public Key in OPNsense → Endpunkte → nebenwohnsitz eintragen.

---

## Schritt 5 — WireGuard aktivieren

**OPNsense → VPN → WireGuard → Allgemein**

→ **WireGuard aktivieren** ✅ → **Speichern & Anwenden**

---

## Schritt 6 — Firewall-Regeln

### WAN: UDP 51820 eingehend erlauben

**OPNsense → Firewall → Regeln → WAN → [+] Hinzufügen**

| Feld      | Wert                              |
|-----------|-----------------------------------|
| Aktion    | Passieren                         |
| Interface | WAN                               |
| Protokoll | UDP                               |
| Quelle    | Beliebig                          |
| Ziel      | WAN-Adresse                       |
| Port      | `51820`                           |

> Für IPv4 (CGNAT): **nicht möglich** — ausschließlich IPv6 nutzen.

### WireGuard-Interface: Traffic erlauben

**OPNsense → Firewall → Regeln → WireGuard (wg0) → [+] Hinzufügen**

| Feld      | Wert      |
|-----------|-----------|
| Aktion    | Passieren |
| Protokoll | Beliebig  |
| Quelle    | Beliebig  |
| Ziel      | Beliebig  |

---

## Schritt 7 — Client-Konfig für den Raspi exportieren

**OPNsense → VPN → WireGuard → Lokal** → `wg-server` → **"Clients"** → `nebenwohnsitz` → **Download**

Die heruntergeladene `wg0.conf` auf dem Raspi ablegen:

```bash
# Auf dem Raspberry Pi:
mkdir -p /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard
# conf-Datei kopieren (scp, USB-Stick, etc.)
cp wg0.conf /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf
```

---

## Schritt 8 — Statische Route für Nebenwohnsitz-LAN

**OPNsense → System → Routen → Statische Routen**

| Netzwerk           | Gateway                                      |
|-------------------|----------------------------------------------|
| `10.10.0.0/24`    | WireGuard-Interface (nach Aktivierung wählbar)|
| `192.168.20.0/24` | WireGuard-Interface                          |

---

## Verifikation

```bash
# Auf dem Raspi (nach dem Verbinden):
ping 10.10.0.1          # OPNsense WireGuard-Interface
ping 192.168.10.1       # OPNsense LAN-Gateway

# In OPNsense → VPN → WireGuard → Status:
# Peer nebenwohnsitz sollte "latest handshake: X seconds ago" zeigen
```
