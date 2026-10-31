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
        self.stream = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32)
        self.dev.activateStream(self.stream)
        log.info("SDR відкрито: %s", self.device_args)

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
        rate = min(rate, self.max_sample_rate)
        self.dev.setSampleRate(self._rx, 0, rate)
        try:
            self.dev.setBandwidth(self._rx, 0, rate * 0.9)
        except Exception:  # noqa: BLE001
            pass
        self.sample_rate = rate

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
