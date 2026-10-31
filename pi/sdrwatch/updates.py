"""Віддалене оновлення: ПЗ модуля (sdrwatch) і прошивка HackRF.

Сервіс працює без прав root, тому він лише кладе перевірений файл і запит у
/var/lib/sdrwatch/update/, а встановлює службова одноразова програма
sdrwatch-update (systemd path-unit, root). Стан пишеться в status.json.

Файл приходить або з застосунку (телефон завантажив його з GitHub і передав —
працює, коли в модуля немає інтернету), або модуль завантажує його сам.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.request

KINDS = {
    # тип: (префікс тегу релізу, ім'я файлу в релізі, максимальний розмір)
    "pi": ("pi-", "sdrwatch-pi.tar.gz", 50 * 1024 * 1024),
    "hackrf": ("hackrf-", "hackrf_one_usb.bin", 2 * 1024 * 1024),
}


class UpdateError(Exception):
    pass


class Updater:
    def __init__(self, storage_root: str, repo: str) -> None:
        self.dir = os.path.join(storage_root, "update")
        self.repo = repo
        os.makedirs(self.dir, exist_ok=True)

    # ---- стан -------------------------------------------------------------------------------
    def status(self) -> dict:
        try:
            with open(os.path.join(self.dir, "status.json"), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {"state": "idle"}

    @staticmethod
    def installed_build() -> str | None:
        """Тег релізу, з якого встановлено ПЗ (пише install.sh)."""
        for p in ("/opt/sdrwatch/BUILD", os.path.join(os.path.dirname(__file__), "..", "BUILD")):
            try:
                with open(p) as f:
                    return f.read().strip() or None
            except OSError:
                continue
        return None

    # ---- приймання файлу ------------------------------------------------------------------------
    def stage(self, kind: str, data: bytes, sha256: str, tag: str = "") -> dict:
        if kind not in KINDS:
            raise UpdateError("Невідомий тип оновлення")
        if self.status().get("state") == "running":
            raise UpdateError("Оновлення вже виконується")
        _, fname, max_size = KINDS[kind]
        if not data or len(data) > max_size:
            raise UpdateError("Файл порожній або завеликий")
        digest = hashlib.sha256(data).hexdigest()
        if digest.lower() != sha256.strip().lower():
            raise UpdateError("Контрольна сума не збігається — файл пошкоджено під час передачі")
        if kind == "hackrf" and not _looks_like_hackrf_fw(data):
            raise UpdateError("Це не схоже на прошивку HackRF One")
        if kind == "pi" and data[:2] != b"\x1f\x8b":
            raise UpdateError("Очікувався архів .tar.gz")
        path = os.path.join(self.dir, fname)
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
        req = {"kind": kind, "file": path, "sha256": digest, "tag": tag, "ts": time.time()}
        self._write("status.json", {"state": "queued", "kind": kind, "tag": tag, "ts": time.time(),
                                    "message": "Очікує встановлення"})
        # Запис request.json запускає sdrwatch-update.path → sdrwatch-update.service (root)
        self._write("request.json", req)
        return req

    def _write(self, name: str, obj: dict) -> None:
        p = os.path.join(self.dir, name)
        with open(p + ".tmp", "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(p + ".tmp", p)

    # ---- завантаження з GitHub самим модулем ------------------------------------------------------
    def latest(self) -> dict:
        """Останні релізи для кожного типу: {kind: {tag, url, sha256_url}}."""
        url = f"https://api.github.com/repos/{self.repo}/releases?per_page=30"
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "User-Agent": "sdrwatch"})
        with urllib.request.urlopen(req, timeout=15) as r:
            releases = json.load(r)
        out: dict = {}
        for rel in releases:
            for kind, (prefix, fname, _) in KINDS.items():
                if kind in out or not rel.get("tag_name", "").startswith(prefix):
                    continue
                assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
                if fname in assets:
                    out[kind] = {"tag": rel["tag_name"], "url": assets[fname],
                                 "sha256_url": assets.get(fname + ".sha256")}
        return out

    def fetch_and_stage(self, kind: str) -> dict:
        rel = self.latest().get(kind)
        if not rel:
            raise UpdateError("Реліз не знайдено")
        data = _get(rel["url"], KINDS[kind][2])
        if rel.get("sha256_url"):
            sha = _get(rel["sha256_url"], 4096).decode().split()[0]
        else:
            raise UpdateError("У релізі немає контрольної суми")
        return self.stage(kind, data, sha, rel["tag"])


def _get(url: str, limit: int) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "sdrwatch"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise UpdateError("Файл завеликий")
    return data


def _looks_like_hackrf_fw(data: bytes) -> bool:
    """Образ LPC43xx: таблиця векторів на початку — початковий стек у SRAM (0x10xxxxxx / 0x20xxxxxx).
    Підходить і офіційна прошивка (щоб можна було повернутися на неї)."""
    if len(data) < 16 * 1024:
        return False
    sp = int.from_bytes(data[0:4], "little")
    return (sp >> 24) in (0x10, 0x20)
