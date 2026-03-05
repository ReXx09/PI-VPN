# PI-VPN — Schritt-für-Schritt Anleitung

**Ziel:** Site-to-Site VPN zwischen Hauptwohnsitz (Starlink + OPNsense) und
Nebenwohnsitz (Vodafone Kabel + Fritzbox 6660) über IPv6.

```
OPNsense (Hauptwohnsitz)  ◄══ WireGuard Tunnel (IPv6) ══►  Raspberry Pi (Nebenwohnsitz)
WireGuard-Server nativ                                        wireguard-ui + ddns-go
10.10.0.1                                                     10.10.0.2
```

---

> **Befehls-Referenz:** Alle Aktionen auch direkt ohne Menü aufrufbar →
> [Befehls-Referenz.md](Befehls-Referenz.md)

---

## Inhaltsverzeichnis

- [Überblick](#überblick-was-wird-wo-eingerichtet)
- **[Teil A — Hauptwohnsitz: OPNsense](#teil-a--hauptwohnsitz-opnsense-einrichten)**
  - [A1 — WireGuard-Plugin installieren](#a1--wireguard-plugin-installieren)
  - [A2 — Dynamisches DNS (AAAA)](#a2--dynamisches-dns-aaaa-einrichten)
  - [A3 — WireGuard-Server konfigurieren](#a3--wireguard-server-konfigurieren)
  - [A4 — Firewall-Regel UDP 51820](#a4--firewall-regel-wan--udp-51820)
  - [A5 — WireGuard aktivieren](#a5--wireguard-aktivieren)
  - [A6 — Peer vorbereiten](#a6--peer-nebenwohnsitz-vorbereiten)
  - [A7 — Statische Routen](#a7--statische-routen-für-das-nebenwohnsitz-lan)
- **[Teil B — Nebenwohnsitz: Raspberry Pi](#teil-b--nebenwohnsitz-raspberry-pi-einrichten)**
  - [B1 — Raspberry Pi OS installieren](#b1--raspberry-pi-os-installieren)
  - [B2 — GitHub Token erstellen](#b2--github-personal-access-token-erstellen)
  - [B3 — Repo klonen](#b3--projekt-auf-den-raspberry-pi-klonen)
  - [B4 — Zentrales Menü starten](#b4--zentrales-menü-starten)
  - [B5 — Public Key ermitteln](#b5--public-key-des-raspi-ermitteln)
- **[Teil C — wireguard-ui WebUI konfigurieren](#teil-c--wireguard-ui-webui-konfigurieren)**
  - [C1 — Server-Einstellungen prüfen](#c1--wireguard-server-einstellungen-prüfen)
  - [C2 — OPNsense als Peer eintragen](#c2--opnsense-als-peer-eintragen)
  - [C3 — Tunnelstatus prüfen](#c3--tunnelstatus-prüfen)
- **[Teil D — Fritzbox 6660 konfigurieren](#teil-d--fritzbox-6660-konfigurieren)**
  - [D1 — IPv6 aktivieren](#d1--ipv6-aktivieren)
  - [D2 — Portfreigabe für WireGuard](#d2--portfreigabe-für-wireguard)
  - [D3 — Statische Route (optional)](#d3--statische-route-optional-für-alle-fritzbox-geräte)
- **[Teil E — DDNS für den Raspberry Pi](#teil-e--ddns-für-den-raspberry-pi-nebenwohnsitz)**
  - [E1 — ddns-go WebUI öffnen](#e1--ddns-go-webui-öffnen)
  - [E2 — Konfigurieren](#e2--konfigurieren)
- **[Teil F — Verbindung testen](#teil-f--verbindung-vollständig-testen)**
  - [F1 — VPN-Tunnel](#f1--vpn-tunnel)
  - [F2 — Streaming-Test](#f2--streaming-test-full-tunnel)
  - [F3 — Nach einem Neustart](#f3--nach-einem-neustart)
- [Nützliche Befehle](#nützliche-befehle)
- [Häufige Probleme](#häufige-probleme)

---

## Überblick: Was wird wo eingerichtet?

| Standort       | Gerät          | Was                                          |
|----------------|----------------|----------------------------------------------|
| Hauptwohnsitz  | OPNsense       | WireGuard-Plugin, Dynamisches DNS (AAAA)     |
| Hauptwohnsitz  | Fritzbox/Router| –– (OPNsense übernimmt alles)                |
| Nebenwohnsitz  | Raspberry Pi   | Docker, wireguard-ui, ddns-go                |
| Nebenwohnsitz  | Fritzbox 6660  | IPv6 aktivieren, UDP 51820 freigeben         |

---

## Teil A — Hauptwohnsitz: OPNsense einrichten

> Detaillierte OPNsense-Anleitung: [OPNsense-WireGuard.md](OPNsense-WireGuard.md)

### A1 — WireGuard-Plugin installieren

1. OPNsense-WebUI öffnen (z. B. `https://192.168.10.1`)
2. **System → Plugins**
3. `os-wireguard` suchen → **[+]** klicken → installieren
4. OPNsense neu starten

### A2 — Dynamisches DNS (AAAA) einrichten

Starlink vergibt ein dynamisches IPv6-Prefix → DDNS sorgt dafür, dass der
Raspberry Pi am Nebenwohnsitz immer den aktuellen Hostnamen auflösen kann.

1. **Dienste → Dynamisches DNS → [+] Hinzufügen**

   | Feld        | Wert                                           |
   |-------------|------------------------------------------------|
   | Dienst      | Cloudflare                                     |
   | Interface   | WAN                                            |
   | Hostname    | `vpn-home.deine-domain.de`                     |
   | Token       | Cloudflare API-Token (DNS:Edit-Berechtigung)   |
   | Protokoll   | **IPv6 (AAAA)**                                |
   | Intervall   | 5 Minuten                                      |

2. **Speichern** → **„Einmalig aktualisieren"** klicken

3. Testen (von einem Gerät im Heimnetz oder online):
   ```
   nslookup -type=AAAA vpn-home.deine-domain.de
   ```
   → Eine IPv6-Adresse muss erscheinen, sonst weiter prüfen.

> **Cloudflare Token erstellen:**
> dash.cloudflare.com → Profil → API-Token → Token erstellen
> → Vorlage „Zone DNS bearbeiten" → nur deine Zone auswählen → Token kopieren

### A3 — WireGuard-Server konfigurieren

1. **VPN → WireGuard → Lokal → [+] Hinzufügen**

   | Feld             | Wert          |
   |-----------------|---------------|
   | Name            | `wg-server`   |
   | Listen-Port     | `51820`       |
   | Tunnel-Adressen | `10.10.0.1/24`|
   | MTU             | `1280`        |

   → **Speichern** (Schlüsselpaar wird automatisch generiert)

2. Öffentlichen Schlüssel notieren:
   **VPN → WireGuard → Lokal → wg-server** → Schlüssel anzeigen
   → Dieser Public Key wird später am Raspberry Pi eingetragen

### A4 — Firewall-Regel: WAN → UDP 51820

1. **Firewall → Regeln → WAN → [+] Hinzufügen**

   | Feld      | Wert         |
   |-----------|--------------|
   | Aktion    | Passieren    |
   | Protokoll | UDP          |
   | Ziel      | WAN-Adresse  |
   | Port      | `51820`      |

2. **Speichern & Anwenden**

### A5 — WireGuard aktivieren

**VPN → WireGuard → Allgemein → „WireGuard aktivieren" ✅ → Speichern & Anwenden**

### A6 — Peer (Nebenwohnsitz) vorbereiten

> ⚠️ Den Public Key des Raspi bekommst du erst nach dem Raspberry Pi Setup (Teil B).
> Lege den Peer-Eintrag jetzt schon an — den Public Key trägst du danach ein.

1. **VPN → WireGuard → Endpunkte → [+] Hinzufügen**

   | Feld             | Wert                              |
   |-----------------|-----------------------------------|
   | Name            | `nebenwohnsitz`                   |
   | Öffentl. Schlüssel | (wird nach Teil B eingetragen) |
   | Erlaubte IPs    | `10.10.0.2/32, 192.168.20.0/24`  |
   | Keepalive       | `25`                              |
   | Endpunkt-Host   | (leer — Client verbindet sich)    |

2. **Speichern**

### A7 — Statische Routen für das Nebenwohnsitz-LAN

**System → Routen → Statische Routen**

| Netzwerk           | Gateway            |
|--------------------|--------------------|
| `10.10.0.0/24`    | WireGuard-Interface|
| `192.168.20.0/24` | WireGuard-Interface|

---

## Teil B — Nebenwohnsitz: Raspberry Pi einrichten

### B1 — Raspberry Pi OS installieren

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) herunterladen
2. **Raspberry Pi OS Bookworm (64-bit, Lite)** wählen
3. Vor dem Flashen: Zahnrad-Symbol → SSH aktivieren, WLAN einrichten (optional)
4. SD-Karte flashen → in den Raspi einlegen → starten
5. Per SSH verbinden:
   ```bash
   ssh pi@<raspi-ip>
   # Standard-Passwort: raspberry  (sofort ändern mit: passwd)
   ```

### B2 — GitHub Personal Access Token erstellen

Da das Repository **privat** ist, brauchst du einen Token zum Klonen.

1. GitHub öffnen: **github.com → Dein Profil (oben rechts) → Settings**
2. Ganz unten links: **Developer settings**
3. **Personal access tokens → Fine-grained tokens → Generate new token**
4. Einstellungen:
   - Token name: `raspi-pi-vpn`
   - Expiration: nach Belieben (z. B. 90 Tage)
   - Repository access: **Only select repositories → PI-VPN**
   - Permissions → Repository permissions → **Contents: Read-only**
5. **Generate token** → Token kopieren und sicher aufbewahren

### B3 — Projekt auf den Raspberry Pi klonen

```bash
# Auf dem Raspberry Pi (via SSH):

# Schritt 1 — git installieren (auf frischem Raspberry Pi OS nicht vorinstalliert!)
sudo apt update && sudo apt install -y git

# Schritt 2 — Repo klonen
# ↓ DEIN_TOKEN durch den kopierten Token ersetzen (z. B. github_pat_11ABCDEF_...)
sudo git clone https://DEIN_TOKEN@github.com/ReXx09/PI-VPN.git /opt/pi-vpn
```

> **Beispiel** (echter Token sieht so aus):
> ```bash
> sudo git clone https://github_pat_11ABCDEF_xYz0123456789abcdef@github.com/ReXx09/PI-VPN.git /opt/pi-vpn
> ```
>
> **Achtung:** Den Token niemals mit Leerzeichen oder Anführungszeichen eingeben — direkt nahtlos im URL ersetzen.

### B4 — Zentrales Menü starten

Nach dem Klonen ist das **zentrale Menü** der empfohlene Einstiegspunkt für alle Aktionen:

```bash
sudo bash /opt/pi-vpn/menu.sh
```

Das Menü öffnet eine interaktive TUI-Oberfläche (erfordert `whiptail`, auf Raspberry Pi OS vorinstalliert):

```
+----------------------------------------------+
| PI-VPN | Zentrales Menue  | pi               |
|                                              |
|  1  [SETUP]      Setup & Installation        |
|  2  [STATUS]     Status & Monitoring         |
|  3  [CONTAINER]  Container-Verwaltung        |
|  4  [CONFIG]     Konfiguration & Updates     |
|  5  [RESET]      Reset & Deinstallation      |
|  6  [WEBUI]      WebUI-Adressen anzeigen     |
|  0  [X]          Beenden                    |
+----------------------------------------------+
```

**→ Wähle `1` (Setup & Installation) → `1` (Vollständige Installation)**

Der Wizard führt dich interaktiv durch:

| Schritt | Was passiert                                              |
|---------|-----------------------------------------------------------|
| 1       | Systemcheck: Kernel, WireGuard-Modul, wireguard-tools     |
| 2       | Docker CE installieren + IP-Forwarding setzen             |
| 3       | WebUI-Benutzername & Passwort festlegen                   |
| 4       | VPN-IP, MTU, DNS, LAN-Subnetz, Interface eingeben        |
| 5       | DDNS: optional aktivieren                                 |
| 6       | Zusammenfassung bestätigen → `.env` wird geschrieben      |
| 7       | Container starten → Anleitung für WebUI anzeigen          |

**Typische Eingaben im Wizard:**

| Frage                    | Antwort                                     |
|--------------------------|---------------------------------------------|
| Benutzername WebUI       | `admin`                                     |
| Passwort WebUI           | Eigenes sicheres Passwort (min. 12 Zeichen) |
| Tunnel-IP dieses Raspi   | `10.10.0.2/24`                              |
| MTU                      | `1280`                                      |
| DNS                      | `10.10.0.1,1.1.1.1`                         |
| LAN-Subnetz              | `192.168.20.0/24`  (dein Fritzbox-LAN)     |
| LAN-Interface            | `eth0`                                      |
| DDNS einrichten?         | `j`                                         |

### B5 — Public Key des Raspi ermitteln

Nach dem Wizard-Start gibt die WebUI den Public Key aus.
Alternativ direkt im Terminal:

```bash
# Warten bis Container läuft, dann:
sudo docker exec wireguard-ui wg show
# Zeile "public key: ..." kopieren

# Oder aus der generierten Konfig:
sudo cat /opt/pi-vpn/docker/nebenwohnsitz/data/wireguard/wg0.conf | grep -A1 "\[Interface\]"
```

→ Diesen Public Key jetzt in OPNsense unter **VPN → WireGuard → Endpunkte → nebenwohnsitz** eintragen → **Speichern & Anwenden**

---

## Teil C — wireguard-ui WebUI konfigurieren

Aufrufen unter: **`http://<raspi-ip>:5000`**

### C1 — „WireGuard Server" Einstellungen prüfen

Der Wizard hat alle Werte vorausgefüllt. Prüfe:

| Feld          | Erwarteter Wert   |
|---------------|-------------------|
| Server Address| `10.10.0.2/24`    |
| Listen Port   | `51820`           |
| MTU           | `1280`            |
| DNS           | `10.10.0.1, 1.1.1.1` |
| Post Up       | `iptables ... MASQUERADE` (vom Wizard generiert) |

→ **Save** klicken

### C2 — OPNsense als Peer eintragen

1. Tab **„Wireguard Clients"** → **„+ New Client"**
2. Folgende Werte eintragen:

   | Feld              | Wert                                                      |
   |------------------|-----------------------------------------------------------|
   | Name             | `OPNsense-Hauptwohnsitz`                                  |
   | Public Key       | Public Key aus OPNsense (Teil A3 notiert)                 |
   | Allocated IPs    | `10.10.0.1/32`                                            |
   | **Allowed IPs**  | Siehe unten (Split- oder Full-Tunnel wählen)              |
   | Endpoint         | `vpn-home.deine-domain.de:51820`                          |
   | Keepalive        | `25`                                                      |

3. **Allowed IPs — wähle deinen Tunnel-Modus:**

   | Modus               | AllowedIPs                      | Wofür               |
   |---------------------|---------------------------------|---------------------|
   | **Split-Tunnel**    | `10.10.0.0/24, 192.168.10.0/24`| Nur Heimnetz erreichbar, Rest direkt über Vodafone |
   | **Full-Tunnel**     | `0.0.0.0/0, ::/0`              | Alles durch den Tunnel → Streaming über Starlink-Anschluss |

4. **Save** → **„Apply Config"** klicken
   → WireGuard startet automatisch und verbindet sich

### C3 — Tunnelstatus prüfen

In der WebUI: **„Wireguard Clients"** → Status-Symbol sollte grün werden

Oder im Terminal:
```bash
sudo docker exec wireguard-ui wg show
```

Erwartete Ausgabe:
```
interface: wg0
  public key: ...
  ...

peer: <OPNsense-Public-Key>
  endpoint: [2001:db8:xxxx::1]:51820
  latest handshake: 12 seconds ago    ← Verbindung aktiv!
  transfer: 1.23 MiB received, 456 KiB sent
```

---

## Teil D — Fritzbox 6660 konfigurieren

> Detaillierte Anleitung: [Fritzbox-IPv6-Setup.md](Fritzbox-IPv6-Setup.md)

### D1 — IPv6 aktivieren

**Fritzbox → Heimnetz → Netzwerk → Registerkarte „IPv6"**
- **IPv6-Unterstützung aktivieren** ✅
- Speichern

### D2 — Portfreigabe für WireGuard

**Fritzbox → Internet → Freigaben → Portfreigaben → Gerät hinzufügen**
- Gerät: Raspberry Pi auswählen
- **Neue Freigabe → Andere Anwendung**

  | Feld      | Wert                |
  |-----------|---------------------|
  | Protokoll | UDP                 |
  | Port      | `51820`             |
  | An Port   | `51820`             |

- **OK → Übernehmen**

### D3 — Statische Route (optional, für alle Fritzbox-Geräte)

Damit alle Geräte im Fritzbox-Netz das Hauptwohnsitz-LAN erreichen:

**Fritzbox → Heimnetz → Netzwerk → Registerkarte „Statische Routen"**

| Netzwerk         | Subnetzmaske    | Gateway (Raspi LAN-IP)  |
|-----------------|-----------------|-------------------------|
| `192.168.10.0`  | `255.255.255.0` | `192.168.20.50`         |
| `10.10.0.0`     | `255.255.255.0` | `192.168.20.50`         |

---

## Teil E — DDNS für den Raspberry Pi (Nebenwohnsitz)

Optional — nützlich wenn OPNsense Firewall-Regeln auf die Client-IPv6 setzen soll.

### E1 — ddns-go WebUI öffnen

`http://<raspi-ip>:9876`

> ⚠️ **Wichtig — Login-Zeitfenster beachten:**
> ddns-go gibt beim **ersten Start** nur ein kurzes Zeitfenster (~5 Minuten) um den
> Admin-Account einzurichten. Öffne die WebUI daher **sofort** nach dem ersten
> Container-Start und klicke auf:
> **„Login and configure as an administrator account"**
>
> Erscheint stattdessen die Fehlermeldung:
> *„Need to complete the username and password setting before …, please restart ddns-go"*
> → Das Zeitfenster ist abgelaufen. Lösung:
> ```bash
> sudo docker restart ddns-go
> # Dann sofort WebUI öffnen: http://<raspi-ip>:9876
> ```
> Oder über das Menü: **🐳 Container-Verwaltung → ddns-go neu starten**

### E2 — Konfigurieren

1. Provider wählen: **Cloudflare**
2. API-Token: (eigener Cloudflare-Token mit DNS:Edit-Berechtigung)
3. **Speichern**

**IPv4-Sektion:**

| Feld    | Wert                |
|---------|---------------------|
| Enabled | ☐ **deaktivieren** |

> **Warum deaktivieren?** Vodafone Kabel nutzt DS-Lite — du hast kein öffentliches IPv4.
> ddns-go würde sonst eine private CGNAT-Adresse in den DNS eintragen, was nicht funktioniert.

**IPv6-Sektion:**

| Feld           | Wert                             |
|----------------|----------------------------------|
| Enabled        | ✅ aktivieren                    |
| Get IP method  | **By network card → eth0**       |
| Domains        | `vpn-neben.deine-domain.de`      |

> **Warum "By network card" statt "By API"?**
> Linux vergibt sich durch IPv6 Privacy Extensions **mehrere Adressen gleichzeitig**:
> eine stabile (MAC-basiert, ändert sich nie) und eine temporäre (zufällig, wechselt regelmäßig).
> Externe Dienste (By API) sehen immer die **temporäre** Adresse, da das OS diese für
> ausgehende Verbindungen bevorzugt — dein DNS-Eintrag würde auf eine kurzlebige Adresse zeigen.
> "By network card" liest direkt die **stabile** Adresse von `eth0`, unabhängig davon,
> welche Adresse für ausgehende Verbindungen verwendet wird.

4. **Save** klicken
5. **„Einmalig aktualisieren"** → der AAAA-Record wird sofort gesetzt
6. Intervall: `5 Minuten` (Standard — passt)

---

## Teil F — Verbindung vollständig testen

### F1 — VPN-Tunnel

```bash
# Auf dem Raspberry Pi:
ping 10.10.0.1              # OPNsense WireGuard-Interface
ping 192.168.10.1           # OPNsense LAN-Gateway (Hauptwohnsitz)

# Von einem Gerät am Nebenwohnsitz (wenn Fritzbox-Route gesetzt):
ping 192.168.10.1           # Hauptwohnsitz-LAN
ping 192.168.20.50          # Raspi selbst
```

### F2 — Streaming-Test (Full-Tunnel)

Bei Full-Tunnel (`AllowedIPs = 0.0.0.0/0, ::/0`) erscheinen Geräte am
Nebenwohnsitz mit der öffentlichen IP des Hauptwohnsitzes:

```bash
curl -s https://ifconfig.me
# Muss die Starlink-IPv6/IPv4 des Hauptwohnsitzes zurückgeben
```

### F3 — Nach einem Neustart

Container starten automatisch neu (`restart: unless-stopped`).
Status prüfen:

```bash
sudo bash /opt/pi-vpn/scripts/manage/status.sh
```

---

## Nützliche Befehle

```bash
# Zentrales Menü — empfohlener Einstieg für alle Aktionen
sudo bash /opt/pi-vpn/menu.sh

# WireGuard-Status (direkt)
sudo docker exec wireguard-ui wg show

# Vollständiger VPN-Status
sudo bash /opt/pi-vpn/scripts/manage/status.sh

# Container-Logs
sudo docker logs wireguard-ui --tail 50
sudo docker logs ddns-go --tail 50

# Container neu starten
cd /opt/pi-vpn/docker/nebenwohnsitz
sudo docker compose restart

# Konfig-Backup
sudo bash /opt/pi-vpn/scripts/manage/backup.sh

# Updates holen (wenn Token noch aktiv)
cd /opt/pi-vpn
sudo git pull

# ── Alles zurücksetzen (für Neu-Tests) ──────────────────────────────────────
sudo bash /opt/pi-vpn/scripts/manage/reset.sh
```

> **Neu-Test / Komplett-Reset:** `reset.sh` führt dich interaktiv durch alle 8 Schritte:
> Tunnel trennen → Container entfernen → Volumes löschen → .env löschen →
> Docker deinstallieren (optional) → Projektverzeichnis löschen (optional).
> Danach: `sudo git clone ...` und `sudo bash /opt/pi-vpn/menu.sh` erneut ausführen.

---

## Häufige Probleme

| Problem                              | Ursache                              | Lösung                                                        |
|--------------------------------------|--------------------------------------|---------------------------------------------------------------|
| `git: command not found`             | git nicht vorinstalliert (frisches RPi OS) | `sudo apt update && sudo apt install -y git`            |
| `git clone` schlägt stillschweigend fehl | Token abgelaufen oder falsch       | Neuen Fine-grained Token erstellen (Teil B2)                  |
| ddns-go: „Need to complete username/password…" | Login-Zeitfenster abgelaufen | `sudo docker restart ddns-go` → sofort WebUI öffnen (Teil E1) |
| Tunnel baut sich nicht auf           | Fritzbox-Portfreigabe fehlt          | Teil D2 erneut prüfen                                         |
| „latest handshake" veraltet         | DDNS-Record outdated                 | ddns-go WebUI → „Einmalig aktualisieren"                      |
| Tunnel aktiv aber kein LAN-Ping      | Route in OPNsense/Fritzbox fehlt     | Teil A7 bzw. D3 prüfen                                        |
| wg0 startet nicht                    | iptables-Fehler (falsches Interface) | `LAN_IFACE` im Wizard prüfen: `ip link show`                  |
| wireguard-ui startet nicht           | Port 5000 belegt                     | `sudo ss -tlnp \| grep 5000`                                  |
| IPv6 nicht verfügbar                 | Fritzbox IPv6 deaktiviert            | Teil D1 → IPv6 aktivieren                                     |
| Menü zeigt abgeschnittene Zeichen    | Terminal zu schmal                   | Terminal auf mindestens 80×24 Zeichen vergrößern              |

