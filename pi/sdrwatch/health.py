"""Стан модуля: температура ЦП, навантаження, живлення, пам'ять, флешка, HackRF.

Збирається в основному процесі раз на 5 с (читання кількох файлів /proc і /sys — копійки),
історія за останню годину — для графіків у застосунку.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from collections import deque

# Біти `vcgencmd get_throttled` (Raspberry Pi)
_THROTTLE = {
    0: "просідання живлення ЗАРАЗ",
    1: "частоту ЦП обмежено ЗАРАЗ",
    2: "троттлінг ЗАРАЗ",
    3: "м'яке обмеження температури ЗАРАЗ",
    16: "було просідання живлення",
    17: "було обмеження частоти",
    18: "був троттлінг",
    19: "було обмеження температури",
}


def _read(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def _throttled() -> tuple[int | None, list[str]]:
    try:
        out = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=2).stdout
        v = int(out.strip().split("=")[1], 16)
    except (OSError, IndexError, ValueError, subprocess.SubprocessError):
        return None, []
    return v, [t for b, t in _THROTTLE.items() if v & (1 << b)]


def _cpu_times() -> tuple[int, int] | None:
    s = _read("/proc/stat")
    if not s:
        return None
    v = [int(x) for x in s.splitlines()[0].split()[1:]]
    idle = v[3] + (v[4] if len(v) > 4 else 0)
    return sum(v), idle


class Health:
    def __init__(self, storage_path: str, engine=None) -> None:
        self.storage_path = storage_path
        self.engine = engine
        self.history: deque = deque(maxlen=720)       # 1 година по 5 с
        self.current: dict = {}
        self._prev_cpu = _cpu_times()
        self._lock = threading.Lock()

    def start(self, hub=None) -> None:
        def loop():
            while True:
                snap = self.sample()
                if hub is not None:
                    hub.publish("live", {"type": "health", **snap})
                time.sleep(5)

        threading.Thread(target=loop, daemon=True, name="health").start()

    def sample(self) -> dict:
        now = time.time()
        temp = _read("/sys/class/thermal/thermal_zone0/temp")
        freq = _read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
        cur = _cpu_times()
        cpu_pct = None
        if cur and self._prev_cpu:
            dt, di = cur[0] - self._prev_cpu[0], cur[1] - self._prev_cpu[1]
            cpu_pct = round(100 * (1 - di / dt), 1) if dt > 0 else None
        self._prev_cpu = cur
        mem = {}
        for line in (_read("/proc/meminfo") or "").splitlines():
            k, _, v = line.partition(":")
            if k in ("MemTotal", "MemAvailable"):
                mem[k] = int(v.split()[0]) // 1024
        try:
            du = shutil.disk_usage(self.storage_path if os.path.exists(self.storage_path) else "/")
            disk = {"total_mb": du.total // 2**20, "free_mb": du.free // 2**20}
        except OSError:
            disk = {}
        thr, thr_text = _throttled()
        load = os.getloadavg() if hasattr(os, "getloadavg") else (0, 0, 0)
        up = _read("/proc/uptime")
        snap = {
            "ts": now,
            "cpu_temp_c": round(int(temp) / 1000, 1) if temp and temp.isdigit() else None,
            "cpu_pct": cpu_pct,
            "cpu_mhz": int(freq) // 1000 if freq and freq.isdigit() else None,
            "cores": os.cpu_count(),
            "load": [round(x, 2) for x in load],
            "mem_total_mb": mem.get("MemTotal"),
            "mem_free_mb": mem.get("MemAvailable"),
            "disk": disk,
            "throttled": thr,
            "throttled_text": thr_text,
            "undervoltage": bool(thr is not None and thr & 0x1),
            "uptime_s": int(float(up.split()[0])) if up else None,
        }
        # Попередження для застосунку
        warn = []
        if snap["cpu_temp_c"] is not None and snap["cpu_temp_c"] >= 80:
            warn.append(f"Перегрів ЦП: {snap['cpu_temp_c']} °C")
        if snap["undervoltage"]:
            warn.append("Просідання живлення — слабкий блок живлення/кабель")
        if disk.get("free_mb") is not None and disk["free_mb"] < 200:
            warn.append("Мало місця на флешці")
        snap["warnings"] = warn
        with self._lock:
            self.current = snap
            self.history.append({k: snap[k] for k in ("ts", "cpu_temp_c", "cpu_pct")})
        return snap

    def report(self) -> dict:
        with self._lock:
            return {"current": self.current or self.sample(), "history": list(self.history)}
