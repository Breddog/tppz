"""Інформація та керування мережею модуля через NetworkManager (nmcli).

Читання (IP, інтерфейси, поточний Wi-Fi) працює без прав. Зміни (додати Wi-Fi, забути)
потребують дозволу polkit для користувача сервісу — його додає install.sh.
Усі виклики nmcli — списком аргументів (без shell), з таймаутами.
"""

from __future__ import annotations

import socket
import subprocess


def _run(args: list[str], timeout: float = 15.0) -> tuple[int, str, str]:
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "nmcli не встановлено"
    except subprocess.TimeoutExpired:
        return 124, "", "перевищено час очікування"


def _nmcli(*args: str, timeout: float = 15.0) -> tuple[int, str, str]:
    return _run(["nmcli", "-t", *args], timeout=timeout)


def interfaces() -> list[dict]:
    """Фізичні інтерфейси з IP-адресами (Ethernet, Wi-Fi)."""
    out: list[dict] = []
    rc, data, _ = _nmcli("-f", "DEVICE,TYPE,STATE,CONNECTION", "device")
    if rc != 0:
        # Резерв без NetworkManager — хоча б IP з socket
        return _interfaces_fallback()
    for line in data.strip().splitlines():
        parts = line.split(":")
        if len(parts) < 4 or parts[1] not in ("ethernet", "wifi"):
            continue
        dev, typ, state, conn = parts[0], parts[1], parts[2], parts[3]
        ips = _dev_ips(dev)
        out.append({"device": dev, "type": typ, "state": state, "connection": conn, "ips": ips})
    return out


def _dev_ips(dev: str) -> list[str]:
    rc, data, _ = _run(["ip", "-o", "-4", "addr", "show", "dev", dev])
    ips = []
    if rc == 0:
        for line in data.splitlines():
            toks = line.split()
            if "inet" in toks:
                ips.append(toks[toks.index("inet") + 1])  # напр. 192.168.1.50/24
    return ips


def _interfaces_fallback() -> list[dict]:
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return [{"device": "?", "type": "?", "state": "?", "connection": "", "ips": ips}]


def wifi_status() -> dict:
    rc, data, _ = _nmcli("-f", "ACTIVE,SSID,SIGNAL,FREQ", "device", "wifi", "list", "--rescan", "no")
    current = None
    if rc == 0:
        for line in data.strip().splitlines():
            p = line.split(":")
            if len(p) >= 2 and p[0] == "yes":
                current = {"ssid": p[1], "signal": p[2] if len(p) > 2 else "", "freq": p[3] if len(p) > 3 else ""}
                break
    return {"connected_ssid": current}


def saved_wifi() -> list[dict]:
    rc, data, _ = _nmcli("-f", "NAME,TYPE,AUTOCONNECT", "connection", "show")
    nets = []
    if rc == 0:
        for line in data.strip().splitlines():
            p = line.split(":")
            if len(p) >= 2 and p[1] in ("802-11-wireless", "wifi"):
                nets.append({"name": p[0], "autoconnect": p[2] == "yes" if len(p) > 2 else True})
    return nets


def scan_wifi() -> list[dict]:
    _nmcli("device", "wifi", "rescan", timeout=8.0)
    rc, data, _ = _nmcli("-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list")
    seen: dict[str, dict] = {}
    if rc == 0:
        for line in data.strip().splitlines():
            p = line.split(":")
            if len(p) >= 2 and p[0] and p[0] not in seen:
                seen[p[0]] = {"ssid": p[0], "signal": int(p[1]) if p[1].isdigit() else 0,
                              "security": p[2] if len(p) > 2 else ""}
    return sorted(seen.values(), key=lambda x: -x["signal"])


def info(hostname: str) -> dict:
    return {
        "hostname": hostname,
        "interfaces": interfaces(),
        "wifi": wifi_status(),
        "saved_wifi": saved_wifi(),
    }


def add_wifi(ssid: str, password: str, priority: int = 5) -> dict:
    """Додати/оновити Wi-Fi і підключитися. Порожній пароль — відкрита мережа."""
    if not ssid:
        raise ValueError("Порожня назва мережі")
    name = f"wifi-{ssid}"
    _nmcli("connection", "delete", name, timeout=10.0)  # перестворюємо з нуля
    args = ["connection", "add", "type", "wifi", "con-name", name, "ssid", ssid,
            "connection.autoconnect", "yes", "connection.autoconnect-priority", str(priority)]
    if password:
        args += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password]
    rc, _, err = _nmcli(*args, timeout=20.0)
    if rc != 0:
        raise PermissionError(err.strip() or "Не вдалося створити профіль Wi-Fi")
    rc, _, err = _nmcli("connection", "up", name, timeout=30.0)
    # «up» може не вдатися, якщо мережі поряд немає — профіль усе одно збережено
    return {"ok": True, "name": name, "connected": rc == 0, "message": "" if rc == 0 else err.strip()}


def forget_wifi(name: str) -> dict:
    if not name:
        raise ValueError("Не вказано мережу")
    rc, _, err = _nmcli("connection", "delete", name, timeout=15.0)
    if rc != 0:
        raise PermissionError(err.strip() or "Не вдалося видалити мережу")
    return {"ok": True}
