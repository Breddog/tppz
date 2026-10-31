"""Класифікація сигналів за спектральними, часовими та IQ-ознаками.

Ознаки:
  * ширина смуги, «плоскість» спектра, крутизна схилів (OFDM — плоска поличка з різкими краями);
  * огинаюча: FM-відео і LoRa/FLRC мають постійну огинаючу (CV≈0), OFDM — релеївську (CV≈0.5);
  * шпаруватість і стрибки частоти між проходами (FHSS-лінки керування);
  * рядкова синхронізація аналогового відео (див. video.py) — найнадійніша ознака;
  * збіг з відомою сіткою каналів і діапазонами лінків.
Навіть коли зображення показати неможливо (цифрове, кодоване), сигнал класифікується.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .. import channels as ch
from .filters import fir, lowpass_taps, mix

# code: (назва українською, пріоритет 0..2, чи можна показати відео)
CLASSES: dict[str, tuple[str, int, bool]] = {
    "analog_video": ("Аналогове FPV-відео", 2, True),
    "analog_video_inverted": ("Аналогове відео (інвертоване)", 2, True),
    "analog_video_scrambled": ("Аналогове відео (кодоване / скрембльоване)", 2, True),
    "analog_video_weak": ("Ймовірно аналогове відео (слабкий сигнал)", 2, False),
    "digital_video": ("Цифрове FPV-відео", 2, False),
    "control_link": ("Канал керування дроном", 2, False),
    "telemetry": ("Телеметрія / вузькосмуговий лінк", 1, False),
    "wifi": ("Wi-Fi / OFDM-пакети", 0, False),
    "wideband_unknown": ("Невідомий широкосмуговий сигнал", 1, False),
    "carrier": ("Несуча / вузькосмуговий сигнал", 0, False),
    "known_service": ("Відома служба (мовлення, мобільний зв'язок…)", 0, False),
    "unknown": ("Невідомий сигнал", 0, False),
}


@dataclass
class IqFeatures:
    envelope_cv: float = 0.0      # коефіцієнт варіації огинаючої
    duty: float = 1.0             # частка часу, коли сигнал присутній
    papr_db: float = 0.0

    def to_dict(self) -> dict:
        return {"envelope_cv": round(self.envelope_cv, 3), "duty": round(self.duty, 3),
                "papr_db": round(self.papr_db, 1)}


def iq_features(iq: np.ndarray, fs: float, offset_hz: float, bw_hz: float) -> IqFeatures:
    """Виділити сигнал фільтром і порахувати ознаки огинаючої."""
    x = mix(iq, offset_hz, fs)
    # Широкі сигнали не фільтруємо: обрізання бічних смуг FM дає хибну АМ-модуляцію
    if bw_hz * 1.5 < 0.8 * fs:
        cut = min(0.45, max(bw_hz * 0.75, 50e3) / fs)
        x = fir(x, lowpass_taps(cut, 63))
    env = np.abs(x)
    # Згладжування огинаючої ~ на тривалість 1/(2·смуга): прибирає шум, але не модуляцію OFDM
    n = max(1, int(fs / max(bw_hz, 1.0) / 2))
    if n > 1:
        env = np.convolve(env, np.ones(n) / n, mode="same")
    # Шпаруватість — за потужністю, усередненою на 20 мкс (пакети / стрибки частоти)
    w = max(1, int(fs * 20e-6))
    pw = np.convolve(env ** 2, np.ones(w) / w, mode="same")
    lo_ref, hi_ref = float(np.percentile(pw, 10)), float(np.percentile(pw, 95))
    # Чіткий контраст «є / немає» — пакетний сигнал; інакше вважаємо безперервним
    on = pw > max(0.25 * hi_ref, 4 * lo_ref) if hi_ref > 10 * lo_ref else np.ones(len(pw), bool)
    duty = float(np.mean(on))
    e_on = env[on] if on.any() else env
    cv = float(np.std(e_on) / (np.mean(e_on) + 1e-12))
    p = env ** 2
    papr = float(10 * np.log10(p.max() / (p[on].mean() if on.any() else p.mean() + 1e-12) + 1e-12))
    return IqFeatures(cv, duty, papr)


@dataclass
class Classification:
    code: str
    confidence: float
    subtype: str = ""
    hints: list[str] = field(default_factory=list)

    @property
    def label(self) -> str:
        return CLASSES[self.code][0]

    @property
    def priority(self) -> int:
        return CLASSES[self.code][1]

    @property
    def can_show_video(self) -> bool:
        return CLASSES[self.code][2]

    def to_dict(self) -> dict:
        return {"code": self.code, "label": self.label, "subtype": self.subtype,
                "confidence": round(self.confidence, 2), "priority": self.priority,
                "can_show_video": self.can_show_video, "hints": self.hints}


def classify(freq_hz: float, bw_hz: float, flatness: float, edge_db_per_mhz: float,
             iqf: IqFeatures | None = None, video=None, hopping: bool = False,
             presence: float = 1.0) -> Classification:
    """Об'єднати всі ознаки в один висновок.

    presence — частка проходів, у яких сигнал було видно (0..1)
    hopping — частота «стрибає» між проходами в межах діапазону лінку керування
    """
    ranges = ch.link_ranges_for(freq_hz)
    kinds = {r.kind for r in ranges}
    mhz = bw_hz / 1e6

    # 1. Знайдено рядкову синхронізацію — однозначно аналогове відео
    if video is not None and video.is_video:
        hints = [f"Стандарт {video.standard}", f"Якість синхро {video.sync_score:.0%}"]
        if video.scrambled:
            sub = {"rotate": "зсув рядків (cut & rotate)", "line_invert": "інверсія рядків",
                   "unknown": "невідома схема"}[video.scrambled]
            hints.append(f"Скремблювання: {sub}" + (" — дескрембльовано" if video.descrambled else ""))
            return Classification("analog_video_scrambled", min(0.99, 0.6 + video.sync_score * 0.4), sub, hints)
        if video.inverted:
            hints.append("Полярність інвертована — виправлено автоматично")
            return Classification("analog_video_inverted", min(0.99, 0.6 + video.sync_score * 0.4),
                                   video.standard or "", hints)
        return Classification("analog_video", min(0.99, 0.6 + video.sync_score * 0.4), video.standard or "", hints)

    cv = iqf.envelope_cv if iqf else None
    duty = iqf.duty if iqf else presence

    # 1а. Поза FPV-діапазонами і в смузі відомої служби — фон (FM, ТБ, GSM/LTE, GNSS…)
    svc = ch.service_for(freq_hz)
    if svc is not None and not (kinds & {"video", "control"}):
        cell = any(w in svc.name for w in ("GSM", "LTE", "UMTS", "5G"))
        hint = ("Це базова станція мобільного зв'язку, не дрон" if cell
                else "Це стороння служба (мовлення/навігація/зв'язок), не дрон")
        return Classification("known_service", 0.7, svc.name, [hint])

    # 2. Вузькосмугові стрибкоподібні — лінки керування
    if mhz < 3.0:
        in_ctrl = "control" in kinds
        if in_ctrl and (hopping or duty < 0.85 or presence < 0.7):
            if freq_hz > 2.3e9:
                sub = "ELRS 2.4 / TBS Tracer / FrSky / Ghost"
            elif freq_hz > 800e6:
                sub = "ELRS 868/915 / TBS Crossfire"
            else:
                sub = "LRS 433 МГц"
            conf = 0.85 if hopping else 0.6
            hints = ["Стрибки частоти (FHSS)" if hopping else "Пакетна передача"]
            if cv is not None and cv < 0.3:
                hints.append("Постійна огинаюча — LoRa/FLRC/GFSK")
            if freq_hz > 2.3e9 and not hopping:
                hints.append("2.4 ГГц спільний з Wi-Fi/Bluetooth — переконайтесь, що це не роутер/телефон")
            return Classification("control_link", conf, sub, hints)
        if "telemetry" in kinds or "control" in kinds:
            return Classification("telemetry", 0.5, "", ["Вузька смуга в діапазоні лінків"])
        return Classification("carrier", 0.4, "", [])

    # 3. Широкосмугові
    # OFDM: плоска поличка; огинаюча релеївська (якщо в смузі немає сильнішого стороннього сигналу)
    is_ofdm = flatness > 0.7 or (flatness > 0.5 and (cv is None or cv > 0.3))
    const_env = cv is not None and cv < 0.25
    if const_env and 5 <= mhz <= 30 and "video" in kinds:
        return Classification("analog_video_weak", 0.6, "",
                              ["Постійна огинаюча FM, але синхро не знайдено — підійдіть ближче або увімкніть AMP"])
    if is_ofdm:
        wifi_m = ch.match_channel(freq_hz, bw_hz, kind="wifi", tolerance_hz=3e6)
        if wifi_m and (duty < 0.7 or presence < 0.8):
            return Classification("wifi", 0.6, wifi_m.channel.name,
                                  [f"Схоже на Wi-Fi (канал {wifi_m.channel.name}) — роутер/телефон, зазвичай не загроза",
                                   "Але Wi-Fi використовують і деякі цифрові FPV — дивіться, чи рухається джерело"])
        dji = ch.match_channel(freq_hz, bw_hz, kind="digital", tolerance_hz=5e6)
        if "video" in kinds or dji:
            if 8 <= mhz <= 12:
                sub = "DJI O3/O4 / Walksnail (10 МГц)"
            elif 15 <= mhz <= 24:
                sub = "DJI / Walksnail (20 МГц)"
            elif mhz > 30:
                sub = "DJI O3/O4 (40 МГц)"
            else:
                sub = "OFDM-відеолінк"
            conf = 0.8 if dji else 0.6
            return Classification("digital_video", conf, sub,
                                  ["Цифровий сигнал: зображення недоступне, лише класифікація"])
        return Classification("wifi" if presence < 0.8 else "wideband_unknown", 0.5, "", [])
    if "video" in kinds and 12 <= mhz <= 32 and (cv is None or cv > 0.25):
        return Classification("digital_video", 0.5, "HDZero / цифровий з однією несучою (ймовірно)",
                              ["Цифровий сигнал: зображення недоступне"])
    return Classification("wideband_unknown", 0.4, "", [])
