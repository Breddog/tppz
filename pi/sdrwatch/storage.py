"""Кільцеве сховище на флешці (як у відеореєстраторі).

Під запис виділяється quota_mb. Коли місце закінчується — найстаріші файли
(кліпи відео, мініатюри, архів водоспаду) видаляються першими, а записи подій
лишаються (вони маленькі) з позначкою «медіа перезаписано».
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time

import numpy as np

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    kind TEXT NOT NULL,
    track_id TEXT,
    freq_hz REAL,
    class_code TEXT,
    label TEXT,
    priority INTEGER DEFAULT 0,
    data TEXT
);
CREATE INDEX IF NOT EXISTS ev_ts ON events(ts);
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    kind TEXT NOT NULL,          -- thumb | clip | spectrum | waterfall
    path TEXT NOT NULL,
    size INTEGER NOT NULL,
    event_id INTEGER,
    meta TEXT
);
CREATE INDEX IF NOT EXISTS files_ts ON files(ts);
CREATE INDEX IF NOT EXISTS files_ev ON files(event_id);
"""

MAX_EVENTS = 200_000


class Storage:
    def __init__(self, root: str, quota_mb: int = 2048) -> None:
        self.root = root
        self.quota_bytes = int(quota_mb) * 1024 * 1024
        os.makedirs(root, exist_ok=True)
        for sub in ("thumbs", "clips", "spectra", "waterfall"):
            os.makedirs(os.path.join(root, sub), exist_ok=True)
        self._lock = threading.RLock()
        self.db = sqlite3.connect(os.path.join(root, "sdrwatch.db"), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.execute("PRAGMA journal_mode=WAL")
        self._used = self._calc_used()

    # ---- облік місця --------------------------------------------------------
    def _calc_used(self) -> int:
        r = self.db.execute("SELECT COALESCE(SUM(size),0) FROM files").fetchone()
        return int(r[0])

    def usage(self) -> dict:
        with self._lock:
            n_ev = self.db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            n_f = self.db.execute("SELECT COUNT(*) FROM files").fetchone()[0]
            oldest = self.db.execute("SELECT MIN(ts) FROM files").fetchone()[0]
        try:
            st = os.statvfs(self.root)
            disk_free = st.f_bavail * st.f_frsize
        except OSError:
            disk_free = 0
        return {"used_bytes": self._used, "quota_bytes": self.quota_bytes, "events": n_ev,
                "files": n_f, "oldest_media_ts": oldest, "disk_free_bytes": disk_free}

    def set_quota(self, quota_mb: int) -> None:
        self.quota_bytes = int(quota_mb) * 1024 * 1024
        self._enforce()

    def _enforce(self, incoming: int = 0) -> None:
        with self._lock:
            # Не дати флешці заповнитися повністю, навіть якщо квота більша за вільне місце
            try:
                st = os.statvfs(self.root)
                hard = self._used + st.f_bavail * st.f_frsize - 200 * 1024 * 1024
            except OSError:
                hard = self.quota_bytes
            limit = min(self.quota_bytes, max(hard, 10 * 1024 * 1024))
            while self._used + incoming > limit:
                rows = self.db.execute("SELECT id, path, size FROM files ORDER BY ts ASC LIMIT 50").fetchall()
                if not rows:
                    break
                for r in rows:
                    try:
                        os.remove(os.path.join(self.root, r["path"]))
                    except FileNotFoundError:
                        pass
                    self.db.execute("DELETE FROM files WHERE id=?", (r["id"],))
                    self._used -= int(r["size"])
                    if self._used + incoming <= limit:
                        break
            self.db.commit()
            n = self.db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            if n > MAX_EVENTS:
                self.db.execute("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY id LIMIT ?)",
                                (n - MAX_EVENTS,))
                self.db.commit()

    # ---- файли ----------------------------------------------------------------
    def add_file(self, kind: str, rel_path: str, data: bytes, event_id: int | None = None,
                 meta: dict | None = None) -> int:
        self._enforce(len(data))
        full = os.path.join(self.root, rel_path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)
        return self.register_file(kind, rel_path, len(data), event_id, meta)

    def register_file(self, kind: str, rel_path: str, size: int, event_id: int | None = None,
                      meta: dict | None = None) -> int:
        with self._lock:
            cur = self.db.execute(
                "INSERT INTO files(ts, kind, path, size, event_id, meta) VALUES (?,?,?,?,?,?)",
                (time.time(), kind, rel_path, size, event_id, json.dumps(meta or {}, ensure_ascii=False)))
            self.db.commit()
            self._used += size
            return int(cur.lastrowid)

    def update_file(self, file_id: int, size: int, meta: dict) -> None:
        with self._lock:
            old = self.db.execute("SELECT size FROM files WHERE id=?", (file_id,)).fetchone()
            if not old:
                return
            self.db.execute("UPDATE files SET size=?, meta=? WHERE id=?",
                            (size, json.dumps(meta, ensure_ascii=False), file_id))
            self.db.commit()
            self._used += size - int(old["size"])
        self._enforce()

    def get_file(self, file_id: int) -> dict | None:
        with self._lock:
            r = self.db.execute("SELECT * FROM files WHERE id=?", (file_id,)).fetchone()
        if not r:
            return None
        d = dict(r)
        d["meta"] = json.loads(d["meta"] or "{}")
        d["full_path"] = os.path.join(self.root, d["path"])
        return d

    def files_for_event(self, event_id: int) -> list[dict]:
        with self._lock:
            rows = self.db.execute("SELECT id, ts, kind, size, meta FROM files WHERE event_id=?",
                                   (event_id,)).fetchall()
        return [{**dict(r), "meta": json.loads(r["meta"] or "{}")} for r in rows]

    # ---- події ----------------------------------------------------------------
    def add_event(self, kind: str, track: dict) -> int:
        cls = track.get("class") or {}
        with self._lock:
            cur = self.db.execute(
                "INSERT INTO events(ts, kind, track_id, freq_hz, class_code, label, priority, data) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (time.time(), kind, track.get("id"), track.get("freq_hz"), cls.get("code"), cls.get("label"),
                 cls.get("priority", 0), json.dumps(track, ensure_ascii=False)))
            self.db.commit()
            return int(cur.lastrowid)

    def link_file(self, file_id: int, event_id: int) -> None:
        with self._lock:
            self.db.execute("UPDATE files SET event_id=? WHERE id=?", (event_id, file_id))
            self.db.commit()

    def events(self, since_id: int = 0, before_id: int | None = None, limit: int = 100,
               min_priority: int = 0, class_code: str | None = None, ts_from: float | None = None,
               ts_to: float | None = None) -> list[dict]:
        q = "SELECT * FROM events WHERE id > ? AND priority >= ?"
        args: list = [since_id, min_priority]
        if before_id:
            q += " AND id < ?"
            args.append(before_id)
        if class_code:
            q += " AND class_code = ?"
            args.append(class_code)
        if ts_from:
            q += " AND ts >= ?"
            args.append(ts_from)
        if ts_to:
            q += " AND ts <= ?"
            args.append(ts_to)
        q += " ORDER BY id DESC LIMIT ?" if not since_id else " ORDER BY id ASC LIMIT ?"
        args.append(min(int(limit), 1000))
        with self._lock:
            rows = self.db.execute(q, args).fetchall()
            out = []
            for r in rows:
                d = dict(r)
                d["data"] = json.loads(d["data"] or "{}")
                media = self.db.execute("SELECT id, kind FROM files WHERE event_id=?", (d["id"],)).fetchall()
                d["media"] = [dict(m) for m in media]
                out.append(d)
        return out

    def event(self, event_id: int) -> dict | None:
        with self._lock:
            r = self.db.execute("SELECT * FROM events WHERE id=?", (event_id,)).fetchone()
        if not r:
            return None
        d = dict(r)
        d["data"] = json.loads(d["data"] or "{}")
        d["media"] = self.files_for_event(event_id)
        return d

    def clear(self) -> None:
        with self._lock:
            for r in self.db.execute("SELECT path FROM files").fetchall():
                try:
                    os.remove(os.path.join(self.root, r["path"]))
                except FileNotFoundError:
                    pass
            self.db.execute("DELETE FROM files")
            self.db.execute("DELETE FROM events")
            self.db.commit()
            self._used = 0

    # ---- архів водоспаду -----------------------------------------------------------
    def save_waterfall(self, range_name: str, f_start: float, f_stop: float,
                       rows: list[tuple[float, np.ndarray]]) -> int | None:
        if not rows:
            return None
        ts = np.array([r[0] for r in rows])
        data = np.stack([r[1] for r in rows]).astype(np.float32)
        # Квантування в 0.5 дБ (uint8 від -140 дБм) — у 4 рази менше місця
        q = np.clip((data + 140) * 2, 0, 255).astype(np.uint8)
        import io
        buf = io.BytesIO()
        np.savez_compressed(buf, ts=ts, q=q)
        safe = "".join(c if c.isalnum() else "_" for c in range_name)[:40]
        rel = f"waterfall/{safe}/{int(ts[0])}.npz"
        return self.add_file("waterfall", rel, buf.getvalue(),
                             meta={"range": range_name, "f_start": f_start, "f_stop": f_stop,
                                   "ts_from": float(ts[0]), "ts_to": float(ts[-1]), "rows": len(rows)})

    def waterfall(self, range_name: str, ts_from: float, ts_to: float, max_rows: int = 400) -> dict:
        with self._lock:
            rows = self.db.execute("SELECT * FROM files WHERE kind='waterfall' ORDER BY ts").fetchall()
        tss, datas, f_start, f_stop = [], [], None, None
        for r in rows:
            meta = json.loads(r["meta"] or "{}")
            if meta.get("range") != range_name or meta.get("ts_to", 0) < ts_from or meta.get("ts_from", 0) > ts_to:
                continue
            try:
                z = np.load(os.path.join(self.root, r["path"]))
            except (OSError, ValueError):
                continue
            sel = (z["ts"] >= ts_from) & (z["ts"] <= ts_to)
            tss.append(z["ts"][sel])
            datas.append(z["q"][sel])
            f_start, f_stop = meta["f_start"], meta["f_stop"]
        if not tss:
            return {"range": range_name, "rows": [], "ts": []}
        ts = np.concatenate(tss)
        q = np.concatenate(datas)
        if len(ts) > max_rows:
            idx = np.linspace(0, len(ts) - 1, max_rows).astype(int)
            ts, q = ts[idx], q[idx]
        return {"range": range_name, "f_start": f_start, "f_stop": f_stop, "ts": ts.tolist(),
                "rows": (q.astype(np.float32) / 2 - 140).round(1).tolist()}

    def waterfall_ranges(self) -> list[str]:
        with self._lock:
            rows = self.db.execute("SELECT DISTINCT json_extract(meta,'$.range') AS r FROM files "
                                   "WHERE kind='waterfall'").fetchall()
        return [r["r"] for r in rows if r["r"]]
