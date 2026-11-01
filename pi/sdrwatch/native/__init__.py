"""Прискорені (C) ділянки обробки. Якщо бібліотеки немає й зібрати не вдалося — повертається None,
а код використовує numpy (повільніше, але працює всюди)."""

from __future__ import annotations

import ctypes
import logging
import os
import shutil
import subprocess
import threading

import numpy as np

log = logging.getLogger(__name__)
_HERE = os.path.dirname(__file__)
_SRC = os.path.join(_HERE, "fastdsp.c")
_lib = None
_tried = False
_lock = threading.Lock()


def _candidates() -> list[str]:
    return [os.path.join(_HERE, "libfastdsp.so"), "/opt/sdrwatch/lib/libfastdsp.so",
            os.path.join(os.environ.get("SDRWATCH_CACHE", "/tmp"), "sdrwatch-libfastdsp.so")]


def _build(dst: str) -> bool:
    cc = shutil.which("cc") or shutil.which("gcc")
    if not cc or not os.path.exists(_SRC):
        return False
    flags = ["-O3", "-ffast-math", "-shared", "-fPIC"]
    try:
        r = subprocess.run([cc, *flags, "-o", dst, _SRC, "-lm"], capture_output=True, timeout=60)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def lib():
    """ctypes-бібліотека або None."""
    global _lib, _tried
    if _tried:
        return _lib
    with _lock:
        if _tried:
            return _lib
        _tried = True
        if os.environ.get("SDRWATCH_NO_NATIVE"):
            return None
        for p in _candidates():
            if not os.path.exists(p):
                continue
            try:
                _lib = _setup(ctypes.CDLL(p))
                return _lib
            except OSError:
                continue
        dst = _candidates()[-1]
        if _build(dst):
            try:
                _lib = _setup(ctypes.CDLL(dst))
                log.info("Прискорення C зібрано: %s", dst)
            except OSError:
                _lib = None
        return _lib


def _setup(L):
    fp = ctypes.POINTER(ctypes.c_float)
    for name, src_t in (("fm_baseband", fp), ("fm_baseband_cs8", ctypes.POINTER(ctypes.c_int8))):
        f = getattr(L, name)
        f.argtypes = [src_t, ctypes.c_long, ctypes.c_long, ctypes.c_float, fp, fp]
        f.restype = ctypes.c_long
    return L


def fm_baseband(iq: np.ndarray, fs: float, decim: int) -> np.ndarray | None:
    """ЧМ-детектор + проріджування (середнє по decim), Гц. None — якщо прискорення немає."""
    L = lib()
    if L is None:
        return None
    x = np.ascontiguousarray(iq, dtype=np.complex64)
    n = len(x)
    out = np.empty(n // decim, np.float32)
    prev = np.array([x[0].real, x[0].imag] if n else [1, 0], np.float32)
    fp = ctypes.POINTER(ctypes.c_float)
    k = L.fm_baseband(x.view(np.float32).ctypes.data_as(fp), n, decim, float(fs / (2 * np.pi)),
                      prev.ctypes.data_as(fp), out.ctypes.data_as(fp))
    return out[:k]
