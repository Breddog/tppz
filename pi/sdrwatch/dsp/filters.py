"""Прості фільтри на numpy (без scipy — легше ставити на Raspberry Pi)."""

from __future__ import annotations

import numpy as np

_CACHE: dict[tuple[int, float], np.ndarray] = {}


def lowpass_taps(cutoff_norm: float, ntaps: int = 31) -> np.ndarray:
    """КІХ ФНЧ (віконний sinc). cutoff_norm — частка від fs (0..0.5)."""
    key = (ntaps, round(cutoff_norm, 4))
    t = _CACHE.get(key)
    if t is None:
        n = np.arange(ntaps) - (ntaps - 1) / 2
        t = 2 * cutoff_norm * np.sinc(2 * cutoff_norm * n) * np.hamming(ntaps)
        t = (t / t.sum()).astype(np.float32)
        _CACHE[key] = t
    return t


def fir(x: np.ndarray, taps: np.ndarray) -> np.ndarray:
    """Фільтрація зі збереженням довжини та без зсуву фази (центрований КІХ)."""
    if len(x) < len(taps) * 4:
        return np.convolve(x, taps, mode="same")
    # Швидка згортка через FFT
    n = len(x) + len(taps) - 1
    nfft = 1 << (n - 1).bit_length()
    y = np.fft.ifft(np.fft.fft(x, nfft) * np.fft.fft(taps, nfft))[:n] if np.iscomplexobj(x) else \
        np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(taps, nfft), nfft)[:n]
    d = (len(taps) - 1) // 2
    return y[d:d + len(x)].astype(x.dtype)


def mix(iq: np.ndarray, offset_hz: float, fs: float) -> np.ndarray:
    """Зсунути сигнал на -offset_hz (перенести його на нульову частоту)."""
    if offset_hz == 0:
        return iq
    ph = np.exp(-2j * np.pi * offset_hz / fs * np.arange(len(iq)))
    return (iq * ph).astype(np.complex64)


def fm_demod(iq: np.ndarray, fs: float) -> np.ndarray:
    """Частотний дискримінатор, результат у Гц."""
    d = iq[1:] * np.conj(iq[:-1])
    return (np.angle(d) * fs / (2 * np.pi)).astype(np.float32)


def moving_average(x: np.ndarray, n: int) -> np.ndarray:
    if n <= 1:
        return x
    c = np.cumsum(np.r_[0.0, x.astype(np.float64)])
    y = (c[n:] - c[:-n]) / n
    pad_l = (n - 1) // 2
    return np.pad(y, (pad_l, len(x) - len(y) - pad_l), mode="edge").astype(np.float32)
