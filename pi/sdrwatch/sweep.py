"""Швидкий огляд ефіру режимом sweep ПРОШИВКИ HackRF (утиліта hackrf_sweep).

У звичайному режимі Python сам перебудовує приймач на кожне вікно ~16 МГц і чекає відліки —
це сотні перебудов за прохід. У режимі sweep перебудовує сама прошивка HackRF, а програма
отримує готові рядки спектра: увесь діапазон 1–6000 МГц за частки секунди (так працюють
hackrf_sweep, QSpectrumAnalyzer, HackRF FPV Scanner).

Формат рядка hackrf_sweep (текстовий):
    дата, час, hz_low, hz_high, hz_bin_width, num_samples, dB, dB, ...
Один рядок — смуга 5 МГц; коли hz_low повертається на початок — прохід завершено.
"""

from __future__ import annotations

import logging
import queue
import shutil
import subprocess
import threading
import time

import numpy as np

log = logging.getLogger(__name__)


def available(cmd: list[str] | None = None) -> bool:
    return bool(cmd) or shutil.which("hackrf_sweep") is not None


def parse_line(line: str) -> tuple[float, float, float, np.ndarray] | None:
    """Рядок hackrf_sweep → (hz_low, hz_high, bin_hz, рівні дБ)."""
    parts = line.split(",")
    if len(parts) < 7:
        return None
    try:
        lo, hi, bw = float(parts[2]), float(parts[3]), float(parts[4])
        vals = np.array(parts[6:], dtype=np.float32)
    except ValueError:
        return None
    if hi <= lo or bw <= 0 or not len(vals):
        return None
    return lo, hi, bw, vals


class Sweeper:
    """Процес hackrf_sweep + потік читання. Повні проходи — у черзі `sweeps` як (рівні, час проходу)."""

    def __init__(self, start_hz: float, stop_hz: float, bin_hz: float, lna: float, vga: float, amp: bool,
                 cmd: list[str] | None = None) -> None:
        # hackrf_sweep приймає межі в цілих МГц
        self.lo_mhz = max(0, int(start_hz // 1e6))
        self.hi_mhz = max(self.lo_mhz + 20, int(-(-stop_hz // 1e6)))
        self.bin_hz = float(bin_hz)
        self.start_hz = self.lo_mhz * 1e6
        self.n = int(round((self.hi_mhz - self.lo_mhz) * 1e6 / self.bin_hz))
        self.spec = np.full(self.n, np.nan, np.float32)
        self.sweeps: queue.Queue = queue.Queue(maxsize=2)
        self.error: str | None = None
        lna = int(max(0, min(40, round(lna / 8) * 8)))
        vga = int(max(0, min(62, round(vga / 2) * 2)))
        base = cmd or ["hackrf_sweep"]
        self.args = base + ["-f", f"{self.lo_mhz}:{self.hi_mhz}", "-w", str(int(self.bin_hz)),
                            "-l", str(lna), "-g", str(vga), "-a", "1" if amp else "0"]
        self.proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self.sweep_s = 0.0

    def start(self) -> None:
        self.proc = subprocess.Popen(self.args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     bufsize=1 << 16)
        self._thread = threading.Thread(target=self._read, daemon=True, name="hackrf-sweep")
        self._thread.start()
        threading.Thread(target=self._read_err, daemon=True, name="hackrf-sweep-err").start()

    def _read_err(self) -> None:
        assert self.proc and self.proc.stderr
        for line in self.proc.stderr:
            line = line.strip()
            if line and ("error" in line.lower() or "fail" in line.lower() or "not found" in line.lower()):
                self.error = line

    def _read(self) -> None:
        assert self.proc and self.proc.stdout
        last_lo = None
        t0 = time.monotonic()
        for line in self.proc.stdout:
            p = parse_line(line)
            if p is None:
                continue
            lo, hi, bw, vals = p
            if last_lo is not None and lo < last_lo:
                # початок нового проходу: попередній — готовий
                now = time.monotonic()
                self.sweep_s = now - t0
                t0 = now
                if self.sweeps.full():
                    try:
                        self.sweeps.get_nowait()   # повільний споживач — беремо найсвіжіше
                    except queue.Empty:
                        pass
                self.sweeps.put((self.spec.copy(), self.sweep_s))
            last_lo = lo
            a = int(round((lo - self.start_hz) / self.bin_hz))
            if abs(bw - self.bin_hz) > 1:
                # прошивка обрала іншу ширину біна — перерахувати на нашу сітку
                i0 = max(0, int(np.ceil((lo - self.start_hz) / self.bin_hz - 0.5)))
                i1 = min(self.n, int(np.floor((hi - self.start_hz) / self.bin_hz - 0.5)) + 1)
                if i1 > i0:
                    src = lo + (np.arange(len(vals)) + 0.5) * bw
                    dst = self.start_hz + (np.arange(i0, i1) + 0.5) * self.bin_hz
                    self.spec[i0:i1] = np.interp(dst, src, vals)
                continue
            b = min(self.n, a + len(vals))
            if b > a >= 0:
                self.spec[a:b] = vals[: b - a]
        if self.proc.poll() is None:
            return
        if not self.error:
            self.error = f"hackrf_sweep завершився (код {self.proc.returncode})"

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=2)
        self.proc = None

    def freqs(self) -> np.ndarray:
        return self.start_hz + (np.arange(self.n) + 0.5) * self.bin_hz
