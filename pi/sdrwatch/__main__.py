"""Запуск: python -m sdrwatch run | pair | sim"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import signal
import sys

from . import __version__
from .config import DEFAULT_CONFIG_PATH, Config
from .discovery import DiscoveryResponder, local_ips, register_mdns


class AppState:
    def __init__(self, cfg, engine, storage, hub, device_id):
        self.cfg, self.engine, self.storage, self.hub, self.device_id = cfg, engine, storage, hub, device_id


def device_id_for(cfg: Config) -> str:
    try:
        with open("/proc/cpuinfo") as f:
            serial = [ln.split(":")[1].strip() for ln in f if ln.startswith("Serial")]
    except OSError:
        serial = []
    base = serial[0] if serial else cfg.api.token
    return "sdr-" + hashlib.sha1(base.encode()).hexdigest()[:10]


def pairing_payload(cfg: Config, host: str | None = None) -> dict:
    ips = [host] if host else local_ips()
    return {"app": "sdrwatch", "n": cfg.name, "id": device_id_for(cfg),
            "u": [f"http://{ip}:{cfg.api.port}" for ip in ips], "t": cfg.api.token}


def cmd_pair(args) -> None:
    cfg = Config.load(args.config)
    payload = json.dumps(pairing_payload(cfg, args.host), ensure_ascii=False, separators=(",", ":"))
    print("\nДодайте модуль у застосунок: «+» → «Сканувати QR» (або введіть дані вручну)\n")
    try:
        import qrcode
        q = qrcode.QRCode(border=1)
        q.add_data(payload)
        q.print_ascii(invert=True)
    except ImportError:
        print("(встановіть python3-qrcode, щоб показати QR-код у терміналі)")
    p = json.loads(payload)
    print(f"Назва:   {p['n']}\nАдреси:  {', '.join(p['u'])}\nТокен:   {p['t']}\n")


def cmd_run(args) -> None:
    import uvicorn

    from .api import create_app
    from .hub import Hub
    from .notifier import Notifier
    from .scanner import Engine
    from .sources import create_source
    from .storage import Storage

    logging.basicConfig(level=logging.INFO if not args.debug else logging.DEBUG,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Config.load(args.config)
    if args.sim:
        cfg.sdr.driver = "sim"
    if args.storage:
        cfg.storage.path = args.storage
    if args.port:
        cfg.api.port = args.port
    storage = Storage(cfg.storage.path, cfg.storage.quota_mb)
    hub = Hub()
    notifier = Notifier(cfg.notify, cfg.name)
    src = create_source(cfg.sdr)
    engine = Engine(cfg, src, storage, notifier, hub)
    engine.start()
    dev_id = device_id_for(cfg)
    DiscoveryResponder(lambda: cfg.name, dev_id, cfg.api.port).start()
    zc = register_mdns(cfg.name, cfg.api.port, dev_id)
    app = create_app(AppState(cfg, engine, storage, hub, dev_id))

    def shutdown(*_):
        engine.stop()
        if zc:
            zc.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    logging.info("SDR Watch %s: API на порту %d, приймач %s", __version__, cfg.api.port, src.name)
    try:
        uvicorn.run(app, host=cfg.api.host, port=cfg.api.port, log_level="warning")
    finally:
        engine.stop()


def main() -> None:
    ap = argparse.ArgumentParser(prog="sdrwatch", description="SDR Watch — сканер сигналів FPV для Raspberry Pi")
    ap.add_argument("--config", default=os.environ.get("SDRWATCH_CONFIG", DEFAULT_CONFIG_PATH))
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="запустити сервіс")
    r.add_argument("--sim", action="store_true", help="симулятор ефіру замість SDR")
    r.add_argument("--storage", help="тека для кільцевого запису")
    r.add_argument("--port", type=int)
    r.add_argument("--debug", action="store_true")
    p = sub.add_parser("pair", help="показати QR-код для додавання в застосунок")
    p.add_argument("--host", help="зовнішня адреса (напр. Tailscale IP або домен)")
    args = ap.parse_args()
    {"run": cmd_run, "pair": cmd_pair}[args.cmd](args)


if __name__ == "__main__":
    main()
