"""Демодуляція та декодування аналогового FPV-відео (FM, PAL/NTSC).

Можливості:
  * автоматичне визначення стандарту PAL / NTSC за періодом рядків;
  * автоматичне визначення полярності — інвертоване відео виправляється само;
  * AFC — оцінка зсуву несучої для точного доналаштування;
  * «маховик» рядкової синхронізації: пропущені/зашумлені синхроімпульси добудовуються;
  * авто-рівні (чорний за задньою площадкою, розмах за синхроімпульсом) + авто-контраст;
  * виявлення скремблювання (зсув рядків «cut & rotate», інверсія рядків) і спроба
    дескремблювання; якщо зображення неможливо відновити — лише класифікація.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .filters import fir, fm_demod, lowpass_taps, mix, moving_average

STD = {
    "PAL": {"line_s": 64e-6, "lines": 625, "visible": 288, "vbi": 16},
    "NTSC": {"line_s": 1 / 15734.264, "lines": 525, "visible": 240, "vbi": 13},
}
HSYNC_S = 4.7e-6
ACTIVE_START_S = 10.5e-6
ACTIVE_LEN_S = 52e-6
OUT_WIDTH = 480


@dataclass
class VideoResult:
    is_video: bool = False
    standard: str | None = None
    inverted: bool = False
    scrambled: str | None = None        # None | "rotate" | "line_invert" | "unknown"
    descrambled: bool = False
    sync_score: float = 0.0             # 0..1 — якість рядкової синхронізації
    snr_db: float = 0.0
    line_corr: float = 0.0              # кореляція сусідніх рядків (структура зображення)
    afc_offset_hz: float = 0.0          # на скільки треба доналаштувати несучу
    deviation_hz: float = 0.0
    image: np.ndarray | None = field(default=None, repr=False)
    rgb: np.ndarray | None = field(default=None, repr=False)     # кольоровий кадр (якщо просили колір)
    color_quality: float = 0.0

    def to_dict(self) -> dict:
        return {
            "is_video": self.is_video,
            "standard": self.standard,
            "inverted": self.inverted,
            "scrambled": self.scrambled,
            "descrambled": self.descrambled,
            "sync_score": round(self.sync_score, 3),
            "snr_db": round(self.snr_db, 1),
            "line_corr": round(self.line_corr, 3),
            "afc_offset_hz": round(self.afc_offset_hz),
            "deviation_hz": round(self.deviation_hz),
        }


@dataclass
class _Sync:
    score: float
    starts: np.ndarray       # початки синхроімпульсів, у відліках (дробові)
    broad: np.ndarray        # початки широких (кадрових) імпульсів
    line_samples: float
    gapfill: float


def _find_sync(u: np.ndarray, fs: float) -> _Sync:
    lo, hi = np.percentile(u[::8], [1, 99])   # кожен 8-й відлік — у 8 разів швидше, точність та сама
    rng = max(hi - lo, 1e-9)
    th = lo + 0.15 * rng
    below = u < th
    d = np.diff(below.astype(np.int8))
    st = np.flatnonzero(d == 1) + 1
    en = np.flatnonzero(d == -1) + 1
    if len(st) < 4 or len(en) < 4:
        return _Sync(0.0, np.zeros(0), np.zeros(0), 0.0, 1.0)
    if en[0] < st[0]:
        en = en[1:]
    m = min(len(st), len(en))
    st, en = st[:m], en[:m]
    width = (en - st) / fs
    hs = st[(width > 3.0e-6) & (width < 6.5e-6)]
    broad = st[width > 18e-6]
    # «Порожня смуга» між вершиною синхро і рівнем гасіння — у правильній полярності майже пуста
    us = u[::4]
    gapfill = float(np.mean((us > lo + 0.08 * rng) & (us < lo + 0.22 * rng)))
    if len(hs) < 4:
        return _Sync(0.0, hs.astype(float), broad.astype(float), 0.0, gapfill)
    iv = np.diff(hs) / fs
    good = iv[(iv > 60e-6) & (iv < 68e-6)]
    period_frac = len(good) / max(len(iv), 1)
    line_s = float(np.median(good)) if len(good) else 0.0
    score = period_frac * float(np.clip(1 - (gapfill - 0.01) / 0.05, 0, 1))
    # Уточнення моменту фронту інтерполяцією перетину порогу
    i = hs.astype(int)
    i = i[(i > 0) & (i < len(u))]
    a, b = u[i - 1], u[i]
    frac = np.clip((a - th) / np.where(a - b == 0, 1e-9, a - b), 0, 1)
    starts = (i - 1) + frac
    return _Sync(score, starts, broad.astype(float), line_s * fs, gapfill)


def _flywheel(starts: np.ndarray, period: float, total: int) -> np.ndarray:
    """Рівномірна сітка рядків, підтягнута до знайдених синхроімпульсів (як ФАПЧ)."""
    if len(starts) == 0 or period <= 0:
        return np.zeros(0)
    tol = period * 0.03
    lines = [float(starts[0])]
    t = float(starts[0])
    j = 0
    while t + period * 1.01 < total:
        pred = t + period
        while j < len(starts) and starts[j] < pred - tol:
            j += 1
        if j < len(starts) and abs(starts[j] - pred) <= tol:
            t = 0.7 * float(starts[j]) + 0.3 * pred
        else:
            t = pred
        lines.append(t)
    return np.asarray(lines)


def _row_corr(a: np.ndarray, b: np.ndarray) -> float:
    a = a - a.mean()
    b = b - b.mean()
    den = float(np.sqrt((a * a).sum() * (b * b).sum()))
    return 1.0 if den < 1e-9 else float((a * b).sum() / den)


def _best_shift(prev: np.ndarray, row: np.ndarray) -> tuple[int, float]:
    a = prev - prev.mean()
    b = row - row.mean()
    c = np.fft.irfft(np.fft.rfft(a) * np.conj(np.fft.rfft(b)), len(a))
    k = int(np.argmax(c))
    den = float(np.sqrt((a * a).sum() * (b * b).sum()))
    return k, (1.0 if den < 1e-9 else float(c[k] / den))


def _analyze_scramble(img: np.ndarray, try_descramble: bool) -> tuple[str | None, float, np.ndarray, bool]:
    rows = img.astype(np.float32)
    step = max(1, len(rows) // 64)
    idx = range(0, len(rows) - 1, step)
    corr = np.median([_row_corr(rows[i], rows[i + 1]) for i in idx])
    if corr > 0.45:
        return None, float(corr), img, False
    inv = np.median([abs(_row_corr(rows[i], rows[i + 1])) for i in idx])
    shift_c = np.median([_best_shift(rows[i], rows[i + 1])[1] for i in idx])
    if shift_c > 0.7 and shift_c > inv:
        kind = "rotate"
        if try_descramble:
            out = rows.copy()
            for i in range(1, len(out)):
                k, _ = _best_shift(out[i - 1], rows[i])
                out[i] = np.roll(rows[i], k)
            return kind, float(corr), out.clip(0, 255).astype(np.uint8), True
        return kind, float(corr), img, False
    if inv > 0.7:
        kind = "line_invert"
        if try_descramble:
            out = rows.copy()
            for i in range(1, len(out)):
                if _row_corr(out[i - 1], rows[i]) < 0:
                    out[i] = 255 - rows[i]
            return kind, float(corr), out.astype(np.uint8), True
        return kind, float(corr), img, False
    return "unknown", float(corr), img, False


def raw_raster(iq: np.ndarray, fs: float, offset_hz: float = 0.0, width: int = OUT_WIDTH,
               height: int = 288, video_bw_hz: float = 6e6) -> np.ndarray:
    """Растр прямо з ЧМ-демодуляції, БЕЗ синхронізації: завжди щось показує.

    Коли сигналу немає — це справжній «сніг» (смугообмежений шум приймача), а не чорний екран.
    Коли є відео, але синхронізація ще не зловлена — видно «рухому» картинку. Нічого не вигадується:
    яскравість береться з реального сигналу.
    """
    n_need = width * height + 64
    x = iq[: n_need] if len(iq) >= n_need else iq          # фільтруємо лише те, що піде в кадр
    x = mix(x, offset_hz, fs) if offset_hz else x
    x = fir(x, lowpass_taps(min(0.45, max(video_bw_hz, 1e6) / fs), 21))
    hz = fm_demod(x, fs).astype(np.float32)
    # Згладити до «відеосмуги», щоб шум виглядав як аналоговий сніг, а не піксельна каша
    k = max(1, int(round(fs / (2 * width / 64e-6))))
    if k > 1:
        hz = moving_average(hz, k)
    n = width * height
    y = hz[:n] if len(hz) >= n else np.resize(hz, n)
    lo, hi = np.percentile(y, [2, 98])
    img = np.clip((y - lo) / (hi - lo + 1e-9) * 255.0, 0, 255).astype(np.uint8)
    return img.reshape(height, width)


def demodulate(iq: np.ndarray, fs: float, offset_hz: float = 0.0, *, force_invert: bool | None = None,
               auto_contrast: bool = True, descramble: bool = True, color: bool = False,
               saturation: float = 1.0) -> VideoResult:
    """Повний ланцюг: IQ → композит → кадр (uint8 H×W)."""
    res = VideoResult()
    if len(iq) < fs * 1e-3:
        return res
    # ФНЧ тут не потрібен: при 20 МГц дискретизації його зріз ≈ Найквіст, а він займав 60 % часу кадру.
    # Фільтруємо лише якщо сигнал зсунутий від центру (тоді прибираємо сусідів).
    x = mix(iq, offset_hz, fs) if offset_hz else iq
    if offset_hz:
        x = fir(x, lowpass_taps(min(0.45, 9e6 / fs), 31))
    from .. import native
    hz = native.fm_baseband(x, fs, 1)               # C — швидше на ARM; без нього — numpy
    if hz is None:
        hz = fm_demod(x, fs)
    p_lo, p_hi = np.percentile(hz[::8], [0.5, 99.5])
    res.afc_offset_hz = float((p_lo + p_hi) / 2)
    res.deviation_hz = float(p_hi - p_lo)
    v = moving_average(hz, max(1, int(round(fs / 6e6))))
    span = max(p_hi - p_lo, 1.0)
    med = np.median(v)
    v = (v - med) / span
    raw_c = (hz - med) / span if color else None     # без згладжування — піднесуча кольору ціла

    cands = []
    for pol in ((-1, 1) if force_invert is None else ((-1,) if force_invert else (1,))):
        cands.append((pol, _find_sync(v * pol, fs)))
    pol, sync = max(cands, key=lambda c: c[1].score)
    res.sync_score = sync.score
    res.inverted = pol < 0
    if sync.score < 0.35 or sync.line_samples <= 0:
        return res
    line_s = sync.line_samples / fs
    res.standard = "PAL" if abs(line_s - 64e-6) < abs(line_s - STD["NTSC"]["line_s"]) else "NTSC"
    st = STD[res.standard]
    u = v * pol
    period = sync.line_samples
    lines = _flywheel(sync.starts, period, len(u))
    # Початок поля — після останнього широкого (кадрового) імпульсу групи
    first = 0
    if len(sync.broad):
        groups_end = [b for k, b in enumerate(sync.broad)
                      if k + 1 == len(sync.broad) or sync.broad[k + 1] - b > period * 2]
        for g in groups_end:
            cand = int(np.searchsorted(lines, g + period * 0.25))
            if cand + st["vbi"] + st["visible"] <= len(lines):
                first = cand
                break
    n_lines = min(st["visible"], len(lines) - first - st["vbi"] - 1)
    if n_lines < 32:
        return res
    sel = lines[first + st["vbi"]: first + st["vbi"] + n_lines]
    xs = np.linspace(ACTIVE_START_S, ACTIVE_START_S + ACTIVE_LEN_S, OUT_WIDTH) * fs
    grid = sel[:, None] + xs[None, :]
    grid = np.clip(grid, 0, len(u) - 2)
    i0 = grid.astype(int)
    fr = grid - i0
    raw = u[i0] * (1 - fr) + u[i0 + 1] * fr

    # Рівні: вершина синхро і задня площадка по всіх рядках
    tip_idx = (lines[:, None] + np.linspace(0.6e-6, 4.0e-6, 8)[None, :] * fs).astype(int)
    bp_idx = (lines[:, None] + np.linspace(5.8e-6, 9.6e-6, 12)[None, :] * fs).astype(int)
    ok = (bp_idx[:, -1] < len(u))
    tip = float(np.median(u[tip_idx[ok]]))
    bp = u[bp_idx[ok]]
    blank = float(np.median(bp))
    sync_h = max(blank - tip, 1e-6)
    noise = float(np.median(np.std(bp, axis=1))) + 1e-9
    res.snr_db = float(20 * np.log10(sync_h / noise))
    img = (raw - blank) / (sync_h * 0.7 / 0.3) * 255.0
    if auto_contrast:
        lo, hi = np.percentile(img, [1, 99])
        if hi - lo < 120 and hi - lo > 8:  # слабкий контраст — розтягнути
            img = (img - lo) / (hi - lo) * 230 + 12
    img = np.clip(img, 0, 255).astype(np.uint8)

    kind, corr, img2, desc = _analyze_scramble(img, descramble)
    res.scrambled, res.line_corr, res.descrambled = kind, corr, desc
    res.image = img2
    res.is_video = True
    if color and raw_c is not None and fs >= 4 * 4.5e6:
        from . import color as col
        res.rgb, res.color_quality = col.decode(raw_c * pol, sel, fs, res.standard, blank, sync_h,
                                                width=320, saturation=saturation)
    return res
