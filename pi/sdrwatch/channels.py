"""Відомі сітки каналів FPV-відео та діапазони лінків керування.

Використовується для:
  * співставлення знайденої частоти з відомим каналом (напр. «R4 5769 МГц, +1.2 МГц»);
  * точного доналаштування (знайдений сигнал «притягується» до каналу, далі AFC);
  * пріоритетного пошуку при втраті сигналу — спершу скануються канали тієї ж сітки.
"""

from __future__ import annotations

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


BANDS: list[Band] = [
    # ---- 5.8 ГГц аналогові FPV ------------------------------------------
    Band("A", "Boscam A", "analog", (5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725)),
    Band("B", "Boscam B", "analog", (5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866)),
    Band("E", "Boscam E", "analog", (5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945)),
    Band("F", "Fatshark / IRC", "analog", (5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880)),
    Band("R", "Raceband", "analog", (5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917)),
    Band("L", "Lowrace", "analog", (5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621)),
    Band("U", "Band U", "analog", (5325, 5348, 5366, 5384, 5402, 5420, 5438, 5456)),
    Band("O", "Band O", "analog", (5474, 5492, 5510, 5528, 5546, 5564, 5582, 5600)),
    Band("H", "Band H", "analog", (5653, 5693, 5733, 5773, 5813, 5853, 5893, 5933)),
    # ---- 1.2 / 1.3 ГГц аналогові ----------------------------------------
    Band("1G2", "1.2 ГГц (9 кан.)", "analog", (1080, 1120, 1160, 1200, 1240, 1258, 1280, 1320, 1360)),
    Band("1G3", "1.3 ГГц", "analog", (1010, 1040, 1080, 1120, 1160, 1200, 1240, 1280, 1320, 1360)),
    # ---- 3.3 ГГц аналогові ----------------------------------------------
    Band("3G3", "3.3 ГГц", "analog", (3330, 3350, 3370, 3390, 3410, 3430, 3450, 3470)),
    # ---- Цифрові відеосистеми (центри каналів, ширина 10/20/40 МГц) -------
    Band("DJI", "DJI FPV / O3 / O4 / Walksnail", "digital",
         (5660, 5695, 5735, 5770, 5805, 5839, 5878, 5914), bandwidth_hz=20 * MHZ),
    Band("DJI40", "DJI O3/O4 40 МГц", "digital", (5795,), bandwidth_hz=40 * MHZ),
    # ---- Wi-Fi 2.4 (джерело хибних тривог та також DJI/аналоги Wi-Fi FPV) --
    Band("WIFI", "Wi-Fi 2.4 ГГц", "wifi", tuple(2412 + 5 * i for i in range(13)), bandwidth_hz=20 * MHZ),
]

ALL_CHANNELS: list[Channel] = [c for b in BANDS for c in b.channels()]
BAND_BY_CODE = {b.code: b for b in BANDS}


@dataclass(frozen=True)
class LinkRange:
    name: str
    start_hz: float
    stop_hz: float
    kind: str  # "control", "telemetry", "video", "wifi"


# Діапазони, у яких працюють типові лінки керування та телеметрії
LINK_RANGES: list[LinkRange] = [
    LinkRange("ELRS / TBS Tracer / FrSky 2.4 ГГц", 2_400e6, 2_480e6, "control"),
    LinkRange("ELRS / Crossfire 868 МГц (EU)", 863e6, 870e6, "control"),
    LinkRange("ELRS / Crossfire 915 МГц", 902e6, 928e6, "control"),
    LinkRange("LRS 433 МГц", 430e6, 440e6, "control"),
    LinkRange("Телеметрія SiK/MAVLink 433", 433e6, 435e6, "telemetry"),
    LinkRange("Телеметрія SiK/MAVLink 868/915", 868e6, 928e6, "telemetry"),
    LinkRange("FPV відео 5.8 ГГц", 5_325e6, 5_950e6, "video"),
    LinkRange("FPV відео 1.2–1.3 ГГц", 1_000e6, 1_400e6, "video"),
    LinkRange("FPV відео 3.3 ГГц", 3_300e6, 3_500e6, "video"),
    LinkRange("DJI / Wi-Fi 5.1–5.3 ГГц", 5_150e6, 5_350e6, "video"),
]


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


# Рідковживані сітки програють популярним (R, F, A, B, E), якщо відхилення схожі
BAND_PENALTY_HZ = {"L": 1.5e6, "U": 1.5e6, "O": 1.5e6, "H": 1.5e6, "1G3": 0.5e6}


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
    return [{"code": b.code, "title": b.title, "kind": b.kind,
             "bandwidth_hz": b.bandwidth_hz,
             "channels": [{"name": c.name, "freq_hz": c.freq_hz} for c in b.channels()]}
            for b in BANDS]
