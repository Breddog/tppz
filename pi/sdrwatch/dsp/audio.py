"""Звук з ефіру: вузька ЧМ (рації, голос), широка ЧМ (мовлення), АМ (авіадіапазон).

HackRF у режимі звуку працює на 2.4 МГц смуги — це в ~8 разів менше даних, ніж при 20 МГц.
Ланцюг: перенесення каналу на 0 Гц (з безперервною фазою між блоками) → ФНЧ + проріджування
2.4 МГц → 240 кГц → демодуляція → звуковий ФНЧ → 24 кГц, 16-біт моно.
Фільтрація overlap-save через FFT, із «хвостом» попереднього блоку — без клацань на стиках.
На телефон іде готовий звук (~48 КБ/с), а не сирі відліки (≈10 МБ/с) — інакше мережа не потягне.
"""

from __future__ import annotations

import numpy as np

from .filters import lowpass_taps

SDR_RATE = 2.4e6        # частота дискретизації SDR у режимі звуку
MID_RATE = 240e3        # після першого проріджування
AUDIO_RATE = 24000      # звук на телефон
TUNE_OFFSET = 250e3     # налаштовуємось трохи вбік, щоб DC-пік HackRF не потрапив у канал

MODES = {
    "nfm": "ЧМ вузька (рації, голос)",
    "wfm": "ЧМ широка (FM-мовлення)",
    "am": "АМ (авіація, СВ/КВ)",
}

# Смуга каналу для кожної модуляції (Гц, половина ширини)
_CHAN_HALF = {"nfm": 8e3, "wfm": 100e3, "am": 5e3}


class _OverlapFir:
    """Потоковий КІХ-фільтр (overlap-save) з пам'яттю між блоками."""

    def __init__(self, taps: np.ndarray, complex_data: bool) -> None:
        self.taps = taps.astype(np.complex64 if complex_data else np.float32)
        self.hist = np.zeros(len(taps) - 1, np.complex64 if complex_data else np.float32)

    def __call__(self, x: np.ndarray) -> np.ndarray:
        buf = np.concatenate([self.hist, x])
        n = len(buf)
        nfft = 1 << (n + len(self.taps) - 1 - 1).bit_length()
        y = np.fft.ifft(np.fft.fft(buf, nfft) * np.fft.fft(self.taps, nfft))[:n]
        if not np.iscomplexobj(x):
            y = y.real
        k = len(self.taps) - 1
        self.hist = buf[-k:] if k else self.hist
        return y[k:].astype(x.dtype)


class AudioDemod:
    def __init__(self, mode: str = "nfm") -> None:
        self.set_mode(mode)

    def set_mode(self, mode: str) -> None:
        if mode not in MODES:
            raise ValueError("Невідома модуляція")
        self.mode = mode
        half = _CHAN_HALF[mode]
        # 2.4 МГц → 240 кГц: зріз трохи ширше за канал (для WFM ±100 кГц)
        self.f1 = _OverlapFir(lowpass_taps(min(0.045, max(half * 1.2, 15e3) / SDR_RATE), 95), True)
        if mode == "wfm":
            self.f2 = _OverlapFir(lowpass_taps(15e3 / MID_RATE, 63), False)        # звук 15 кГц
        else:
            self.f2 = _OverlapFir(lowpass_taps(half / MID_RATE, 63), True)          # канал
        self.f3 = _OverlapFir(lowpass_taps(4e3 / AUDIO_RATE if mode != "wfm" else 0.45, 31), False)
        self.phase = 0.0
        self._rem = None
        self.prev = np.complex64(1)
        self.deemph = 0.0
        self.agc: float | None = None

    def channel(self, iq: np.ndarray, offset_hz: float) -> tuple[np.ndarray, float, float]:
        """Вирізати канал для демодуляції НА ТЕЛЕФОНІ — найдешевшим способом (як rtl_fm):
        перенесення на 0 Гц (таблиця гетеродина) + проріджування підсумовуванням (коробковий фільтр).
        Точний фільтр каналу, демодуляцію, шумодав і гучність робить телефон.
        ЧМ вузька / АМ — 48 кГц (сума по 50), ЧМ широка — 240 кГц (сума по 10)."""
        d = 10 if self.mode == "wfm" else 50
        x = iq.astype(np.complex64, copy=False)
        if getattr(self, "_rem", None) is not None and len(self._rem):
            x = np.concatenate([self._rem, x])
        m = (len(x) // d) * d
        self._rem = x[m:]
        x = x[:m]
        w = -2 * np.pi * offset_hz / SDR_RATE
        key = (m, round(w, 12))
        if getattr(self, "_lo_key", None) != key:
            self._lo_key = key
            self._lo = np.exp(1j * w * np.arange(m)).astype(np.complex64)
        y = (x * self._lo * np.complex64(np.exp(1j * self.phase))).reshape(-1, d).mean(axis=1)
        self.phase = float((self.phase + w * m) % (2 * np.pi))
        p = float(np.mean(np.abs(y) ** 2)) + 1e-20 if len(y) else 1e-20
        return y.astype(np.complex64), SDR_RATE / d, float(10 * np.log10(p))

    def process(self, iq: np.ndarray, offset_hz: float) -> tuple[np.ndarray, float]:
        """iq на SDR_RATE → (звук int16 на AUDIO_RATE, потужність каналу в дБ відносно повної шкали)."""
        n = len(iq)
        # Перенесення каналу на 0 Гц із безперервною фазою
        w = -2 * np.pi * offset_hz / SDR_RATE
        lo = np.exp(1j * (self.phase + w * np.arange(n))).astype(np.complex64)
        self.phase = float((self.phase + w * n) % (2 * np.pi))
        x = self.f1(iq.astype(np.complex64) * lo)[::10]                       # 240 кГц
        if self.mode == "wfm":
            ch_pow = float(np.mean(np.abs(x) ** 2)) + 1e-20
            d = np.angle(x * np.conj(np.concatenate([[self.prev], x[:-1]])))
            self.prev = x[-1] if len(x) else self.prev
            a = self.f2(d.astype(np.float32))[::10]                            # 24 кГц
            # Деакцент 50 мкс (Європа)
            alpha = 1.0 - np.exp(-1.0 / (AUDIO_RATE * 50e-6))
            out = np.empty_like(a)
            y = self.deemph
            for i, v in enumerate(a):                                          # 2400 відліків — дешево
                y += alpha * (v - y)
                out[i] = y
            self.deemph = y
            audio = out / (2 * np.pi * 75e3 / MID_RATE) * 0.8     # девіація мовлення 75 кГц → ~0.8 шкали
        else:
            x = self.f2(x)[::10]                                               # 24 кГц, канал
            ch_pow = float(np.mean(np.abs(x) ** 2)) + 1e-20
            if self.mode == "nfm":
                d = np.angle(x * np.conj(np.concatenate([[self.prev], x[:-1]])))
                self.prev = x[-1] if len(x) else self.prev
                audio = d / np.pi * 2.5                                        # девіація ~5 кГц → повна шкала
            else:  # am
                env = np.abs(x)
                # АРП: середній рівень несучої (перший блок — одразу, далі плавно)
                m = float(np.mean(env) + 1e-12)
                self.agc = m if self.agc is None else 0.7 * self.agc + 0.3 * m
                audio = (env - self.agc) / (self.agc * 1.2)
            audio = self.f3(audio.astype(np.float32))
        audio = audio - float(np.mean(audio)) * 0.02
        pcm = np.clip(audio * 30000, -32767, 32767).astype("<i2")
        return pcm, float(10 * np.log10(ch_pow))


IQ_HEADER = None


def iq_packet(x: np.ndarray, rate: float, freq_hz: float, mode: str, level_db: float | None, squelch_db: float,
              is_open: bool) -> bytes:
    """Пакет вузької смуги для телефона: заголовок + int16 I/Q (масштаб — у заголовку).

    36 байт: magic b"SDRA", ver u8 1, mode u8 (0 nfm, 1 wfm, 2 am), flags u16 (bit0 — шумодав відкритий),
    freq f64, rate f32, scale f32 (значення = int16 × scale), level f32 (дБ над шумом), squelch f32, n u32.
    """
    import struct
    global IQ_HEADER
    if IQ_HEADER is None:
        IQ_HEADER = struct.Struct("<4sBBHdffffI")
    x = np.ascontiguousarray(x, dtype=np.complex64)
    peak = float(np.max(np.abs(x.view(np.float32)))) if len(x) else 1.0
    scale = max(peak, 1e-9) / 32000.0
    q = np.clip(np.round(x.view(np.float32) / scale), -32767, 32767).astype("<i2")
    head = IQ_HEADER.pack(b"SDRA", 1, {"nfm": 0, "wfm": 1, "am": 2}[mode], 1 if is_open else 0, float(freq_hz),
                          float(rate), scale, float(level_db if level_db is not None else -99.0),
                          float(squelch_db), len(x))
    return head + q.tobytes()


def window_levels(iq: np.ndarray, center_hz: float, freqs: list[float], squelch_db: float,
                  half_bw_hz: float = 8e3, fft_size: int = 8192) -> list[tuple[float, float]]:
    """Те саме, що window_peaks, але для довільного списку частот (сканування збережених каналів)."""
    from .spectrum import psd_db
    s = psd_db(iq, fft_size, 4)
    bin_hz = SDR_RATE / fft_size
    noise = float(np.median(s))
    hb = max(1, int(half_bw_hz / bin_hz))
    out = []
    for f in freqs:
        if abs(f - center_hz) < 20e3 or abs(f - center_hz) > 1.05e6:
            continue
        i = int(round((f - center_hz) / bin_hz + fft_size / 2))
        if hb <= i < fft_size - hb:
            lvl = float(np.max(s[i - hb:i + hb + 1])) - noise
            if lvl > squelch_db:
                out.append((f, lvl))
    return sorted(out, key=lambda p: -p[1])


def window_peaks(iq: np.ndarray, center_hz: float, step_hz: float, start_hz: float, stop_hz: float,
                 squelch_db: float, half_bw_hz: float = 8e3, fft_size: int = 8192) -> list[tuple[float, float]]:
    """Канали сітки (start + k·step) у вікні ±1 МГц навколо center, де є сигнал вище шуму на squelch_db.

    Повертає [(частота, перевищення дБ)], від найсильнішого. Так автоскан перевіряє ~2 МГц ефіру
    одним записом замість перебудови на кожен канал.
    """
    from .spectrum import psd_db
    s = psd_db(iq, fft_size, 4)
    bin_hz = SDR_RATE / fft_size
    noise = float(np.median(s))
    out = []
    lo = max(start_hz, center_hz - 1.0e6)
    hi = min(stop_hz, center_hz + 1.0e6)
    k0 = int(np.ceil((lo - start_hz) / step_hz))
    k1 = int(np.floor((hi - start_hz) / step_hz))
    hb = max(1, int(half_bw_hz / bin_hz))

    def level(f: float) -> float | None:
        i = int(round((f - center_hz) / bin_hz + fft_size / 2))
        return float(np.max(s[i - hb:i + hb + 1])) - noise if hb <= i < fft_size - hb else None

    for k in range(k0, k1 + 1):
        f = start_hz + k * step_hz
        if abs(f - center_hz) < 20e3:          # біля нуля — DC-пік HackRF, пропускаємо
            continue
        lvl = level(f)
        if lvl is None or lvl <= squelch_db:
            continue
        # Лише місцевий максимум: сусідній канал «бризкає» тим самим сигналом — його не беремо
        nb = [level(f + d) for d in (-step_hz, step_hz)]
        if any(v is not None and v > lvl + 0.5 for v in nb):
            continue
        out.append((f, lvl))
    return sorted(out, key=lambda p: -p[1])
