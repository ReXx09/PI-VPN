#!/usr/bin/env python3
"""PI-VPN Dashboard — Backend API (Flask)"""

import os
import sys
import json as _json
import subprocess
import time
import shutil
from flask import Flask, jsonify, send_from_directory

try:
    import docker as docker_sdk
    _docker_available = True
except ImportError:
    _docker_available = False

app = Flask(__name__, static_folder="static")

# Pfade zu Host-Mounts (docker-compose volume-Mounts)
HOST_PROC = "/hostproc"
HOST_SYS  = "/hostsys"
HOST_ROOT = "/hostroot"


# ── Hilfsfunktionen ───────────────────────────────────────────────────────────

def sh(cmd, timeout=5):
    """Befehl ausführen, stdout zurückgeben (oder '' bei Fehler)."""
    try:
        return subprocess.check_output(
            cmd, text=True, stderr=subprocess.DEVNULL, timeout=timeout
        )
    except Exception:
        return ""


def read_host(relpath):
    """Datei aus Host-/proc lesen, Fallback auf Container-/proc."""
    for base in [HOST_PROC, ""]:
        try:
            with open(base + relpath) as f:
                return f.read()
        except Exception:
            pass
    return ""


def docker_client():
    if not _docker_available:
        return None
    try:
        return docker_sdk.from_env()
    except Exception:
        return None


# ── Daten-Collector: WireGuard ────────────────────────────────────────────────

WG_CONF = os.environ.get("WG_CONF_PATH", "/app/wireguard/wg0.conf")
WGUI_DB = os.environ.get("WGUI_DB_PATH",  "/app/wgui-db/server.db")


def _names_from_wg_conf(path):
    """Peer-Namen aus wg0.conf parsen.
    wireguard-ui schreibt '# <Name>' als Kommentar vor/nach [Peer].
    Unterstützt auch '# Name: <Name>' und '### begin <Name> ###'."""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return {}
    result, pending = {}, None
    for line in lines:
        s = line.strip()
        if not s:
            pass                                            # Leerzeile: pending behalten
        elif s.startswith("###"):                           # ### begin Name ###
            inner = s.strip("#").strip()
            if inner.lower().startswith("begin "):
                pending = inner[6:].strip()
        elif s.startswith("#"):                             # # Name  oder  # Name: Wert
            candidate = s.lstrip("#").strip()
            if candidate.lower().startswith("name:"):
                candidate = candidate[5:].strip()
            # Interne wireguard-ui Metadaten-Kommentare ignorieren
            _skip = ("update at", "update:", "generated", "do not edit", "last update")
            if any(candidate.lower().startswith(p) for p in _skip):
                pass
            elif candidate:
                pending = candidate
        elif s == "[Peer]":
            pass                                            # pending behalten
        elif s.startswith("PublicKey") and "=" in s:
            key = s.split("=", 1)[1].strip()
            if key and pending:
                result[key] = pending
            pending = None
        elif s.startswith("[") and s != "[Peer]":
            pending = None                                  # neue Sektion → reset
    return result


def _names_from_boltdb(path):
    """Peer-Namen aus wireguard-ui BoltDB durch binäre JSON-Suche.
    wireguard-ui (ngoduykhanh) speichert jeden Client als JSON-Blob in BoltDB.
    Wir suchen nach JSON-Objekten die mit '{"id"' beginnen und
    sowohl 'public_key' als auch 'name' enthalten."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return {}
    result = {}
    for chunk in raw.split(b'{"id"')[1:]:
        # Schließende Klammer des JSON-Objekts suchen
        depth, end = 1, -1
        for pos, b in enumerate(chunk):
            if b == 0x7B:    # {
                depth += 1
            elif b == 0x7D:  # }
                depth -= 1
                if depth == 0:
                    end = pos
                    break
        if end == -1:
            continue
        segment = b'{"id"' + chunk[:end + 1]
        if b'"public_key"' not in segment or b'"name"' not in segment:
            continue
        try:
            obj = _json.loads(segment)
            pk = obj.get("public_key", "")
            nm = obj.get("name", "")
            if pk and nm:
                result[pk] = nm
        except Exception:
            pass
    return result


def wgui_peer_names():
    """Peer-Namen: erst wg0.conf, Fallback auf BoltDB-Binärsuche."""
    names = _names_from_wg_conf(WG_CONF)
    if names:
        print(f"[dash] peer-namen aus wg0.conf ({len(names)}): {list(names.values())}", file=sys.stderr, flush=True)
        return names
    names = _names_from_boltdb(WGUI_DB)
    if names:
        print(f"[dash] peer-namen aus boltdb ({len(names)}): {list(names.values())}", file=sys.stderr, flush=True)
        return names
    print(
        f"[dash] WARN: keine peer-namen gefunden. "
        f"wg_conf={WG_CONF} (exists={os.path.exists(WG_CONF)}), "
        f"db={WGUI_DB} (exists={os.path.exists(WGUI_DB)})",
        file=sys.stderr, flush=True,
    )
    return {}


def wg_data():
    """`wg show wg0 dump` parsen → (interface_up, peers_list)."""
    out = sh(["wg", "show", "wg0", "dump"])
    if not out.strip():
        return False, []

    now = int(time.time())
    peer_names = wgui_peer_names()
    peers = []
    for i, line in enumerate(out.strip().split("\n")):
        if i == 0:
            continue  # erste Zeile = Interface-Zeile
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        pub_key, _psk, endpoint, allowed_ips, latest_hs, rx, tx, _ka = parts[:8]
        hs = int(latest_hs) if latest_hs.isdigit() and latest_hs != "0" else 0
        name = peer_names.get(pub_key, "")
        peers.append({
            "name":             name,
            "public_key_short": pub_key[:20] + "…" if len(pub_key) > 20 else pub_key,
            "public_key":       pub_key,
            "endpoint":         endpoint if endpoint != "(none)" else None,
            "allowed_ips":      allowed_ips,
            "handshake_ago":    (now - hs) if hs else None,
            "rx_bytes":         int(rx) if rx.isdigit() else 0,
            "tx_bytes":         int(tx) if tx.isdigit() else 0,
        })
    return True, peers


# ── Daten-Collector: Container ────────────────────────────────────────────────

def container_info(client, name):
    if not client:
        return {"running": False, "status": "docker n/a", "restart_count": 0}
    try:
        c = client.containers.get(name)
        return {
            "running":       c.status == "running",
            "status":        c.status,
            "restart_count": c.attrs.get("RestartCount", 0),
        }
    except Exception:
        return {"running": False, "status": "not found", "restart_count": 0}


def get_logs(client, name, n=20):
    if not client:
        return ["(Docker nicht verfügbar)"]
    try:
        c = client.containers.get(name)
        raw = c.logs(tail=n).decode("utf-8", errors="replace")
        return [l for l in raw.strip().split("\n") if l][-n:]
    except Exception:
        return ["(Container nicht gefunden)"]


# ── Daten-Collector: System ───────────────────────────────────────────────────

def system_info():
    # Load Average
    loadavg_raw = read_host("/proc/loadavg")
    load = loadavg_raw.split()[:3] if loadavg_raw else ["?", "?", "?"]

    # RAM aus /proc/meminfo
    ram_total = ram_used = 0
    for line in read_host("/proc/meminfo").split("\n"):
        parts = line.split()
        if len(parts) >= 2:
            if parts[0] == "MemTotal:":
                ram_total = int(parts[1]) // 1024
            elif parts[0] == "MemAvailable:":
                ram_used = ram_total - int(parts[1]) // 1024

    # Disk: Host-Root gemountet unter HOST_ROOT
    disk_pct = 0
    for root in [HOST_ROOT, "/"]:
        try:
            st = os.statvfs(root)
            total = st.f_blocks * st.f_frsize
            free  = st.f_bfree  * st.f_frsize
            disk_pct = round((total - free) / total * 100, 1) if total else 0
            break
        except Exception:
            pass

    # CPU-Temperatur
    temp = None
    for path in [
        f"{HOST_SYS}/class/thermal/thermal_zone0/temp",
        "/sys/class/thermal/thermal_zone0/temp",
    ]:
        try:
            with open(path) as f:
                temp = round(int(f.read().strip()) / 1000, 1)
            break
        except Exception:
            pass

    # Uptime
    uptime_str = "?"
    raw = read_host("/proc/uptime")
    if raw:
        try:
            secs = float(raw.split()[0])
            d = int(secs // 86400)
            h = int((secs % 86400) // 3600)
            m = int((secs % 3600) // 60)
            uptime_str = f"{d}d {h}h {m}m"
        except Exception:
            pass

    return {
        "load":          load,
        "ram_total_mb":  ram_total,
        "ram_used_mb":   ram_used,
        "ram_percent":   round(ram_used / ram_total * 100, 1) if ram_total else 0,
        "disk_percent":  disk_pct,
        "temp_celsius":  temp,
        "uptime":        uptime_str,
    }


# ── Daten-Collector: DDNS / IPv6 ─────────────────────────────────────────────

def local_ipv6():
    """Stabile globale IPv6 von eth0 (keine temporäre Privacy-Adresse)."""
    out = sh(["ip", "-6", "addr", "show", "eth0"])
    for line in out.split("\n"):
        if "scope global" in line and "temporary" not in line:
            parts = line.strip().split()
            if len(parts) >= 2:
                return parts[1].split("/")[0]
    return None


def dns_aaaa(hostname):
    """AAAA-Record per dig auflösen mit Retry-Logik, inkl. Fehlergrund."""
    if not hostname:
        return None, "hostname_missing"
    if not shutil.which("dig"):
        return None, "dig_missing"

    # Retry-Logik: Versuche bis zu 3x mit verschiedenen Nameservern
    attempts = [
        ["dig", hostname, "AAAA", "+short", "+time=2"],  # Standard
        ["dig", "@1.1.1.1", hostname, "AAAA", "+short", "+time=2"],  # Cloudflare
        ["dig", "@8.8.8.8", hostname, "AAAA", "+short", "+time=2"],   # Google
    ]
    
    for attempt, cmd in enumerate(attempts):
        try:
            proc = subprocess.run(
                cmd,
                text=True,
                capture_output=True,
                timeout=5,
                check=False,
            )
        except Exception:
            continue

        out = proc.stdout or ""
        lines = [l.strip() for l in out.strip().split("\n")
                 if l.strip() and not l.startswith(";")]
        if lines:
            return lines[0], None
    
    # Keine Antwort von allen Servern
    return None, "no_aaaa"


# ── Daten-Collector: Nextcloud ────────────────────────────────────────────────

def nextcloud_status():
    """WebDAV PROPFIND auf den Backup-Ordner — listet Backup-Dateien."""
    import urllib.request
    import urllib.error
    import base64
    import xml.etree.ElementTree as ET
    from urllib.parse import quote

    nc_url  = os.environ.get("NC_URL",  "").rstrip("/")
    nc_user = os.environ.get("NC_USER", "")
    nc_pass = os.environ.get("NC_PASS", "")
    nc_path = os.environ.get("NC_PATH", "/PI-VPN-Backups").lstrip("/")

    if not (nc_url and nc_user and nc_pass):
        return {"configured": False}

    dav_url = (
        f"{nc_url}/remote.php/dav/files/"
        f"{quote(nc_user, safe='')}/{quote(nc_path, safe='/')}/"
    )
    req = urllib.request.Request(dav_url, method="PROPFIND")
    creds = base64.b64encode(f"{nc_user}:{nc_pass}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Depth", "1")
    req.add_header("Content-Type", "application/xml")

    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return {"configured": True, "reachable": False, "error": f"HTTP {e.code}"}
    except Exception as e:
        return {"configured": True, "reachable": False, "error": str(e)[:80]}

    try:
        root = ET.fromstring(body)
        ns   = {"d": "DAV:"}
        files = []
        for resp_el in root.findall("d:response", ns):
            href = resp_el.findtext("d:href", namespaces=ns) or ""
            if href.endswith("/"):
                continue  # Ordner überspringen (Folder selbst + Unterordner)
            name = href.split("/")[-1]
            if name:
                files.append(name)
        files.sort(reverse=True)
        return {
            "configured":   True,
            "reachable":    True,
            "backup_count": len(files),
            "last_backup":  files[0] if files else None,
        }
    except Exception:
        return {"configured": True, "reachable": True, "backup_count": 0, "last_backup": None}


# ── Flask-Routes ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory("static", "index.html")


@app.route("/api/status")
def status():
    client   = docker_client()
    wg_up, peers = wg_data()
    lip6     = local_ipv6()
    hostname = os.environ.get("VPN_HOST", "")
    dip6, dns_reason = dns_aaaa(hostname)

    return jsonify({
        "timestamp": int(time.time()),
        "vpn": {
            "up":    wg_up,
            "peers": peers,
        },
        "containers": {
            "wireguard-ui": container_info(client, "wireguard-ui"),
            "ddns-go":      container_info(client, "ddns-go"),
            "dashboard":    container_info(client, "dashboard"),
        },
        "ddns": {
            "hostname":   hostname,
            "local_ipv6": lip6,
            "dns_ipv6":   dip6,
            "dns_reason": dns_reason,
            "match":      (lip6 == dip6) if (lip6 and dip6) else None,
        },
        "system": system_info(),
        "logs": {
            "wireguard-ui": get_logs(client, "wireguard-ui"),
            "ddns-go":      get_logs(client, "ddns-go"),
        },
        "nextcloud": nextcloud_status(),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
