"""Сповіщення: застосунок на телефоні отримує події через API (фоновий сервіс),
а додатково модуль може надсилати push через ntfy, Telegram або вебхук —
це працює навіть коли телефон «приспав» застосунок (iOS, енергозбереження Android).
"""

from __future__ import annotations

import json
import logging
import queue
import threading
import time
import urllib.request

log = logging.getLogger(__name__)


class Notifier:
    def __init__(self, cfg, device_name: str) -> None:
        self.cfg = cfg            # NotifyConfig (живе посилання — зміни з телефону діють одразу)
        self.device_name = device_name
        self.q: queue.Queue = queue.Queue(maxsize=200)
        self.last_sent: dict[str, float] = {}
        self._th = threading.Thread(target=self._run, daemon=True, name="notifier")
        self._th.start()

    def maybe_notify(self, kind: str, track: dict, image: bytes | None = None) -> bool:
        c = self.cfg
        cls = track.get("class") or {}
        if not c.enabled or cls.get("priority", 0) < c.min_priority or kind not in ("new", "reacquired", "changed"):
            return False
        if c.classes and cls.get("code") not in c.classes:
            return False
        rssi = track.get("rssi_dbm")
        if c.min_rssi_dbm is not None and rssi is not None and rssi < c.min_rssi_dbm:
            return False
        key = f"{cls.get('code')}:{round(track.get('freq_hz', 0) / 5e6)}"
        now = time.time()
        if now - self.last_sent.get(key, 0) < c.cooldown_s:
            return False
        self.last_sent[key] = now
        title = f"{self.device_name}: {cls.get('label', 'Сигнал')}"
        body = track.get("hint", "")
        try:
            self.q.put_nowait((title, body, track, image))
        except queue.Full:
            return False
        return True

    def _run(self) -> None:
        while True:
            title, body, track, image = self.q.get()
            c = self.cfg
            for name, fn in (("ntfy", self._ntfy), ("telegram", self._telegram), ("webhook", self._webhook)):
                try:
                    fn(c, title, body, track, image)
                except Exception as e:  # noqa: BLE001 — мережа може бути недоступна
                    log.warning("Сповіщення %s не надіслано: %s", name, e)

    @staticmethod
    def _post(url: str, data: bytes, headers: dict) -> None:
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()

    def _ntfy(self, c, title, body, track, image) -> None:
        if not c.ntfy_url:
            return
        pr = (track.get("class") or {}).get("priority", 0)
        self._post(c.ntfy_url, body.encode(), {
            "Title": _rfc2047(title),
            "Priority": "high" if pr >= 2 else "default",
            "Tags": "satellite_antenna",
        })

    def _telegram(self, c, title, body, track, image) -> None:
        if not (c.telegram_token and c.telegram_chat_id):
            return
        url = f"https://api.telegram.org/bot{c.telegram_token}/sendMessage"
        data = json.dumps({"chat_id": c.telegram_chat_id, "text": f"⚠️ {title}\n{body}"}).encode()
        self._post(url, data, {"Content-Type": "application/json"})

    def _webhook(self, c, title, body, track, image) -> None:
        if not c.webhook_url:
            return
        data = json.dumps({"device": self.device_name, "title": title, "body": body, "track": track},
                          ensure_ascii=False).encode()
        self._post(c.webhook_url, data, {"Content-Type": "application/json"})


def _rfc2047(s: str) -> str:
    """Заголовки HTTP мають бути ASCII — кодуємо UTF-8 за RFC 2047 (ntfy це розуміє)."""
    import base64
    return "=?UTF-8?B?" + base64.b64encode(s.encode()).decode() + "?="
