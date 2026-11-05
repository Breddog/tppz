"""Спектр, оцінка рівня шуму та виявлення сигналів без «порожніх» спрацювань на шумі.

Схема:
  1. PSD методом Велча (вікно Блекмана-Гарріса, усереднення K кадрів) — дисперсія шуму
     падає в √K разів, тому поріг 8 дБ ≈ 4σ.
  2. Прибирання DC-піку HackRF і країв смуги (спад фільтра).
  3. Рівень шуму для кожного біна: ковзний перцентиль по частоті + довготривалий трекер
     «швидко вниз / повільно вгору» + обмеження глобальним опорним рівнем — широкі
     безперервні сигнали (OFDM 20–40 МГц) не «з'їдають» поріг.
  4. Маска перевищення → морфологічне закриття/відкриття → області → ознаки сигналу.
  5. Підтвердження у трекері: сигнал має бути видно кілька проходів поспіль.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

_WINDOWS: dict[int, np.ndarray] = {}
# Еквівалентна шумова смуга вікна Блекмана-Гарріса, у бінах: сума бінів / ENBW = повна потужність
ENBW_BINS = 2.004


def _window(n: int) -> np.ndarray:
    w = _WINDOWS.get(n)
    if w is None:
        k = np.arange(n)
        a = (0.35875, 0.48829, 0.14128, 0.01168)  # Блекман-Гарріс 4-term
        w = (a[0] - a[1] * np.cos(2 * np.pi * k / (n - 1)) + a[2] * np.cos(4 * np.pi * k / (n - 1))
             - a[3] * np.cos(6 * np.pi * k / (n - 1))).astype(np.float32)
        _WINDOWS[n] = w
    return w


def psd_db(iq: np.ndarray, fft_size: int = 1024, averages: int = 8) -> np.ndarray:
    """Спектральна густина в dBFS (повна шкала синусоїди = 0 дБ), центр — посередині."""
    nseg = max(1, min(averages * 2 - 1, (len(iq) - fft_size) // (fft_size // 2) + 1))
    w = _window(fft_size)
    step = fft_size // 2  # 50 % перекриття
    segs = np.lib.stride_tricks.sliding_window_view(iq[: step * (nseg - 1) + fft_size], fft_size)[::step][:nseg]
    spec = np.fft.fft(segs * w, axis=1)
    p = np.mean(np.abs(spec) ** 2, axis=0) / (np.sum(w) ** 2)
    p = np.fft.fftshift(p)
    return (10 * np.log10(p + 1e-20)).astype(np.float32)


def remove_dc(spec_db: np.ndarray, width: int = 2) -> np.ndarray:
    """Замінити DC-пік (шум LO у прямого перетворення) інтерполяцією сусідів."""
    s = spec_db.copy()
    c = len(s) // 2
    lo, hi = c - width, c + width + 1
    s[lo:hi] = np.linspace(s[lo - 1], s[hi], hi - lo + 2)[1:-1]
    return s


def rolling_percentile(x: np.ndarray, win: int, q: float) -> np.ndarray:
    win = max(3, win | 1)
    pad = win // 2
    xp = np.pad(x, pad, mode="reflect")
    # Децимація для швидкодії на Raspberry Pi: перцентиль рахуємо з кроком, потім інтерполюємо
    step = max(1, win // 8)
    view = np.lib.stride_tricks.sliding_window_view(xp, win)[::step]
    vals = np.percentile(view, q, axis=1)
    xs = np.arange(0, len(x), step)[: len(vals)]
    return np.interp(np.arange(len(x)), xs, vals).astype(np.float32)


def smooth(x: np.ndarray, n: int = 3) -> np.ndarray:
    if n <= 1:
        return x
    k = np.ones(n, dtype=np.float32) / n
    return np.convolve(np.pad(x, n // 2, mode="edge"), k, mode="valid")[: len(x)].astype(np.float32)


def local_floor(spec_db: np.ndarray, win_frac: float = 0.25) -> np.ndarray:
    """Миттєва оцінка рівня шуму по частоті (ковзний 25-й перцентиль + корекція до медіани шуму)."""
    win = max(15, int(len(spec_db) * win_frac))
    raw = rolling_percentile(spec_db, win, 25)
    resid = spec_db - raw
    noise_like = resid[resid < 6]
    corr = float(np.median(noise_like)) if noise_like.size else 0.0
    return smooth(raw + corr, 9)


class NoiseFloorTracker:
    """Довготривала оцінка шуму для панорами (кожен бін окремо).

    Вниз — швидко (сигнал зник → шум одразу видно), вгору — дуже повільно
    (безперервні сигнали не «вбудовуються» в шум). Додатково обмежено опорним
    рівнем околу (±region_bins) + margin: широкий сигнал на весь сегмент не піднімає
    поріг, а на повному діапазоні 0–6 ГГц враховується, що власний шум SDR різний
    на різних частотах.
    """

    def __init__(self, n_bins: int, down: float = 0.5, up: float = 0.01, margin_db: float = 6.0,
                 region_bins: int = 8000) -> None:
        self.floor = np.full(n_bins, np.nan, dtype=np.float32)
        self.ref = np.full(n_bins, np.nan, dtype=np.float32)
        self.down, self.up, self.margin = down, up, margin_db
        self.region = region_bins

    @property
    def global_ref(self) -> float | None:
        v = self.ref[~np.isnan(self.ref)]
        return float(np.median(v)) if v.size else None

    def update(self, sl: slice, spec_db: np.ndarray) -> np.ndarray:
        inst = local_floor(spec_db)
        cur = self.floor[sl]
        cur = np.where(np.isnan(cur), inst, cur)
        alpha = np.where(inst < cur, self.down, self.up)
        cur = cur + alpha * (inst - cur)
        self.floor[sl] = cur
        near = self.floor[max(0, sl.start - self.region): sl.stop + self.region]
        near = near[~np.isnan(near)]
        ref = float(np.percentile(near, 20))
        old = self.ref[sl]
        self.ref[sl] = np.where(np.isnan(old), ref, 0.9 * old + 0.1 * ref)
        return np.minimum(cur, self.ref[sl] + self.margin)

    def get(self, sl: slice) -> np.ndarray:
        return np.fmin(self.floor[sl], self.ref[sl] + self.margin)


@dataclass
class Detection:
    freq_hz: float          # центр (зважений за потужністю)
    bandwidth_hz: float     # зайнята смуга
    peak_dbfs: float
    mean_dbfs: float
    snr_db: float
    floor_dbfs: float
    flatness: float         # 0..1, 1 — «плоска поличка» (OFDM), мало — горб / лінія
    edge_db_per_mhz: float  # крутизна схилів
    power_dbfs: float = -200.0  # повна потужність у смузі (для RSSI і відстані)
    occupied_hz: float = 0.0    # смуга 99 % потужності
    shape: np.ndarray = field(repr=False, default_factory=lambda: np.zeros(0, np.float32))
    bin_hz: float = 0.0
    touches_edge: bool = False

    def to_dict(self) -> dict:
        return {
            "freq_hz": round(self.freq_hz),
            "bandwidth_hz": round(self.bandwidth_hz),
            "peak_dbfs": round(self.peak_dbfs, 1),
            "snr_db": round(self.snr_db, 1),
            "flatness": round(self.flatness, 3),
        }


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    d = np.diff(np.r_[0, mask.astype(np.int8), 0])
    starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    return list(zip(starts, ends))


def detect(spec_db: np.ndarray, floor_db: np.ndarray, freqs_hz: np.ndarray,
           threshold_db: float = 8.0, min_bw_hz: float = 60e3, gap_hz: float = 300e3) -> list[Detection]:
    """Знайти сигнали у спектрі (масиви однакової довжини)."""
    if len(spec_db) < 8:
        return []
    bin_hz = float(freqs_hz[1] - freqs_hz[0])
    s = smooth(spec_db, 3)
    excess = s - floor_db
    mask = excess > threshold_db
    # Закриття: склеїти розриви (OFDM з пілотами, FM-горб з провалами)
    gap = max(1, int(gap_hz / bin_hz))
    for a, b in _runs(~mask):
        if 0 < a and b < len(mask) and (b - a) <= gap:
            mask[a:b] = True
    out: list[Detection] = []
    min_bins = max(2, int(min_bw_hz / bin_hz))
    lin = 10 ** (spec_db / 10)
    for a, b in _runs(mask):
        if b - a < min_bins:
            continue
        # Розширити до рівня floor + 3 дБ для оцінки зайнятої смуги
        lo, hi = a, b
        while lo > 0 and excess[lo - 1] > 3:
            lo -= 1
        while hi < len(s) and excess[hi] > 3:
            hi += 1
        seg = lin[lo:hi]
        w = seg / seg.sum()
        fc = float(np.sum(freqs_hz[lo:hi] * w))
        # Зайнята смуга 99 % потужності
        cs = np.cumsum(seg) / seg.sum()
        i0, i1 = int(np.searchsorted(cs, 0.005)), int(np.searchsorted(cs, 0.995))
        occ = max(bin_hz, (i1 - i0 + 1) * bin_hz)
        bw = (hi - lo) * bin_hz   # ширина на рівні шум + 3 дБ — те, що бачить користувач
        core = spec_db[a:b]
        core_lin = 10 ** (core / 10)
        flat = float(np.exp(np.mean(np.log(core_lin))) / np.mean(core_lin))
        peak = float(np.max(core))
        fl = float(np.median(floor_db[lo:hi]))
        # Крутизна: падіння від «полички» до шуму на краях
        edge_n = max(2, (b - a) // 10)
        top = float(np.median(core))
        left = top - float(np.mean(s[max(0, a - edge_n):a])) if a > 0 else 0.0
        right = top - float(np.mean(s[b:b + edge_n])) if b < len(s) else 0.0
        edge = max(left, right) / max(edge_n * bin_hz / 1e6, 1e-3)
        out.append(Detection(
            freq_hz=fc, bandwidth_hz=bw, peak_dbfs=peak,
            mean_dbfs=float(10 * np.log10(np.mean(core_lin))),
            snr_db=peak - fl, floor_dbfs=fl, flatness=flat, edge_db_per_mhz=edge,
            power_dbfs=float(10 * np.log10(seg.sum() / ENBW_BINS + 1e-20)), occupied_hz=occ,
            shape=(spec_db[lo:hi] - fl).astype(np.float32), bin_hz=bin_hz,
            touches_edge=(lo <= 1 or hi >= len(s) - 1),
        ))
    return out


def merge_edge_detections(dets: list[Detection], max_gap_hz: float = 1e6) -> list[Detection]:
    """Склеїти сигнали, розрізані межею між сусідніми сегментами сканування."""
    dets = sorted(dets, key=lambda d: d.freq_hz)
    out: list[Detection] = []
    for d in dets:
        if out:
            p = out[-1]
            gap = (d.freq_hz - d.bandwidth_hz / 2) - (p.freq_hz + p.bandwidth_hz / 2)
            if gap < max_gap_hz and (p.touches_edge or d.touches_edge):
                lo = min(p.freq_hz - p.bandwidth_hz / 2, d.freq_hz - d.bandwidth_hz / 2)
                hi = max(p.freq_hz + p.bandwidth_hz / 2, d.freq_hz + d.bandwidth_hz / 2)
                wp, wd = 10 ** (p.mean_dbfs / 10) * p.bandwidth_hz, 10 ** (d.mean_dbfs / 10) * d.bandwidth_hz
                p.freq_hz = (p.freq_hz * wp + d.freq_hz * wd) / (wp + wd)
                p.bandwidth_hz = hi - lo
                p.peak_dbfs = max(p.peak_dbfs, d.peak_dbfs)
                p.power_dbfs = float(10 * np.log10(10 ** (p.power_dbfs / 10) + 10 ** (d.power_dbfs / 10)))
                p.occupied_hz += d.occupied_hz
                p.snr_db = max(p.snr_db, d.snr_db)
                p.flatness = (p.flatness * wp + d.flatness * wd) / (wp + wd)
                p.shape = np.concatenate([p.shape, d.shape])
                p.touches_edge = d.touches_edge
                continue
        out.append(d)
    return out


def absorb_satellites(dets: list[Detection], max_gap_hz: float = 3e6, narrow_hz: float = 2e6) -> list[Detection]:
    """Приєднати вузькі «супутники» до сусіднього широкого сигналу.

    У FM-відео рівень синхроімпульсу дає окрему спектральну лінію за 1–3 МГц від основного
    «горба»; це частина того самого сигналу, а не окреме джерело.
    """
    wide = [d for d in dets if d.bandwidth_hz >= 1.5 * narrow_hz]
    out = []
    for d in dets:
        if d.bandwidth_hz < narrow_hz:
            host = None
            for w in wide:
                gap = abs(d.freq_hz - w.freq_hz) - w.bandwidth_hz / 2
                if gap < max_gap_hz:
                    host = w
                    break
            if host is not None:
                lo = min(host.freq_hz - host.bandwidth_hz / 2, d.freq_hz - d.bandwidth_hz / 2)
                hi = max(host.freq_hz + host.bandwidth_hz / 2, d.freq_hz + d.bandwidth_hz / 2)
                host.bandwidth_hz = hi - lo
                host.power_dbfs = float(10 * np.log10(10 ** (host.power_dbfs / 10) + 10 ** (d.power_dbfs / 10)))
                continue
        out.append(d)
    return out


def downsample_max(x: np.ndarray, n: int) -> np.ndarray:
    """Стиснути спектр до n точок, зберігаючи піки (для передачі на телефон)."""
    if len(x) <= n:
        return x
    edges = np.linspace(0, len(x), n + 1).astype(int)
    return np.maximum.reduceat(x, edges[:-1])
