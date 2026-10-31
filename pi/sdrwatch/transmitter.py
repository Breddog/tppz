"""Тестовий генератор сигналу (TX): перевірка приймання інших пристроїв на заданій частоті.

Можна увімкнути:
  * carrier — чиста несуча (перевірити, чи «бачить» приймач частоту);
  * tone    — несуча з тоном (FM, звуковий тон для свисту в приймачі);
  * bars    — тестова таблиця аналогового FPV-відео PAL/NTSC (вертикальні смуги + рамка);
  * image   — завантажена з телефону картинка як аналогове FPV-відео;
  * noise   — вузькосмуговий шум (перевірити роботу шумодава / порогів).

Генерує комплексні відліки на нульовій частоті (несуча ставиться перебудовою SDR).
Передавач вмикається ЛИШЕ вручну, на обмежений час (авто-стоп), і нічого не передає сам.
ВАЖЛИВО: передавайте тільки на навантаження/екрановано або на дозволених вам частотах.
"""

from __future__ import annotations

import math

import numpy as np

from .sources.simulated import STANDARDS

HSYNC_S = 4.7e-6
ACTIVE_START_S = 10.5e-6
ACTIVE_LEN_S = 52e-6
# Девіація FM для FPV-відео (Гц на повний розмах відео); типово ~8 МГц → ~16-18 МГц зайнятої смуги
VIDEO_DEVIATION_HZ = 8e6

MODES = {
    "carrier": "Несуча",
    "tone": "Несуча + тон",
    "bars": "Тестова таблиця (відео)",
    "image": "Картинка (відео)",
    "noise": "Шум",
}


def test_pattern(height: int = 240, width: int = 320) -> np.ndarray:
    """Сіра тестова таблиця: вертикальні градієнтні смуги, рамка, хрест, мітка яскравості."""
    img = np.zeros((height, width), np.float32)
    bars = np.floor(np.linspace(0, 7.999, width)) / 7.0
    img[:] = bars[None, :]
    img[: height // 6] = np.linspace(0, 1, width)[None, :]        # плавний градієнт зверху
    img[-height // 6:] = (np.arange(width)[None, :] // 2 % 2)     # дрібна «гребінка» знизу
    img[:, :2] = img[:, -2:] = img[:2] = img[-2:] = 1.0          # рамка
    img[height // 2 - 1: height // 2 + 1] = 1.0                   # горизонт. лінія
    img[:, width // 2 - 1: width // 2 + 1] = 1.0                  # вертик. лінія
    return img


def _composite_from_image(image: np.ndarray, fs: float, standard: str) -> np.ndarray:
    """Один кадр композитного відео (у вольтах: синхро −0.3, чорний 0, білий 0.7) з картинки H×W (0..1)."""
    st = STANDARDS[standard]
    line_s = st["line_s"]
    total_lines = st["lines"]
    visible = int(total_lines * 0.92) // 2 * 2          # активних рядків (прибл.)
    vbi = (total_lines - visible) // 2
    spl = int(round(line_s * fs))
    n = spl * total_lines
    t = np.arange(n) / fs
    line_no = np.clip((t / line_s).astype(int), 0, total_lines - 1)
    pos = t - line_no * line_s
    x = (pos - ACTIVE_START_S) / ACTIVE_LEN_S           # 0..1 активної частини рядка

    h, w = image.shape
    active = (x >= 0) & (x < 1) & (line_no >= vbi) & (line_no < vbi + visible)
    row = np.clip(((line_no - vbi) / max(1, visible) * h).astype(int), 0, h - 1)
    col = np.clip((np.clip(x, 0, 0.999) * w).astype(int), 0, w - 1)
    pix = image[row, col]                               # 0..1
    v = np.where(active, 0.05 + 0.65 * pix, 0.0).astype(np.float32)   # активне відео
    v = np.where(pos < HSYNC_S, -0.3, v)                              # рядкові синхроімпульси
    # Кадрові синхроімпульси (широкі) — щоб приймач зловив кадр
    vsync = (line_no < 3) & (np.mod(pos, line_s / 2) < line_s / 2 - HSYNC_S)
    v = np.where(vsync, -0.3, v)
    return v


def _fm_modulate(v: np.ndarray, fs: float, deviation_hz: float, amp: float) -> np.ndarray:
    phase = 2 * np.pi * np.cumsum(v.astype(np.float64)) * deviation_hz / fs
    return (amp * np.exp(1j * phase)).astype(np.complex64)


def build_waveform(mode: str, fs: float, *, image: np.ndarray | None = None, standard: str = "PAL",
                   tone_hz: float = 1000.0, bandwidth_hz: float = 2e6, amplitude: float = 0.9,
                   seed: int = 0) -> np.ndarray:
    """Повертає комплексний буфер (на 0 Гц), який циклічно повторюється під час передачі."""
    amp = float(np.clip(amplitude, 0.0, 1.0))
    if mode == "carrier":
        return (amp * np.ones(int(fs * 1e-3), np.complex64)).astype(np.complex64)
    if mode == "tone":
        n = int(fs * 20e-3)
        t = np.arange(n) / fs
        # FM-несуча з синусоїдним тоном, девіація ~50 кГц
        phase = 2 * np.pi * 50e3 / tone_hz * np.sin(2 * np.pi * tone_hz * t)
        return (amp * np.exp(1j * phase)).astype(np.complex64)
    if mode == "noise":
        n = int(fs * 20e-3)
        rng = np.random.default_rng(seed)
        x = (rng.standard_normal(n) + 1j * rng.standard_normal(n)).astype(np.complex64)
        # Обмежити смугу шуму простим ковзним середнім
        k = max(1, int(fs / max(bandwidth_hz, 50e3)))
        if k > 1:
            x = np.convolve(x, np.ones(k) / k, mode="same").astype(np.complex64)
        return (amp / (np.max(np.abs(x)) + 1e-9) * x).astype(np.complex64)
    if mode in ("bars", "image"):
        img = test_pattern() if mode == "bars" or image is None else image
        v = _composite_from_image(img, fs, standard if standard in STANDARDS else "PAL")
        return _fm_modulate(v, fs, VIDEO_DEVIATION_HZ, amp)
    raise ValueError(f"Невідомий режим TX: {mode}")


def load_image(data: bytes, max_w: int = 360, max_h: int = 288) -> np.ndarray:
    """Байти зображення → сіра матриця H×W (0..1). Потрібен Pillow."""
    import io

    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert("L")
    im.thumbnail((max_w, max_h))
    return (np.asarray(im, np.float32) / 255.0)
