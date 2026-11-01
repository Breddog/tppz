"""Відомі сітки каналів FPV-відео та діапазони лінків керування.

Використовується для:
  * співставлення знайденої частоти з відомим каналом (напр. «R4 5769 МГц, +1.2 МГц»);
  * точного доналаштування (знайдений сигнал «притягується» до каналу, далі AFC);
  * пріоритетного пошуку при втраті сигналу — спершу скануються канали тієї ж сітки.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass

MHZ = 1e6


@dataclass(frozen=True)
class Channel:
    band: str          # код сітки, напр. "R"
    name: str          # напр. "R4"
    freq_hz: float
    kind: str          # "analog", "digital", "wifi"


@dataclass(frozen=True)
class Band:
    code: str
    title: str
    kind: str
    freqs_mhz: tuple[float, ...]
    bandwidth_hz: float = 18 * MHZ

    def channels(self) -> list[Channel]:
        return [Channel(self.code, self.channel_name(i), f * MHZ, self.kind) for i, f in enumerate(self.freqs_mhz)]

    def channel_name(self, i: int) -> str:
        if self.code == "WIFI":
            return f"Wi-Fi {i + 1}"
        if self.code[-1].isdigit():
            return f"{self.code}-{i + 1}"
        return f"{self.code}{i + 1}"


# Сітки й лінки — з бази data/channels.json (оновлюється з застосунку без перепрошивки, див. load()).
BANDS: list[Band] = []
ALL_CHANNELS: list[Channel] = []
BAND_BY_CODE: dict[str, Band] = {}
DB_INFO: dict = {"version": 0}

@dataclass(frozen=True)
class LinkRange:
    name: str
    start_hz: float
    stop_hz: float
    kind: str  # "control", "telemetry", "video", "wifi"


# Діапазони, у яких працюють типові лінки керування та телеметрії (заповнює load())
LINK_RANGES: list[LinkRange] = []


# Відомі «фонові» служби: на повному діапазоні вони завжди є в ефірі й не є загрозою.
# Сигнали тут класифікуються як known_service (без сповіщень), якщо не схожі на FPV-відео/керування.
SERVICE_RANGES: list[LinkRange] = [
    LinkRange("КХ / СВ / ДВ мовлення", 0.1e6, 30e6, "service"),
    LinkRange("FM-радіо", 87.5e6, 108e6, "service"),
    LinkRange("Авіація (AM)", 108e6, 137e6, "service"),
    LinkRange("Метеосупутники / УКХ зв'язок", 137e6, 174e6, "service"),
    LinkRange("DAB / ТБ VHF", 174e6, 240e6, "service"),
    LinkRange("ТБ DVB-T2", 470e6, 790e6, "service"),
    LinkRange("LTE 800 (база)", 791e6, 821e6, "service"),
    LinkRange("GSM/LTE 900 (база)", 925e6, 960e6, "service"),
    LinkRange("ADS-B / DME / SSR", 960e6, 1215e6, "service"),
    LinkRange("GNSS (GPS/Galileo/ГЛОНАСС)", 1164e6, 1300e6, "service"),
    LinkRange("Inmarsat / Iridium", 1525e6, 1660e6, "service"),
    LinkRange("GSM/LTE 1800 (база)", 1805e6, 1880e6, "service"),
    LinkRange("UMTS/LTE 2100 (база)", 2110e6, 2170e6, "service"),
    LinkRange("LTE 2600 (база)", 2620e6, 2690e6, "service"),
    LinkRange("Радари S-діапазону", 2700e6, 3100e6, "service"),
    LinkRange("5G NR n78", 3400e6, 3800e6, "service"),
]


def service_for(freq_hz: float) -> LinkRange | None:
    for r in SERVICE_RANGES:
        if r.start_hz <= freq_hz <= r.stop_hz:
            return r
    return None


@dataclass
class ChannelMatch:
    channel: Channel
    offset_hz: float

    def to_dict(self) -> dict:
        return {
            "band": self.channel.band,
            "band_title": BAND_BY_CODE[self.channel.band].title,
            "name": self.channel.name,
            "freq_hz": self.channel.freq_hz,
            "offset_hz": round(self.offset_hz),
            "kind": self.channel.kind,
        }


# Рідковживані сітки програють популярним (R, F, A, B, E), якщо відхилення схожі (заповнює load())
BAND_PENALTY_HZ: dict[str, float] = {}


def match_channel(freq_hz: float, bandwidth_hz: float = 0.0, kind: str | None = None,
                  tolerance_hz: float = 4 * MHZ) -> ChannelMatch | None:
    """Найближчий відомий канал у межах допуску.

    kind: "analog" / "digital" / "wifi" — обмежити тип сітки.
    Для цифрових сигналів ширина смуги допомагає обрати 20 чи 40 МГц сітку.
    """
    def score(c: Channel) -> float:
        band = BAND_BY_CODE[c.band]
        s = abs(freq_hz - c.freq_hz) + BAND_PENALTY_HZ.get(c.band, 0.0)
        if bandwidth_hz and band.kind != "analog":
            s += abs(band.bandwidth_hz - bandwidth_hz) * 0.05
        return s

    cands = [c for c in ALL_CHANNELS if (not kind or c.kind == kind) and abs(freq_hz - c.freq_hz) <= tolerance_hz]
    if not cands:
        return None
    best = min(cands, key=score)
    return ChannelMatch(best, freq_hz - best.freq_hz)


def all_matches(freq_hz: float, tolerance_hz: float = 4 * MHZ) -> list[ChannelMatch]:
    """Усі канали, у які потрапляє частота (одна частота часто є в кількох сітках)."""
    res = [ChannelMatch(c, freq_hz - c.freq_hz) for c in ALL_CHANNELS if abs(freq_hz - c.freq_hz) <= tolerance_hz]
    return sorted(res, key=lambda m: abs(m.offset_hz))


def link_ranges_for(freq_hz: float) -> list[LinkRange]:
    return [r for r in LINK_RANGES if r.start_hz <= freq_hz <= r.stop_hz]


def priority_scan_list(freq_hz: float, kind: str = "analog", limit: int = 24) -> list[float]:
    """Частоти для пріоритетного пошуку після втрати сигналу.

    Спершу — канали тієї ж сітки (пілот міг перемкнути канал у межах band),
    потім — канали інших сіток поблизу, відсортовані за віддаленістю.
    """
    matches = all_matches(freq_hz, tolerance_hz=6 * MHZ)
    bands = [m.channel.band for m in matches if m.channel.kind == kind] or \
            [m.channel.band for m in matches]
    out: list[float] = [freq_hz]
    for code in bands:
        for ch in sorted(BAND_BY_CODE[code].channels(), key=lambda c: abs(c.freq_hz - freq_hz)):
            if ch.freq_hz not in out:
                out.append(ch.freq_hz)
    near = sorted((c for c in ALL_CHANNELS if c.kind == kind),
                  key=lambda c: abs(c.freq_hz - freq_hz))
    for ch in near:
        if ch.freq_hz not in out:
            out.append(ch.freq_hz)
        if len(out) >= limit:
            break
    return out[:limit]


def bands_as_dict() -> list[dict]:
    meta = {b["code"]: b for b in DB_INFO.get("bands", [])}
    return [{"code": b.code, "title": b.title, "kind": b.kind,
             "bandwidth_hz": b.bandwidth_hz,
             "makers": meta.get(b.code, {}).get("makers", []),
             "group": meta.get(b.code, {}).get("group", ""),
             "note": meta.get(b.code, {}).get("note", ""),
             "popular": meta.get(b.code, {}).get("popular", False),
             "channels": [{"name": c.name, "freq_hz": c.freq_hz} for c in b.channels()]}
            for b in BANDS]


# ---- база сіток -----------------------------------------------------------------------
BUNDLED_DB = os.path.join(os.path.dirname(__file__), "data", "channels.json")
USER_DB_NAME = "channels.json"     # оновлена база в теці сховища модуля


def validate(db: dict) -> dict:
    """Перевірка бази перед застосуванням (щоб зламаний файл не «осліпив» модуль)."""
    if not isinstance(db, dict) or not isinstance(db.get("bands"), list) or not db["bands"]:
        raise ValueError("База сіток: немає списку bands")
    int(db.get("version", 0))
    codes = set()
    for b in db["bands"]:
        if not b.get("code") or not b.get("title") or b.get("kind") not in ("analog", "digital", "wifi"):
            raise ValueError(f"База сіток: неповна сітка {b.get('code')!r}")
        if b["code"] in codes:
            raise ValueError(f"База сіток: повтор коду {b['code']}")
        codes.add(b["code"])
        fs = [float(f) for f in b.get("freqs_mhz", [])]
        if not fs or any(not (1 <= f <= 12000) for f in fs):
            raise ValueError(f"База сіток: невірні частоти в {b['code']}")
    for r in db.get("links", []):
        if float(r["start_mhz"]) >= float(r["stop_mhz"]):
            raise ValueError(f"База сіток: невірний діапазон лінку {r.get('name')}")
    return db


def apply(db: dict) -> None:
    """Застосувати базу: списки оновлюються НА МІСЦІ (інші модулі тримають на них посилання)."""
    validate(db)
    bands = [Band(b["code"], b["title"], b["kind"], tuple(float(f) for f in b["freqs_mhz"]),
                  float(b.get("bandwidth_mhz", 18)) * MHZ) for b in db["bands"]]
    BANDS[:] = bands
    ALL_CHANNELS[:] = [c for b in bands for c in b.channels()]
    BAND_BY_CODE.clear()
    BAND_BY_CODE.update({b.code: b for b in bands})
    LINK_RANGES[:] = [LinkRange(r["name"], float(r["start_mhz"]) * MHZ, float(r["stop_mhz"]) * MHZ,
                                r.get("kind", "control")) for r in db.get("links", [])]
    BAND_PENALTY_HZ.clear()
    BAND_PENALTY_HZ.update({b["code"]: 1.5e6 for b in db["bands"] if not b.get("popular")
                            and b["kind"] == "analog"})
    DB_INFO.clear()
    DB_INFO.update(db)


def load(storage_path: str | None = None) -> dict:
    """Вбудована база або новіша з теки сховища (якщо її оновили з застосунку)."""
    with open(BUNDLED_DB, encoding="utf-8") as f:
        db = json.load(f)
    if storage_path:
        p = os.path.join(storage_path, USER_DB_NAME)
        try:
            with open(p, encoding="utf-8") as f:
                user = validate(json.load(f))
            if int(user.get("version", 0)) >= int(db.get("version", 0)):
                db = user
        except FileNotFoundError:
            pass
        except (OSError, ValueError, KeyError, TypeError) as e:
            import logging
            logging.getLogger(__name__).warning("Оновлена база сіток пошкоджена (%s) — беру вбудовану", e)
    apply(db)
    return db


def save_user_db(storage_path: str, db: dict) -> None:
    validate(db)
    os.makedirs(storage_path, exist_ok=True)
    p = os.path.join(storage_path, USER_DB_NAME)
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False)
    os.replace(p + ".tmp", p)


load()   # вбудована база — одразу при імпорті
