"""Розшифровка кольору аналогового відео PAL / NTSC (на модулі — потрібна повна частота 20 МГц).

Колір переноситься піднесучою 4.43 МГц (PAL) / 3.58 МГц (NTSC) — її немає в проріджених даних,
які шле телефону режим «Ч/Б (телефон)». Тому кольоровий кадр збирає модуль і шле готовий JPEG.

Для кожного видимого рядка:
  1. сплеск піднесучої після синхроімпульсу (5.6–7.85 мкс) → фаза й амплітуда;
     PAL: середня фаза двох сусідніх рядків — вісь −U, знак V — за відхиленням сплеску ±45°;
  2. активна частина × e^(−jωt) → ФНЧ → (U, V) у системі координат сплеску;
  3. PAL: усереднення з попереднім рядком (лінія затримки) — прибирає фазові спотворення;
  4. яскравість — композит без піднесучої (ФНЧ ~ період піднесучої);
  5. YUV → RGB.
Слабкий сплеск (поганий сигнал) — кольору немає, кадр сірий (як у телевізорах).
"""

from __future__ import annotations

import numpy as np

FSC = {"PAL": 4.43361875e6, "NTSC": 3.579545e6}
ACTIVE_START_S = 10.5e-6
ACTIVE_LEN_S = 52e-6
BURST = (5.8e-6, 7.6e-6)


def _boxcar_rows(a: np.ndarray, k: int) -> np.ndarray:
    """Ковзне середнє по рядках (вздовж осі 1), довжина k."""
    if k <= 1:
        return a
    c = np.cumsum(np.pad(a, ((0, 0), (k // 2 + 1, k - k // 2 - 1)), mode="edge"), axis=1)
    return (c[:, k:] - c[:, :-k]) / k


def decode(u: np.ndarray, lines: np.ndarray, fs: float, standard: str, blank: float, sync_h: float,
           width: int = 320, saturation: float = 1.0) -> tuple[np.ndarray, float]:
    """u — композит (синхро внизу, нормований), lines — початки видимих рядків (відліки, дробові).

    Повертає (RGB uint8 H×W×3, якість кольору 0..1 — відносна амплітуда сплеску)."""
    fsc = FSC[standard]
    w = 2 * np.pi * fsc / fs
    n_act = int(ACTIVE_LEN_S * fs)
    h = len(lines)
    base = lines.astype(np.int64)
    # --- сплеск --------------------------------------------------------------------------------
    b0, b1 = int(BURST[0] * fs), int(BURST[1] * fs)
    kb = np.arange(b0, b1)
    idx = np.clip(base[:, None] + kb[None, :], 0, len(u) - 1)
    bs = u[idx] - u[idx].mean(axis=1, keepdims=True)
    # e^(−jω(base+k)) = e^(−jω·base) · e^(−jωk) — без exp по всьому масиву
    row_ph = np.exp(-1j * w * base.astype(np.float64)).astype(np.complex64)
    zb = (bs.astype(np.float32) @ np.exp(-1j * w * kb).astype(np.complex64)) * row_ph / len(kb)
    amp = np.abs(zb) * 2                                          # амплітуда сплеску (одиниці u)
    # очікувана амплітуда: 0.15 В при синхро 0.3 В
    quality = float(np.clip(np.median(amp) / (sync_h * 0.5 + 1e-9), 0, 1.5))
    # --- активна частина -----------------------------------------------------------------------
    ka = np.arange(int(ACTIVE_START_S * fs), int(ACTIVE_START_S * fs) + n_act)
    ia = np.clip(base[:, None] + ka[None, :], 0, len(u) - 1)
    comp = u[ia].astype(np.float32)
    per = max(1, int(round(fs / fsc)))
    luma = _boxcar_rows(comp, per)                                # без піднесучої
    chroma = comp - luma
    lo_tab = np.exp(-1j * w * ka).astype(np.complex64)[None, :]
    zz = chroma * lo_tab                                          # фаза рядка множиться нижче
    z = _boxcar_rows(zz.real, per * 2) + 1j * _boxcar_rows(zz.imag, per * 2)
    z = z * row_ph[:, None]
    # --- вісь U і знак V -----------------------------------------------------------------------
    ang = np.angle(zb)
    if standard == "PAL":
        # середня фаза сплеску двох сусідніх рядків = вісь −U (сплески ±45° навколо неї)
        prev = np.r_[zb[:1], zb[:-1]]
        mean_ax = np.angle(zb / np.abs(zb + 1e-12) + prev / np.abs(prev + 1e-12))
        sgn = -np.sign(np.angle(np.exp(1j * (ang - mean_ax))))
        sgn[sgn == 0] = 1
        u_axis = mean_ax - np.pi
    else:
        u_axis = ang - np.pi                                      # сплеск NTSC — на осі −U
        sgn = np.ones(h)
    zr = z * np.exp(-1j * u_axis)[:, None]
    scale = 0.15 / np.maximum(amp, 1e-9)[:, None] / 0.7 * 2     # одиниці «1 = білий»
    U = zr.real * scale
    V = zr.imag * scale * sgn[:, None]
    if standard == "PAL":                                         # лінія затримки PAL
        U = (U + np.vstack([U[:1], U[:-1]])) / 2
        V = (V + np.vstack([V[:1], V[:-1]])) / 2
    Y = (luma - blank) / (sync_h * 0.7 / 0.3)
    # --- до потрібної ширини ---------------------------------------------------------------------
    xs = np.linspace(0, n_act - 1, width).astype(int)
    Y, U, V = Y[:, xs], U[:, xs], V[:, xs]
    sat = saturation if quality > 0.25 else 0.0                   # слабкий сплеск — без кольору
    by = U / 0.493 * sat
    ry = V / 0.877 * sat
    gy = -0.509 * ry - 0.194 * by
    rgb = np.stack([Y + ry, Y + gy, Y + by], axis=-1)
    return np.clip(rgb * 255, 0, 255).astype(np.uint8), quality
