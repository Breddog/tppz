"""Симулятор ефіру: для розробки, демонстрації та тестів без справжнього SDR.

Генерує реалістичні сигнали:
  * аналогове FM-відео PAL/NTSC (звичайне, інвертоване, скрембльоване);
  * цифрове OFDM-відео (як DJI / Walksnail);
  * стрибкоподібні вузькосмугові лінки керування (як ELRS / Crossfire);
  * Wi-Fi-подібні пакети;
  * тепловий шум приймача.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

import numpy as np

from .base import SdrSource

STANDARDS = {
    "PAL": {"line_s": 64e-6, "lines": 625},
    "NTSC": {"line_s": 1 / 15734.264, "lines": 525},
}


def composite(t: np.ndarray, standard: str = "PAL", scramble_seed: int | None = None,
              pattern_phase: float = 0.0) -> np.ndarray:
    """Композитний відеосигнал (у вольтах: синхро −0.3, чорний 0, білий 0.7)."""
    st = STANDARDS[standard]
    line_s = st["line_s"]
    lines_per_field = st["lines"] / 2
    line_no = np.floor(t / line_s)
    pos = t - line_no * line_s
    field_line = np.mod(line_no, lines_per_field)
    frame = np.floor(line_no / st["lines"])

    hsync = pos < 4.7e-6
    active_start, active_len = 10.5e-6, 52e-6
    x = (pos - active_start) / active_len          # 0..1 у межах активної частини рядка
    if scramble_seed is not None:
        # Скремблювання «cut and rotate»: кожен рядок циклічно зсувається на випадкову величину
        shift = np.mod(np.sin(line_no * 12.9898 + scramble_seed) * 43758.5453, 1.0)
        x = np.mod(x + shift, 1.0)
    y = field_line / lines_per_field

    # Тестове зображення: градієнтні смуги + рухомий квадрат
    bars = np.floor(np.clip(x, 0, 0.999) * 8) / 7.0
    img = 0.1 + 0.55 * bars * (0.55 + 0.45 * y)   # вертикальний градієнт — «живий» спектр як у камери
    bx = 0.5 + 0.3 * np.sin(frame * 0.2 + pattern_phase)
    box = (np.abs(x - bx) < 0.08) & (np.abs(y - 0.5) < 0.12)
    img = np.where(box, 0.7, img)
    img = np.where(np.abs(y - 0.25) < 0.01, 0.0, img)

    v = np.where((x >= 0) & (x < 1), img, 0.0)
    v = np.where(hsync, -0.3, v)
    # Кадрові синхроімпульси: перші 3 рядки поля — широкі імпульси
    vsync = (field_line < 3) & (np.mod(pos, line_s / 2) < line_s / 2 - 4.7e-6)
    v = np.where(vsync, -0.3, v)
    return v.astype(np.float32)


def _shift(x: np.ndarray, off_hz: float, fs: float, keep: float = 0.45) -> np.ndarray:
    """Перенести сигнал на off_hz у частотній області, обрізавши все поза ±keep·fs."""
    n = len(x)
    k = int(round(off_hz / fs * n))
    if k == 0:
        return x
    if abs(k) >= n:
        return np.zeros(n, np.complex128)
    X = np.fft.fft(x)
    Y = np.zeros_like(X)
    src = np.rint(np.fft.fftfreq(n) * n).astype(np.int64)   # номер біна (зі знаком)
    dst = src + k
    ok = np.abs(dst) < keep * n
    Y[dst[ok] % n] = X[ok]
    return np.fft.ifft(Y)


@dataclass
class Emitter:
    freq_hz: float
    kind: str                 # analog | analog_inverted | analog_scrambled | ofdm | fhss | wifi | cw
    power_dbm: float = -65.0      # рівень на вході приймача
    bandwidth_hz: float = 10e6
    standard: str = "PAL"
    hop_lo_hz: float = 0.0
    hop_hi_hz: float = 0.0
    hop_period_s: float = 4e-3
    duty: float = 1.0
    seed: int = 1
    _rng: np.random.Generator = field(default=None, repr=False)  # type: ignore[assignment]

    def __post_init__(self) -> None:
        self._rng = np.random.default_rng(self.seed)

    # Чи потрапляє випромінювач у смугу приймача
    def span(self) -> tuple[float, float]:
        if self.kind == "fhss":
            return self.hop_lo_hz - self.bandwidth_hz, self.hop_hi_hz + self.bandwidth_hz
        return self.freq_hz - self.bandwidth_hz, self.freq_hz + self.bandwidth_hz

    def generate(self, t: np.ndarray, fs: float, center_hz: float) -> np.ndarray | None:
        """Сигнал у смузі приймача. Частини поза ±0.45·fs відкидаються (як аналоговий фільтр SDR)."""
        lo, hi = self.span()
        half = fs / 2
        if hi < center_hz - half or lo > center_hz + half:
            return None
        amp = 10 ** (self.power_dbm / 20)
        n = len(t)
        if self.kind.startswith("analog"):
            v = composite(t, self.standard,
                          scramble_seed=self.seed if self.kind == "analog_scrambled" else None)
            if self.kind == "analog_inverted":
                v = -v
            dev = 8e6  # девіація FM, Гц на 1 В (≈18 МГц зайнятої смуги, як у VTX)
            phase = 2 * np.pi * np.cumsum(v, dtype=np.float64) * dev / fs
            base, off = np.exp(1j * phase), self.freq_hz - center_hz
        elif self.kind in ("ofdm", "wifi"):
            base, off = self._ofdm(n, fs, self.bandwidth_hz), self.freq_hz - center_hz
            if self.kind == "wifi":
                base = base * (np.mod(t, 2e-3) < 2e-3 * self.duty)
        elif self.kind == "fhss":
            slot = np.floor(t / self.hop_period_s).astype(np.int64)
            rng_f = ((slot * 2654435761 + self.seed) % 1000) / 1000.0
            f = self.hop_lo_hz + rng_f * (self.hop_hi_hz - self.hop_lo_hz) - center_hz
            on = np.mod(t, self.hop_period_s) < self.hop_period_s * self.duty
            # Відкинути стрибки поза смугою приймача (інакше — алiасинг у симуляції)
            on &= np.abs(f) < 0.45 * fs
            chirp_t = np.mod(t, 1e-3) / 1e-3
            inst = np.where(on, f + (chirp_t - 0.5) * self.bandwidth_hz, 0.0)
            base, off = np.exp(1j * 2 * np.pi * np.cumsum(inst) / fs) * on, 0.0
        elif self.kind == "nfm":
            # Рація: ЧМ з тоном 1 кГц, девіація 3 кГц
            ph = (3000 / 1000) * np.sin(2 * np.pi * 1000 * t)   # індекс β = девіація / тон
            base, off = np.exp(1j * ph), self.freq_hz - center_hz
        elif self.kind == "am":
            base, off = (1 + 0.6 * np.sin(2 * np.pi * 1000 * t)).astype(np.complex128), self.freq_hz - center_hz
        elif self.kind == "cw":
            base, off = np.ones(n, np.complex128), self.freq_hz - center_hz
        else:
            return None
        return (amp * _shift(base, off, fs)).astype(np.complex64)

    def _ofdm(self, n: int, fs: float, bw: float) -> np.ndarray:
        nfft = 256
        used = max(8, int(nfft * min(bw / fs, 0.95)) // 2 * 2)
        cp = nfft // 8
        sym = nfft + cp
        nsym = n // sym + 2
        data = np.zeros((nsym, nfft), dtype=np.complex64)
        qpsk = (self._rng.choice([-1, 1], (nsym, used)) + 1j * self._rng.choice([-1, 1], (nsym, used))) / math.sqrt(2)
        idx = np.r_[1:used // 2 + 1, nfft - used // 2:nfft]
        data[:, idx] = qpsk
        td = np.fft.ifft(data, axis=1) * (nfft / math.sqrt(used))   # одинична потужність
        td = np.concatenate([td[:, -cp:], td], axis=1).reshape(-1)
        return td[:n]


def default_scene() -> list[Emitter]:
    """Типова «бойова» сцена для демонстрації."""
    return [
        Emitter(5_769e6 + 0.9e6, "analog", power_dbm=-55, bandwidth_hz=9e6, seed=3),          # R4, зсунутий
        Emitter(5_880e6, "analog_inverted", power_dbm=-65, bandwidth_hz=9e6, seed=4),         # F8 / R7 інверсне
        Emitter(5_732e6, "analog_scrambled", power_dbm=-69, bandwidth_hz=9e6, seed=5),        # R3 скрембл
        Emitter(5_805e6, "ofdm", power_dbm=-67, bandwidth_hz=20e6, seed=6),                   # DJI ch5
        Emitter(1_240e6, "analog", power_dbm=-72, bandwidth_hz=9e6, standard="NTSC", seed=7),
        Emitter(0, "fhss", power_dbm=-62, bandwidth_hz=0.8e6, hop_lo_hz=2_402e6, hop_hi_hz=2_478e6,
                hop_period_s=4e-3, duty=0.6, seed=8),
        Emitter(0, "fhss", power_dbm=-67, bandwidth_hz=0.5e6, hop_lo_hz=903e6, hop_hi_hz=927e6,
                hop_period_s=6e-3, duty=0.5, seed=9),
        Emitter(2_437e6, "wifi", power_dbm=-77, bandwidth_hz=18e6, duty=0.3, seed=10),
    ]


class SimulatedSource(SdrSource):
    name = "simulator"

    # Модель тракту: dBFS = dBm + підсилення − CAL_DB (див. DistanceConfig.rx_cal_db)
    CAL_DB = 35.0

    def __init__(self, emitters: list[Emitter] | None = None, noise_dbfs: float = -62.0,
                 seed: int = 0) -> None:
        super().__init__()
        self.emitters = default_scene() if emitters is None else emitters
        self.noise_dbfs = noise_dbfs
        self.rng = np.random.default_rng(seed)
        self.clock = 0.0

    def open(self) -> None:
        pass

    def close(self) -> None:
        pass

    def tune(self, freq_hz: float) -> None:
        self.center_hz = float(freq_hz)
        self.clock += 1e-3  # час перебудови

    def set_sample_rate(self, rate: float) -> None:
        self.sample_rate = float(min(rate, self.max_sample_rate))

    def set_gain(self, lna: float, vga: float, amp: bool) -> None:
        self.lna_gain, self.vga_gain, self.amp = lna, vga, amp

    # Симулятор «вміє» передавати: TX нічого не випромінює, лише імітує таймінг (для демо/тестів)
    can_transmit = True

    def start_tx(self, freq_hz: float, sample_rate: float, gain_db: float, amp: bool = False) -> None:
        self.center_hz = float(freq_hz)
        self.sample_rate = float(min(sample_rate, self.max_sample_rate))
        self.tx_gain = gain_db

    def write_tx(self, iq: np.ndarray) -> int:
        time.sleep(len(iq) / max(self.sample_rate, 1.0))   # імітація швидкості передачі
        return len(iq)

    def stop_tx(self) -> None:
        pass

    def read(self, n: int) -> np.ndarray:
        fs = self.sample_rate
        t = self.clock + np.arange(n, dtype=np.float64) / fs
        self.clock += n / fs
        sigma = 10 ** (self.noise_dbfs / 20) / math.sqrt(2)
        out = (self.rng.standard_normal(n) + 1j * self.rng.standard_normal(n)) * sigma
        g = 10 ** ((self.total_gain_db - self.CAL_DB) / 20)
        for e in self.emitters:
            s = e.generate(t, fs, self.center_hz)
            if s is not None:
                out = out + s * g
        # 8-бітний АЦП HackRF: обмеження амплітуди (перевантаження)
        out = np.clip(out.real, -1, 1) + 1j * np.clip(out.imag, -1, 1)
        return out.astype(np.complex64)
