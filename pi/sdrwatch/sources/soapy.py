"""Приймач через SoapySDR: HackRF One, RTL-SDR, Airspy, LimeSDR, PlutoSDR, USRP..."""

from __future__ import annotations

import logging
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


class SoapySource(SdrSource):
    def __init__(self, device_args: str = "driver=hackrf", ppm: float = 0.0) -> None:
        super().__init__()
        self.device_args = device_args
        self.ppm = ppm
        self.dev = None
        self.stream = None
        self._buf = None
        driver = dict(kv.split("=", 1) for kv in device_args.split(",") if "=" in kv).get("driver", "hackrf")
        self.name = driver
        lim = KNOWN_LIMITS.get(driver)
        if lim:
            self.min_freq_hz, self.max_freq_hz, self.max_sample_rate = lim

    def open(self) -> None:
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
        # Рідний формат HackRF — CS8 (8-біт I/Q). Читаємо його напряму: у 4 рази менше даних через
        # драйвер і пам'ять, ніж CF32 (float), а в float перетворюємо лише те, що прочитали.
        self._cs8 = False
        try:
            native, _scale = self.dev.getNativeStreamFormat(SOAPY_SDR_RX, 0)
            if native == "CS8" and getattr(self, "stream_format", "auto") in ("auto", "CS8"):
                self.stream = self.dev.setupStream(SOAPY_SDR_RX, "CS8")
                self._cs8 = True
        except Exception:  # noqa: BLE001 — старий драйвер: звичайний CF32
            self._cs8 = False
        if not self._cs8:
            self.stream = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32)
        self.dev.activateStream(self.stream)
        self.tx_stream = None
        try:
            self.can_transmit = self.dev.getNumChannels(self._soapy.SOAPY_SDR_TX) > 0
        except Exception:  # noqa: BLE001 — драйвер без TX (напр. RTL-SDR)
            self.can_transmit = False
        log.info("SDR відкрито: %s (передача: %s)", self.device_args, "є" if self.can_transmit else "немає")

    def close(self) -> None:
        if self.dev is not None and self.stream is not None:
            try:
                self.dev.deactivateStream(self.stream)
                self.dev.closeStream(self.stream)
            except Exception:  # noqa: BLE001
                pass
        self.dev = None
        self.stream = None

    def tune(self, freq_hz: float) -> None:
        freq_hz = float(np.clip(freq_hz, self.min_freq_hz, self.max_freq_hz))
        self.dev.setFrequency(self._rx, 0, freq_hz)
        self.center_hz = freq_hz
        # Скинути «старі» відліки з буфера після перебудови PLL
        self._flush()

    def set_sample_rate(self, rate: float) -> None:
        """Змінити частоту дискретизації. Під час активного потоку деякі драйвери (HackRF) її не
        застосовують — тоді плата лишалася на 20 МГц, а звук рахувався як для 2.4 МГц (лише шум).
        Тому: зупинити потік → задати частоту й смугу → перевірити фактичну → запустити потік."""
        rate = min(rate, self.max_sample_rate)
        if abs(rate - (self.sample_rate or 0)) < 1:
            return
        active = getattr(self, "stream", None) is not None
        restarted = False
        if active:
            try:
                self.dev.deactivateStream(self.stream)
                restarted = True
            except Exception as e:  # noqa: BLE001
                log.warning("deactivateStream: %s", e)
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
        if restarted:
            try:
                self.dev.activateStream(self.stream)
            except Exception as e:  # noqa: BLE001 — потік не запустився: створити заново
                log.warning("activateStream після зміни частоти: %s — створюю потік заново", e)
                try:
                    self.dev.closeStream(self.stream)
                except Exception:  # noqa: BLE001
                    pass
                fmt = "CS8" if getattr(self, "_cs8", False) else self._soapy.SOAPY_SDR_CF32
                self.stream = self.dev.setupStream(self._rx, fmt)
                self.dev.activateStream(self.stream)
            try:
                self._flush(30)          # викинути відліки, що встигли прийти на старій частоті
            except Exception:  # noqa: BLE001
                pass

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
        try:
            self.dev.deactivateStream(self.stream)
        except Exception:  # noqa: BLE001
            pass
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
            self.dev.activateStream(self.stream)      # повернути приймання
        except Exception:  # noqa: BLE001
            pass
        log.info("TX вимкнено")

    def set_bias_tee(self, on: bool) -> None:
        """Живлення зовнішнього LNA по коаксіалу (HackRF: 3.3 В, до 50 мА)."""
        for key in ("bias_tx", "biastee", "bias_tee"):
            try:
                self.dev.writeSetting(key, "true" if on else "false")
                return
            except Exception:  # noqa: BLE001 — назва налаштування залежить від драйвера
                continue

    def _flush(self, ms: float = 2.0) -> None:
        if self.sample_rate:
            self.read(int(self.sample_rate * ms / 1000), timeout_us=20000)

    def read(self, n: int, timeout_us: int = 500000) -> np.ndarray:
        if getattr(self, "_cs8", False):
            return self._read_cs8(n, timeout_us)
        out = np.empty(n, dtype=np.complex64)
        got = 0
        deadline = time.monotonic() + max(1.0, n / max(self.sample_rate, 1.0) * 4)
        while got < n:
            sr = self.dev.readStream(self.stream, [out[got:]], n - got, timeoutUs=timeout_us)
            if sr.ret > 0:
                got += sr.ret
            elif sr.ret == -4:  # SOAPY_SDR_OVERFLOW — пропуск відліків, читаємо далі
                continue
            elif time.monotonic() > deadline:
                break
        return out[:got] if got < n else out

    def _read_cs8(self, n: int, timeout_us: int) -> np.ndarray:
        buf = np.empty(2 * n, dtype=np.int8)
        got = 0
        deadline = time.monotonic() + max(1.0, n / max(self.sample_rate, 1.0) * 4)
        while got < n:
            sr = self.dev.readStream(self.stream, [buf[2 * got:]], n - got, timeoutUs=timeout_us)
            if sr.ret > 0:
                got += sr.ret
            elif sr.ret == -4:  # переповнення — пропуск відліків, читаємо далі
                continue
            elif time.monotonic() > deadline:
                break
        # int8 I,Q → complex64, повна шкала 128
        return np.multiply(buf[: 2 * got], np.float32(1 / 128), dtype=np.float32).view(np.complex64)
