"""Приймач через SoapySDR: HackRF One, RTL-SDR, Airspy, LimeSDR, PlutoSDR, USRP..."""

from __future__ import annotations

import collections
import logging
import threading
import time

import numpy as np

from .base import SdrSource

log = logging.getLogger(__name__)

# Обмеження популярних приймачів (частоти, макс. частота дискретизації)
KNOWN_LIMITS = {
    "hackrf": (1e6, 6e9, 20e6),
    "rtlsdr": (24e6, 1.766e9, 2.4e6),
    "airspy": (24e6, 1.8e9, 10e6),
    "lime": (30e6, 3.8e9, 30e6),
    "plutosdr": (70e6, 6e9, 20e6),
    "uhd": (70e6, 6e9, 56e6),
}


# Після перенастройки частоти відкидаємо відліки, що вже були «в дорозі»: libhackrf тримає
# 4 USB-передачі по 131072 відліки (~26 мс при 20 МГц) + ~1 мс на захоплення PLL.
INFLIGHT_SAMPLES = 4 * 131072
SETTLE_S = 0.001
CHUNK = 65536                  # відліків за один readStream
MAX_BACKLOG_S = 0.25           # більше в кільці не тримаємо — найстаріше відкидається


class RxReader:
    """Окремий потік БЕЗПЕРЕРВНО забирає відліки з драйвера в кільце (як SDR++/gqrx).

    Без нього програма читала «на вимогу»: поки вона рахувала кадр, буфер драйвера переповнювався,
    а після перенастройки перші ~26 мс ще були зі СТАРОЇ частоти. Тепер:
      • драйвер ніколи не переповнюється (немає «дір» і рваних кадрів);
      • після tune() точно відкидається те, що було в дорозі (retune());
      • read(n) віддає найсвіжіші n відліків — затримка не накопичується.
    Перетворення int8 → complex64 — лише для того, що справді прочитали."""

    def __init__(self, src: "SoapySource") -> None:
        self.src = src
        self.cv = threading.Condition()
        self.chunks: collections.deque = collections.deque()
        self.avail = 0
        self.skip = 0
        self.run = False
        self.overflows = 0
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.run = True
        self.thread = threading.Thread(target=self._loop, daemon=True, name="sdr-rx")
        self.thread.start()

    def stop(self) -> None:
        self.run = False
        if self.thread:
            self.thread.join(timeout=2)
        self.thread = None
        with self.cv:
            self.chunks.clear()
            self.avail = 0

    def retune(self, discard: int) -> None:
        with self.cv:
            self.chunks.clear()
            self.avail = 0
            self.skip = discard

    def _loop(self) -> None:
        src = self.src
        cs8 = src._cs8
        buf = np.empty(2 * CHUNK, np.int8) if cs8 else np.empty(CHUNK, np.complex64)
        while self.run:
            try:
                sr = src.dev.readStream(src.stream, [buf], CHUNK, timeoutUs=200000)
            except Exception:  # noqa: BLE001 — плату від'єднали: сторожовий таймер перепідключить
                time.sleep(0.05)
                continue
            n = sr.ret
            if n <= 0:
                if n == -4:
                    self.overflows += 1
                else:
                    time.sleep(0.002)
                continue
            data = buf[: 2 * n].copy() if cs8 else buf[:n].copy()
            with self.cv:
                if self.skip:
                    k = min(self.skip, n)
                    self.skip -= k
                    if k == n:
                        continue
                    data = data[2 * k:] if cs8 else data[k:]
                    n -= k
                self.chunks.append(data)
                self.avail += n
                limit = int(src.sample_rate * MAX_BACKLOG_S) + CHUNK
                while self.avail > limit and len(self.chunks) > 1:
                    old = self.chunks.popleft()
                    self.avail -= len(old) // 2 if cs8 else len(old)
                self.cv.notify_all()

    def read(self, n: int, timeout_s: float) -> np.ndarray:
        cs8 = self.src._cs8
        w = 2 if cs8 else 1
        deadline = time.monotonic() + timeout_s
        with self.cv:
            while self.avail < n:
                left = deadline - time.monotonic()
                if left <= 0 or not self.run:
                    break
                self.cv.wait(left)
            # найсвіжіші дані: зайве старе (більше ніж n + 1 блок) — відкинути
            while self.avail - (len(self.chunks[0]) // w if self.chunks else 0) >= n and len(self.chunks) > 1:
                old = self.chunks.popleft()
                self.avail -= len(old) // w
            parts, got = [], 0
            while self.chunks and got < n:
                c = self.chunks.popleft()
                cn = len(c) // w
                take = min(cn, n - got)
                parts.append(c[: take * w])
                if take < cn:
                    self.chunks.appendleft(c[take * w:])
                got += take
                self.avail -= take
        if not parts:
            return np.zeros(0, np.complex64)
        raw = np.concatenate(parts) if len(parts) > 1 else parts[0]
        if cs8:
            return np.multiply(raw, np.float32(1 / 128), dtype=np.float32).view(np.complex64)
        return raw


class SoapySource(SdrSource):
    def __init__(self, device_args: str = "driver=hackrf", ppm: float = 0.0) -> None:
        super().__init__()
        self.device_args = device_args
        self.ppm = ppm
        self.dev = None
        self.stream = None
        self._buf = None
        self._cs8 = False
        self.rx: RxReader | None = None
        self.retune_discard = INFLIGHT_SAMPLES
        driver = dict(kv.split("=", 1) for kv in device_args.split(",") if "=" in kv).get("driver", "hackrf")
        self.name = driver
        lim = KNOWN_LIMITS.get(driver)
        if lim:
            self.min_freq_hz, self.max_freq_hz, self.max_sample_rate = lim

    def open(self, rate: float | None = None) -> None:
        import SoapySDR  # noqa: N813  (пакет python3-soapysdr)
        from SoapySDR import SOAPY_SDR_CF32, SOAPY_SDR_RX

        self._soapy = SoapySDR
        self._rx = SOAPY_SDR_RX
        self.sample_rate = 0.0          # нова сесія плати — частоту дискретизації виставляємо заново
        self.dev = SoapySDR.Device(self.device_args)
        try:
            rng = self.dev.getFrequencyRange(SOAPY_SDR_RX, 0)
            if rng:
                self.min_freq_hz = min(r.minimum() for r in rng)
                self.max_freq_hz = max(r.maximum() for r in rng)
        except Exception:  # noqa: BLE001 — не всі драйвери це вміють
            pass
        if self.ppm:
            try:
                self.dev.setFrequencyCorrection(SOAPY_SDR_RX, 0, self.ppm)
            except Exception:  # noqa: BLE001
                log.warning("Корекція ppm не підтримується драйвером")
        try:
            hw = dict(self.dev.getHardwareInfo())
            # SoapyHackRF: "version" — рядок версії прошивки, "part_id"/"serial" — плата
            self.firmware = hw.get("version") or hw.get("firmware") or hw.get("fw_version")
            self.hw_info = {k: str(v) for k, v in hw.items()}
        except Exception:  # noqa: BLE001
            pass
        if rate:
            self._apply_rate(rate)            # частота — ДО запуску потоку (HackRF так надійніше)
        self.stream = None
        self._start_stream()
        self.tx_stream = None
        try:
            self.can_transmit = self.dev.getNumChannels(self._soapy.SOAPY_SDR_TX) > 0
        except Exception:  # noqa: BLE001 — драйвер без TX (напр. RTL-SDR)
            self.can_transmit = False
        log.info("SDR відкрито: %s (передача: %s)", self.device_args, "є" if self.can_transmit else "немає")

    def close(self) -> None:
        if self.dev is not None:
            self._stop_stream()
        self.dev = None
        self.stream = None

    def tune(self, freq_hz: float) -> None:
        freq_hz = float(np.clip(freq_hz, self.min_freq_hz, self.max_freq_hz))
        if abs(freq_hz - (self.center_hz or 0)) < 1 and self.rx is not None:
            return                       # та сама частота — PLL не чіпаємо, потік не рветься
        self.dev.setFrequency(self._rx, 0, freq_hz)
        self.center_hz = freq_hz
        # Відкинути відліки, що були «в дорозі» зі старої частоти + час захоплення PLL
        if self.rx is not None:
            self.rx.retune(self.retune_discard + int(self.sample_rate * SETTLE_S))

    def _apply_rate(self, rate: float) -> None:
        rate = min(rate, self.max_sample_rate)
        self.dev.setSampleRate(self._rx, 0, rate)
        try:
            self.dev.setBandwidth(self._rx, 0, rate * 0.9)
        except Exception:  # noqa: BLE001
            pass
        try:
            actual = float(self.dev.getSampleRate(self._rx, 0))
        except Exception:  # noqa: BLE001
            actual = rate
        if abs(actual - rate) > rate * 0.01:
            log.warning("Частота дискретизації: просили %.3f МГц, плата дала %.3f МГц", rate / 1e6, actual / 1e6)
        self.sample_rate = actual

    def _start_stream(self) -> None:
        """Новий потік. Рідний формат HackRF — CS8 (8-біт I/Q): у 4 рази менше даних через драйвер;
        після повторної відсутності даних (no_data) — звичайний CF32."""
        from SoapySDR import SOAPY_SDR_CF32
        self._cs8 = False
        if getattr(self, "stream_format", "auto") in ("auto", "CS8") and getattr(self, "_no_data", 0) < 2:
            try:
                native, _scale = self.dev.getNativeStreamFormat(self._rx, 0)
                if native == "CS8":
                    self.stream = self.dev.setupStream(self._rx, "CS8")
                    self._cs8 = True
            except Exception:  # noqa: BLE001 — старий драйвер: звичайний CF32
                self._cs8 = False
        if not self._cs8:
            self.stream = self.dev.setupStream(self._rx, SOAPY_SDR_CF32)
        self.dev.activateStream(self.stream)
        self.rx = RxReader(self)
        self.rx.retune(int(self.sample_rate * SETTLE_S))
        self.rx.start()

    def _stop_stream(self) -> None:
        if self.rx is not None:
            self.rx.stop()
            self.rx = None
        if getattr(self, "stream", None) is None:
            return
        try:
            self.dev.deactivateStream(self.stream)
        except Exception:  # noqa: BLE001
            pass
        try:
            self.dev.closeStream(self.stream)
        except Exception:  # noqa: BLE001
            pass
        self.stream = None

    def note_no_data(self) -> None:
        """Сторожовий таймер: даних немає. Двічі поспіль — далі без CS8 (звичайний CF32)."""
        self._no_data = getattr(self, "_no_data", 0) + 1
        if self._no_data == 2:
            log.warning("HackRF не дає даних у форматі CS8 — переходжу на CF32")

    def set_sample_rate(self, rate: float) -> None:
        """Змінити частоту дискретизації: потік закривається, частота задається, потік створюється
        ЗАНОВО (повторний запуск старого потоку в HackRF інколи лишав його «німим»)."""
        rate = min(rate, self.max_sample_rate)
        if abs(rate - (self.sample_rate or 0)) < 1:
            return
        had = getattr(self, "stream", None) is not None
        if had:
            self._stop_stream()
        self._apply_rate(rate)
        if had:
            self._start_stream()

    def set_gain(self, lna: float, vga: float, amp: bool) -> None:
        names = self.dev.listGains(self._rx, 0)
        if "LNA" in names and "VGA" in names:  # HackRF
            self.dev.setGain(self._rx, 0, "LNA", float(lna))
            self.dev.setGain(self._rx, 0, "VGA", float(vga))
            if "AMP" in names:
                self.dev.setGain(self._rx, 0, "AMP", 14.0 if amp else 0.0)
        else:
            self.dev.setGain(self._rx, 0, float(lna + vga))
        self.lna_gain, self.vga_gain, self.amp = lna, vga, amp

    # ---- передавання ---------------------------------------------------------
    def start_tx(self, freq_hz: float, sample_rate: float, gain_db: float, amp: bool = False) -> None:
        from SoapySDR import SOAPY_SDR_CF32, SOAPY_SDR_TX
        tx = SOAPY_SDR_TX
        # Звільнити приймальний тракт (HackRF — напівдуплекс)
        self._stop_stream()
        self.dev.setSampleRate(tx, 0, min(sample_rate, self.max_sample_rate))
        try:
            self.dev.setBandwidth(tx, 0, min(sample_rate, self.max_sample_rate) * 0.9)
        except Exception:  # noqa: BLE001
            pass
        self.dev.setFrequency(tx, 0, float(np.clip(freq_hz, self.min_freq_hz, self.max_freq_hz)))
        names = self.dev.listGains(tx, 0)
        if "VGA" in names:  # HackRF: IF/VGA 0..47 дБ
            self.dev.setGain(tx, 0, "VGA", float(np.clip(gain_db, 0, 47)))
            if "AMP" in names:
                self.dev.setGain(tx, 0, "AMP", 14.0 if amp else 0.0)
        else:
            self.dev.setGain(tx, 0, float(gain_db))
        self.tx_stream = self.dev.setupStream(tx, SOAPY_SDR_CF32)
        self.dev.activateStream(self.tx_stream)
        self.center_hz = freq_hz
        log.info("TX увімкнено: %.3f МГц, VGA %.0f дБ, AMP %s", freq_hz / 1e6, gain_db, amp)

    def write_tx(self, iq: np.ndarray) -> int:
        if self.tx_stream is None:
            return 0
        iq = np.ascontiguousarray(iq, dtype=np.complex64)
        sent = 0
        deadline = time.monotonic() + max(1.0, len(iq) / max(self.sample_rate, 1.0) * 4)
        while sent < len(iq):
            sr = self.dev.writeStream(self.tx_stream, [iq[sent:]], len(iq) - sent, timeoutUs=500000)
            if sr.ret > 0:
                sent += sr.ret
            elif time.monotonic() > deadline:
                break
        return sent

    def stop_tx(self) -> None:
        if self.tx_stream is not None:
            try:
                self.dev.deactivateStream(self.tx_stream)
                self.dev.closeStream(self.tx_stream)
            except Exception:  # noqa: BLE001
                pass
            self.tx_stream = None
        try:
            self.center_hz = 0.0                      # після TX частоту приймання виставити заново
            self._start_stream()                      # повернути приймання (новий потік)
        except Exception:  # noqa: BLE001
            log.exception("Не вдалося повернути приймання після TX")
        log.info("TX вимкнено")

    def set_bias_tee(self, on: bool) -> None:
        """Живлення зовнішнього LNA по коаксіалу (HackRF: 3.3 В, до 50 мА)."""
        for key in ("bias_tx", "biastee", "bias_tee"):
            try:
                self.dev.writeSetting(key, "true" if on else "false")
                return
            except Exception:  # noqa: BLE001 — назва налаштування залежить від драйвера
                continue

    def read(self, n: int, timeout_us: int = 500000) -> np.ndarray:
        """n найсвіжіших відліків поточної частоти (complex64). Менше — якщо плата не дала даних."""
        if self.rx is None:
            return np.zeros(0, np.complex64)
        return self.rx.read(n, max(timeout_us / 1e6, n / max(self.sample_rate, 1.0) * 4, 0.5))
