"""Відстеження сигналів між проходами сканування.

* Кандидат → підтверджений лише після N влучань: поодинокі шумові сплески відкидаються.
* Вузькі стрибкоподібні сигнали в діапазоні лінку керування збираються в один
  «FHSS-трек» (ELRS/Crossfire), а не сотні окремих частот.
* Втрата — якщо сигналу немає довше lost_timeout_s; для відео запускається
  пріоритетний пошук по сітці каналів.
"""

from __future__ import annotations

import itertools
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Callable

from . import channels as ch
from .distance import RssiKalman
from .dsp.classifier import Classification
from .dsp.spectrum import Detection

_ids = itertools.count(1)


@dataclass
class Track:
    id: str
    freq_hz: float
    bandwidth_hz: float
    first_seen: float
    last_seen: float
    range_name: str
    peak_dbm: float = -200.0
    snr_db: float = 0.0
    flatness: float = 0.0
    edge: float = 0.0
    hits: int = 0
    misses: int = 0
    presence: float = 1.0
    state: str = "candidate"            # candidate | confirmed | lost
    fhss_key: str | None = None
    hop_freqs: deque = field(default_factory=lambda: deque(maxlen=40))
    hop_bw_hz: float = 0.0              # ширина одного «стрибка» FHSS
    classification: Classification | None = None
    last_analysis: float = 0.0
    video: dict | None = None
    iq: dict | None = None
    distance: dict | None = None
    kalman: RssiKalman = field(default_factory=RssiKalman)
    rssi_smooth: float = -200.0
    rssi_slope: float = 0.0
    rssi_history: deque = field(default_factory=lambda: deque(maxlen=120))
    iq_obj: object = None               # останні IqFeatures / VideoResult — для дешевої перекласифікації
    video_obj: object = None
    thumbnail_id: int | None = None
    event_id: int | None = None

    @property
    def hopping(self) -> bool:
        if not self.fhss_key:
            return False
        if len(self.hop_freqs) < 3:
            return False
        # Стабільна несуча завжди на одній частоті; FHSS «розкидано» далеко за межі своєї смуги
        return bool(max(self.hop_freqs) - min(self.hop_freqs) > max(3 * self.hop_bw_hz, 1.5e6))

    def channel(self) -> dict | None:
        if self.fhss_key:
            return None
        kind = None
        if self.classification:
            kind = {"analog": "analog", "digital": "digital", "wifi": "wifi"}.get(
                self.classification.code.split("_")[0])
        m = ch.match_channel(self.freq_hz, self.bandwidth_hz, kind=kind)
        return m.to_dict() if m else None

    def hint(self) -> str:
        """Коротка підказка для користувача, який не розбирається в радіо."""
        c = self.classification
        parts = [f"{self.freq_hz / 1e6:.1f} МГц"]
        chm = self.channel()
        if chm:
            parts[0] += f" ({chm['name']})"
        parts.append(c.label + (f": {c.subtype}" if c and c.subtype else "") if c else "аналізується…")
        if self.distance:
            parts.append(self.distance["text"])
        strength = "дуже сильний" if self.snr_db > 35 else "сильний" if self.snr_db > 22 else \
            "середній" if self.snr_db > 14 else "слабкий"
        parts.append(f"сигнал {strength}")
        return " — ".join(parts)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "freq_hz": round(self.freq_hz),
            "bandwidth_hz": round(self.bandwidth_hz),
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "range": self.range_name,
            "state": self.state,
            "peak_dbm": round(self.peak_dbm, 1),
            "rssi_dbm": round(self.rssi_smooth, 1),
            "snr_db": round(self.snr_db, 1),
            "presence": round(self.presence, 2),
            "hopping": self.hopping,
            "hop_bandwidth_hz": round(self.hop_bw_hz),
            "hop_span_hz": (round(max(self.hop_freqs) - min(self.hop_freqs)) if self.hop_freqs else 0),
            "class": self.classification.to_dict() if self.classification else None,
            "channel": self.channel(),
            "video": self.video,
            "iq": self.iq,
            "distance": self.distance,
            "hint": self.hint(),
            "thumbnail_id": self.thumbnail_id,
            "event_id": self.event_id,
        }


class Tracker:
    def __init__(self, confirm_hits: int = 3, lost_timeout_s: float = 6.0) -> None:
        self.confirm_hits = confirm_hits
        self.lost_timeout_s = lost_timeout_s
        self.tracks: dict[str, Track] = {}
        self.listeners: list[Callable[[str, Track], None]] = []

    def _emit(self, kind: str, t: Track) -> None:
        for cb in self.listeners:
            cb(kind, t)

    @staticmethod
    def fhss_key_for(d: Detection) -> str | None:
        if d.bandwidth_hz > 3e6:
            return None
        for r in ch.link_ranges_for(d.freq_hz):
            if r.kind == "control":
                return f"fhss:{r.name}"
        return None

    def _match(self, d: Detection, range_name: str) -> Track | None:
        key = self.fhss_key_for(d)
        best, best_off = None, None
        for t in self.tracks.values():
            if t.state == "lost" and t.range_name != range_name:
                continue
            if key and t.fhss_key == key:
                return t
            if t.fhss_key:
                continue
            tol = max(1.0e6, 0.4 * max(t.bandwidth_hz, d.bandwidth_hz))
            off = abs(t.freq_hz - d.freq_hz)
            if off <= tol and (best_off is None or off < best_off):
                best, best_off = t, off
        return best

    def update(self, dets: list[Detection], range_name: str, lo_hz: float, hi_hz: float,
               gain_offset_db: float, now: float | None = None,
               lost_timeout_s: float | None = None) -> list[Track]:
        """Оновити треки результатами одного проходу діапазону. Повертає треки, що потребують аналізу."""
        now = time.time() if now is None else now
        lost_timeout = self.lost_timeout_s if lost_timeout_s is None else lost_timeout_s
        seen: set[str] = set()
        for d in dets:
            t = self._match(d, range_name)
            key = self.fhss_key_for(d)
            if t is None:
                t = Track(id=f"s{next(_ids)}", freq_hz=d.freq_hz, bandwidth_hz=d.bandwidth_hz,
                          first_seen=now, last_seen=now, range_name=range_name, fhss_key=key)
                self.tracks[t.id] = t
            if t.id in seen:  # той самий FHSS-трек кілька разів за прохід
                t.hop_freqs.append(d.freq_hz)
                t.peak_dbm = max(t.peak_dbm, d.peak_dbfs + gain_offset_db)
                continue
            seen.add(t.id)
            rssi = d.power_dbfs + gain_offset_db
            if t.fhss_key:
                t.hop_freqs.append(d.freq_hz)
                t.hop_bw_hz = d.bandwidth_hz if not t.hop_bw_hz else 0.8 * t.hop_bw_hz + 0.2 * d.bandwidth_hz
                t.freq_hz = (min(t.hop_freqs) + max(t.hop_freqs)) / 2
                t.bandwidth_hz = max(d.bandwidth_hz, max(t.hop_freqs) - min(t.hop_freqs) + d.bandwidth_hz)
            else:
                a = 0.3 if t.state == "confirmed" else 0.6
                t.freq_hz += a * (d.freq_hz - t.freq_hz)
                t.bandwidth_hz += a * (d.bandwidth_hz - t.bandwidth_hz)
            t.peak_dbm = rssi
            t.snr_db = d.snr_db
            t.flatness, t.edge = d.flatness, d.edge_db_per_mhz
            t.rssi_smooth, t.rssi_slope = t.kalman.update(rssi, now)
            t.rssi_history.append((now, round(rssi, 1)))
            t.hits += 1
            t.presence = 0.8 * t.presence + 0.2
            t.last_seen = now
            if t.state == "lost":
                t.state = "confirmed"
                self._emit("reacquired", t)
            elif t.state == "candidate" and t.hits >= self.confirm_hits:
                t.state = "confirmed"
                self._emit("new", t)

        # Треки цього діапазону, яких не було в проході
        for t in list(self.tracks.values()):
            if t.id in seen or not (lo_hz <= t.freq_hz <= hi_hz) or t.range_name != range_name:
                continue
            t.misses += 1
            t.presence *= 0.8
            if t.state == "candidate" and t.misses - t.hits > self.confirm_hits + 1:
                del self.tracks[t.id]  # шум — тихо прибрати
            elif t.state == "confirmed" and now - t.last_seen > lost_timeout:
                t.state = "lost"
                self._emit("lost", t)
            elif t.state == "lost" and now - t.last_seen > 600:
                del self.tracks[t.id]

        return [t for t in self.tracks.values()
                if t.state != "lost" and t.id in seen and (t.classification is None or now - t.last_analysis > 15)]

    def set_classification(self, t: Track, c: Classification) -> None:
        old = t.classification
        t.classification = c
        if t.state == "confirmed" and old is not None and old.code != c.code:
            self._emit("changed", t)

    def active(self) -> list[Track]:
        out = [t for t in self.tracks.values() if t.state in ("confirmed", "lost")]
        return sorted(out, key=lambda t: (t.state != "confirmed",
                                          -(t.classification.priority if t.classification else 0),
                                          -t.snr_db))
