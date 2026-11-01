"""Обробка сигналу в ОКРЕМОМУ процесі.

Python виконує код одного процесу лише на одному ядрі (GIL). Коли огляд ефіру й веб-сервер
жили разом, обробка «забирала» ядро — і застосунок отримував спектр, звук і відповіді із
затримкою. Тепер:
  * процес «engine» — HackRF + уся обробка сигналу (своє ядро Pi);
  * основний процес — веб-сервер, WebSocket, пошук у мережі (інше ядро).
Між ними — канал команд (Pipe) і черга живих даних (Queue).

EngineProxy має той самий вигляд, що й Engine, тож API не знає, де працює обробка.
"""

from __future__ import annotations

import hashlib
import json
import logging
import multiprocessing as mp
import os
import queue
import threading
import time
from concurrent.futures import Future
from typing import Any

log = logging.getLogger(__name__)

# Атрибути Engine, які API читає напряму (а не викликає)
ATTRS = {"last_spectrum", "recording", "video_opts", "mode", "watch_freq", "notifier"}


class ProcHub:
    """Замінник Hub у процесі обробки: публікує в чергу, знає про підписників із основного процесу."""

    def __init__(self, q) -> None:
        self.q = q
        self.counts: dict[str, int] = {}
        self.options: dict[str, dict] = {}
        self.viewed: set = set()

    def publish(self, channel: str, item: Any, filt=None) -> None:
        if not self.counts.get(channel):
            return                              # нікому не потрібно — не ганяємо дані між процесами
        try:
            self.q.put_nowait((channel, item))
        except queue.Full:
            pass                                # основний процес не встигає — краще пропустити кадр

    def count(self, channel: str) -> int:
        return self.counts.get(channel, 0)

    def option(self, channel: str, key: str, default: Any = None) -> Any:
        v = self.options.get(channel, {}).get(key)
        return default if v is None else v

    def viewed_ranges(self) -> set:
        return set(self.viewed)


def _cfg_hash(cfg) -> str:
    return hashlib.md5(json.dumps(cfg.to_dict(include_secrets=True), sort_keys=True,
                                  default=str).encode()).hexdigest()


def _child(cfg_path: str, overrides: dict, conn, q) -> None:
    from .config import Config
    from .notifier import Notifier
    from .scanner import Engine
    from .sources import create_source
    from .storage import Storage

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s engine: %(message)s")
    cfg = Config.load(cfg_path)
    cfg.update(overrides)
    storage = Storage(cfg.storage.path, cfg.storage.quota_mb)
    hub = ProcHub(q)
    engine = Engine(cfg, create_source(cfg.sdr), storage, Notifier(cfg.notify, cfg.name), hub)
    engine.start()
    send_lock = threading.Lock()
    h0 = [_cfg_hash(cfg)]

    def reply(rid, ok, val):
        h = _cfg_hash(cfg)
        snap = cfg.to_dict(include_secrets=True) if h != h0[0] else None   # обробка змінила конфіг
        h0[0] = h
        with send_lock:
            conn.send((rid, ok, val, snap))

    def handle(msg):
        kind, rid = msg[0], msg[1]
        try:
            if kind == "call":
                _, _, name, args, kwargs = msg
                reply(rid, True, getattr(engine, name)(*args, **kwargs))
            elif kind == "get":
                val = getattr(engine, msg[2])
                if msg[2] == "notifier":
                    val = None
                reply(rid, True, val)
            elif kind == "cfg":
                cfg.update(msg[2])
                if engine.notifier:
                    engine.notifier.device_name = cfg.name
                h0[0] = _cfg_hash(cfg)
                reply(rid, True, None)
        except Exception as e:  # noqa: BLE001 — помилку повертаємо в API
            reply(rid, False, e)

    while True:
        try:
            msg = conn.recv()
        except (EOFError, OSError):
            break
        if msg[0] == "subs":
            hub.counts, hub.options, hub.viewed = msg[1], msg[2], set(msg[3])
            continue
        if msg[0] == "stop":
            break
        threading.Thread(target=handle, args=(msg,), daemon=True).start()
    engine.stop()


class EngineProxy:
    """Те саме, що Engine, але сам Engine живе в іншому процесі."""

    def __init__(self, cfg, hub, overrides: dict | None = None) -> None:
        self.cfg = cfg
        self.hub = hub
        ctx = mp.get_context("spawn")
        self._conn, child_conn = ctx.Pipe()
        self._q = ctx.Queue(maxsize=256)
        self._proc = ctx.Process(target=_child, args=(cfg._path, overrides or {}, child_conn, self._q),
                                 daemon=True, name="sdrwatch-engine")
        self._pending: dict[int, Future] = {}
        self._rid = 0
        self._lock = threading.Lock()
        self._last_subs = None
        self._stopping = False

    # ---- життєвий цикл ----------------------------------------------------------------------
    def start(self) -> None:
        self._proc.start()
        for fn, name in ((self._reader, "engine-rpc"), (self._forward, "engine-hub"), (self._subs, "engine-subs")):
            threading.Thread(target=fn, daemon=True, name=name).start()

    def stop(self) -> None:
        self._stopping = True
        try:
            self._conn.send(("stop", 0))
        except (OSError, ValueError):
            pass
        self._proc.join(timeout=6)
        if self._proc.is_alive():
            self._proc.kill()

    def _reader(self) -> None:
        while True:
            try:
                rid, ok, val, snap = self._conn.recv()
            except (EOFError, OSError):
                if not self._stopping:
                    log.error("Процес обробки сигналу завершився — перезапуск служби")
                    os._exit(3)         # systemd перезапустить службу
                return
            if snap is not None:
                api = snap.pop("api", None)   # порт/токен — лише з основного процесу
                self.cfg.update(snap)
                del api
            fut = self._pending.pop(rid, None)
            if fut is not None:
                (fut.set_result if ok else fut.set_exception)(val)

    def _forward(self) -> None:
        while True:
            try:
                channel, item = self._q.get()
            except (EOFError, OSError):
                return
            self.hub.publish(channel, item)

    def _subs(self) -> None:
        """Повідомляти процес обробки, хто з клієнтів що дивиться (щоб не рахувати зайвого)."""
        while not self._stopping:
            with self.hub._lock:
                subs = list(self.hub._subs)
            counts: dict[str, int] = {}
            options: dict[str, dict] = {}
            for s in subs:
                counts[s.channel] = counts.get(s.channel, 0) + 1
                for k, v in s.options.items():
                    if v is not None:
                        options.setdefault(s.channel, {}).setdefault(k, v)
            viewed = sorted(r for r in self.hub.viewed_ranges() if isinstance(r, int))
            cur = (counts, options, viewed)
            if cur != self._last_subs:
                self._last_subs = cur
                try:
                    self._conn.send(("subs", counts, options, viewed))
                except (OSError, ValueError):
                    pass
            time.sleep(0.15)

    # ---- виклики ------------------------------------------------------------------------------
    def _request(self, kind: str, *payload, timeout: float = 20.0):
        fut: Future = Future()
        with self._lock:
            self._rid += 1
            rid = self._rid
            self._pending[rid] = fut
            self._conn.send((kind, rid, *payload))
        return fut.result(timeout=timeout)

    def reconfigure(self) -> None:
        self._request("cfg", self.cfg.to_dict(include_secrets=True))
        self._request("call", "reconfigure", (), {})

    def __getattr__(self, name: str):
        if name.startswith("_"):
            raise AttributeError(name)
        if name in ATTRS:
            return self._request("get", name)

        def call(*args, **kwargs):
            return self._request("call", name, args, kwargs)

        return call
