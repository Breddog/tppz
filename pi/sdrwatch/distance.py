"""Приблизна оцінка відстані до джерела сигналу.

Методи:
  1. Логарифмічна модель загасання: RSSI = EIRP − FSPL(1 м, f) − 10·n·lg(d) + Gr.
     EIRP невідома, тому береться типовий діапазон потужностей для класу сигналу
     (напр. аналоговий VTX 25 мВт…1.6 Вт) → результат «мін / ймовірна / макс».
  2. Калібрування: якщо користувач зробив калібрування відомим передавачем на відомій
     відстані — поправка rx_cal_db уточнює абсолютний RSSI.
  3. Згладжування фільтром Калмана по RSSI і тренд: наближається / віддаляється.
Це орієнтир, а не вимір: відбиття, перешкоди та антени можуть дати похибку в рази.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass

# Типові EIRP (дБм): мінімальна, типова, максимальна
TX_PROFILES: dict[str, tuple[float, float, float]] = {
    "analog_video": (14, 27, 33),           # 25 мВт … 500 мВт … 2 Вт (з антеною)
    "analog_video_inverted": (14, 27, 33),
    "analog_video_scrambled": (14, 27, 33),
    "analog_video_weak": (14, 27, 33),
    "digital_video": (14, 25, 31),          # DJI/Walksnail ~25 мВт…1 Вт
    "control_link": (10, 22, 32),           # ELRS 10 мВт … 1 Вт
    "telemetry": (10, 20, 30),
    "wifi": (10, 18, 23),
    "wideband_unknown": (10, 23, 33),
    "carrier": (0, 15, 30),
    "unknown": (0, 15, 30),
}


def fspl_1m_db(freq_hz: float) -> float:
    return 20 * math.log10(freq_hz) - 147.55


def distance_m(rssi_dbm: float, freq_hz: float, eirp_dbm: float, n: float, rx_gain_dbi: float) -> float:
    pl = eirp_dbm + rx_gain_dbi - rssi_dbm
    return 10 ** ((pl - fspl_1m_db(freq_hz)) / (10 * n))


def dbfs_to_dbm(dbfs: float, total_gain_db: float, cal_db: float) -> float:
    return dbfs - total_gain_db + cal_db


@dataclass
class DistanceEstimate:
    min_m: float
    likely_m: float
    max_m: float
    rssi_dbm: float
    trend: str            # "approaching" | "receding" | "steady"
    trend_db_per_s: float

    def to_dict(self) -> dict:
        return {"min_m": round(self.min_m), "likely_m": round(self.likely_m), "max_m": round(self.max_m),
                "rssi_dbm": round(self.rssi_dbm, 1), "trend": self.trend,
                "trend_db_per_s": round(self.trend_db_per_s, 2), "text": self.text()}

    def text(self) -> str:
        def f(m: float) -> str:
            return f"{m / 1000:.1f} км" if m >= 1000 else f"{m:.0f} м"
        arrow = {"approaching": " ▲ наближається", "receding": " ▼ віддаляється"}.get(self.trend, "")
        return f"≈{f(self.likely_m)} ({f(self.min_m)}–{f(self.max_m)}){arrow}"


class RssiKalman:
    """1D фільтр Калмана: стан = [RSSI, швидкість зміни RSSI]."""

    def __init__(self, q: float = 0.5, r: float = 4.0) -> None:
        self.q, self.r = q, r
        self.x: list[float] | None = None
        self.p = [[10.0, 0.0], [0.0, 1.0]]
        self.t = 0.0

    def update(self, z: float, t: float | None = None) -> tuple[float, float]:
        t = time.monotonic() if t is None else t
        if self.x is None:
            self.x, self.t = [z, 0.0], t
            return z, 0.0
        dt = max(1e-3, t - self.t)
        self.t = t
        x0 = self.x[0] + dt * self.x[1]
        x1 = self.x[1]
        p = self.p
        p00 = p[0][0] + dt * (p[1][0] + p[0][1]) + dt * dt * p[1][1] + self.q * dt
        p01 = p[0][1] + dt * p[1][1]
        p10 = p[1][0] + dt * p[1][1]
        p11 = p[1][1] + self.q * dt * 0.1
        k0 = p00 / (p00 + self.r)
        k1 = p10 / (p00 + self.r)
        y = z - x0
        self.x = [x0 + k0 * y, x1 + k1 * y]
        self.p = [[(1 - k0) * p00, (1 - k0) * p01], [p10 - k1 * p00, p11 - k1 * p01]]
        return self.x[0], self.x[1]


def estimate(class_code: str, freq_hz: float, rssi_dbm: float, slope_db_per_s: float,
             n: float, rx_gain_dbi: float) -> DistanceEstimate:
    lo, typ, hi = TX_PROFILES.get(class_code, TX_PROFILES["unknown"])
    d_min = distance_m(rssi_dbm, freq_hz, lo, n, rx_gain_dbi)
    d_typ = distance_m(rssi_dbm, freq_hz, typ, n, rx_gain_dbi)
    d_max = distance_m(rssi_dbm, freq_hz, hi, n, rx_gain_dbi)
    trend = "approaching" if slope_db_per_s > 0.8 else "receding" if slope_db_per_s < -0.8 else "steady"
    clamp = lambda v: max(1.0, min(v, 100_000.0))  # noqa: E731
    return DistanceEstimate(clamp(d_min), clamp(d_typ), clamp(d_max), rssi_dbm, trend, slope_db_per_s)


def calibrate(measured_dbfs: float, total_gain_db: float, freq_hz: float, distance: float,
              eirp_dbm: float, n: float, rx_gain_dbi: float) -> float:
    """Повертає нове rx_cal_db за відомим передавачем на відомій відстані."""
    expected_dbm = eirp_dbm + rx_gain_dbi - fspl_1m_db(freq_hz) - 10 * n * math.log10(max(distance, 0.1))
    return expected_dbm - (measured_dbfs - total_gain_db)
