"""Пошук модулів у локальній мережі: UDP-broadcast (без залежностей) + mDNS (якщо є zeroconf)."""

from __future__ import annotations

import json
import logging
import socket
import threading

log = logging.getLogger(__name__)

DISCOVERY_PORT = 47800
MAGIC = b"SDRWATCH_DISCOVER"


def local_ips() -> list[str]:
    ips: set[str] = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


class DiscoveryResponder(threading.Thread):
    """Відповідає на broadcast-запит застосунку: ім'я, id і порт API (без токена!)."""

    def __init__(self, name_fn, device_id: str, api_port: int) -> None:
        super().__init__(daemon=True, name="discovery")
        self.name_fn, self.device_id, self.api_port = name_fn, device_id, api_port

    def run(self) -> None:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("", DISCOVERY_PORT))
        except OSError as e:
            log.warning("Пошук у мережі вимкнено: %s", e)
            return
        while True:
            data, addr = sock.recvfrom(256)
            if data.strip() == MAGIC:
                reply = json.dumps({"app": "sdrwatch", "name": self.name_fn(), "id": self.device_id,
                                    "port": self.api_port}, ensure_ascii=False).encode()
                sock.sendto(reply, addr)


def register_mdns(name: str, port: int, device_id: str):
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        return None
    ips = local_ips()
    if not ips:
        return None
    zc = Zeroconf()
    info = ServiceInfo("_sdrwatch._tcp.local.", f"{device_id}._sdrwatch._tcp.local.",
                       addresses=[socket.inet_aton(ip) for ip in ips], port=port,
                       properties={"name": name, "id": device_id})
    try:
        zc.register_service(info)
    except Exception as e:  # noqa: BLE001
        log.warning("mDNS не зареєстровано: %s", e)
        return None
    return zc
