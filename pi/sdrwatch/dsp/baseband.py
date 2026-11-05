"""«Сирий» відеосигнал для телефона: Pi робить лише найдешевше — ЧМ-дискримінатор і проріджування.

Усе важке (синхронізація рядків/кадрів, полярність, рівні, накопичення слабких сигналів,
дескремблювання, побудова растру і показ) робить ТЕЛЕФОН. Так зникає затримка Pi.

Чому не «чисте» IQ: аналогове FPV займає ~15–20 МГц, тож IQ — це 20 Мвідл/с × 2 байти = 40 МБ/с,
що не пролізе ні через Wi-Fi Pi, ні через точку доступу телефона. Після дискримінатора це вже
звичайний композитний відеосигнал (~5 МГц), його достатньо ~4 Мвідл/с × 1 байт ≈ 13 Мбіт/с за
20 полів/с — і нічого з картинки не втрачається, бо сам растр і синхронізацію Pi не чіпає.

Пакет (little-endian), далі — відліки:
    magic   4s   b"SDRB"
    ver     u8   1
    bits    u8   8 або 4 (4 біти: два відліки в байті, старший — перший)
    flags   u16  bit0 — Pi бачить рядкову синхронізацію (є відео), bit1 — інверсія
    freq    f64  частота настройки, Гц
    fs      f32  частота відліків у пакеті, Гц
    lo, hi  f32  значення 0 і максимального коду в Гц девіації (для AFC/девіації)
    n       u32  кількість відліків
Колір (flags bit2, лише якщо клієнт попросив color=1) — одразу після відліків яскравості:
    magic   4s   b"CHRM"
    fs_c    f32  частота відліків кольору, Гц (~1 МГц)
    fsc     f32  піднесуча, на якій їх знято (PAL 4.43 / NTSC 3.58 МГц)
    scale   f32  Гц на одиницю int8
    delay   f32  зсув часу відліку кольору відносно яскравості з тим самим часом, с
    n_c     u32  кількість комплексних відліків, далі n_c пар int8 (re, im)
Модуль лише множить на піднесучу й проріджує (одна операція в тому ж проході C);
фазу сплеску, PAL-перемикання, лінію затримки і YUV→RGB рахує телефон.
"""

from __future__ import annotations

import struct

import numpy as np

from .filters import fm_demod
from .video import STD, _find_sync

HEADER = struct.Struct("<4sBBHdfffI")
CHROMA = struct.Struct("<4sffffI")
CHROMA_FS = 1.0e6
FSC = {"PAL": 4.43361875e6, "NTSC": 3.579545e6}
_std_memory: dict[int, str] = {}       # частота (МГц) → останній визначений стандарт
MAGIC = b"SDRB"
MAX_FPS = 25              # більше полів/с не шлемо: стільки й показує екран, а мережа не нескінченна
FIELD_S = 0.0205          # трохи більше за одне поле PAL (20 мс): телефон «прокручує» його до кадрового імпульсу
QUALITY = {               # назва → (цільова частота відліків, біт)
    "economy": (3.0e6, 4),
    "normal": (4.0e6, 8),
    "detail": (6.7e6, 8),
}


def decimation(fs: float, target_fs: float) -> int:
    return max(1, int(round(fs / target_fs)))


def make_packet(iq: np.ndarray, fs: float, freq_hz: float, quality: str = "normal",
                color: bool = False) -> tuple[bytes, dict]:
    """IQ (complex64) → пакет для телефона + легкий аналіз для автоскану/AFC на самому Pi."""
    target, bits = QUALITY.get(quality, QUALITY["normal"])
    k = decimation(fs, target)
    from .. import native
    chroma = None
    kc = decimation(fs, CHROMA_FS)
    fsc = FSC[_std_memory.get(int(freq_hz // 1e6), "PAL")]
    color = color and fs >= 2.2 * fsc       # піднесуча має влазити в смугу
    if color:
        r = native.fm_chroma(iq, fs, k, kc, fsc)
        if r is None:
            hz = fm_demod(iq, fs)
            n = (len(hz) // kc) * kc
            lo = np.exp(-1j * 2 * np.pi * fsc / fs * np.arange(len(hz))).astype(np.complex64)
            chroma = (hz[:n] * lo[:n]).reshape(-1, kc).mean(axis=1)
            nl = (len(hz) // k) * k
            v = hz[:nl].reshape(-1, k).mean(axis=1) if k > 1 else hz[:nl]
        else:
            v, chroma = r
    else:
        v = native.fm_baseband(iq, fs, k)          # C: детектор + проріджування в один прохід
        if v is None:                               # немає прискорення — numpy
            hz = fm_demod(iq, fs)
            n = (len(hz) // k) * k
            v = hz[:n].reshape(-1, k).mean(axis=1) if k > 1 else hz[:n]
    fs_out = fs / k
    sub = v[::4]
    p_lo, p_hi, med = np.percentile(sub, [0.5, 99.5, 50])
    span = max(float(p_hi - p_lo), 1.0)
    lo, hi = float(p_lo), float(p_hi)
    levels = 15 if bits == 4 else 255
    x = (v - lo) * (levels / span)
    if bits == 4:
        # Дизеринг: замість «сходинок» яскравості — дрібний шум, який телефон усереднить накопиченням
        x = x + np.random.default_rng().uniform(-0.5, 0.5, len(x)).astype(np.float32)
    q = np.clip(x + 0.5, 0, levels).astype(np.uint8)
    if bits == 4:
        if len(q) % 2:
            q = np.append(q, q[-1])
        payload = ((q[0::2] << 4) | q[1::2]).astype(np.uint8).tobytes()
    else:
        payload = q.tobytes()

    # Легкий аналіз (на проріджених даних — у десятки разів дешевше за повне декодування)
    norm = (v - med) / span
    best = None
    for pol in (1, -1):
        s = _find_sync(norm * pol, fs_out)
        if best is None or s.score > best[1].score:
            best = (pol, s)
    pol, sync = best
    is_video = sync.score >= 0.35 and sync.line_samples > 0
    std = None
    if is_video:
        line_s = sync.line_samples / fs_out
        std = "PAL" if abs(line_s - STD["PAL"]["line_s"]) < abs(line_s - STD["NTSC"]["line_s"]) else "NTSC"
    if std:
        _std_memory[int(freq_hz // 1e6)] = std
    tail = b""
    if chroma is not None and is_video:
        c = np.concatenate([chroma.real, chroma.imag])
        cs = max(float(np.percentile(np.abs(c[::7]), 99.8)) / 120.0, 1.0)
        ci = np.empty(2 * len(chroma), np.int8)
        ci[0::2] = np.clip(np.round(chroma.real / cs), -127, 127)
        ci[1::2] = np.clip(np.round(chroma.imag / cs), -127, 127)
        tail = CHROMA.pack(b"CHRM", float(fs / kc), float(fsc), cs, float((k - kc) / (2 * fs)), len(chroma)) \
            + ci.tobytes()
    flags = (1 if is_video else 0) | (2 if pol < 0 else 0) | (4 if tail else 0)
    head = HEADER.pack(MAGIC, 1, bits, flags, float(freq_hz), float(fs_out), lo, hi, len(q))
    info = {
        "is_video": bool(is_video),
        "standard": std,
        "inverted": bool(pol < 0),
        "sync_score": round(float(sync.score), 3),
        "afc_offset_hz": round((lo + hi) / 2),
        "deviation_hz": round(hi - lo),
        "snr_db": 0.0,
        "decoder": "phone",
        "fs_out": round(fs_out),
        "kbps": round((len(payload) + len(tail)) * 8 * MAX_FPS / 1000),   # найбільший потік, кбіт/с
    }
    info["color"] = bool(tail)
    return head + payload + tail, info


def parse_packet(data: bytes) -> tuple[dict, np.ndarray]:
    """Для тестів і веб-клієнтів: розібрати пакет назад у значення (Гц)."""
    magic, ver, bits, flags, freq, fs, lo, hi, n = HEADER.unpack_from(data)
    assert magic == MAGIC
    raw = np.frombuffer(data, np.uint8, offset=HEADER.size)
    if bits == 4:
        q = np.empty(len(raw) * 2, np.uint8)
        q[0::2], q[1::2] = raw >> 4, raw & 15
        q = q[:n]
        levels = 15
    else:
        q, levels = raw[:n], 255
    hz = lo + q.astype(np.float32) * ((hi - lo) / levels)
    return {"ver": ver, "bits": bits, "flags": flags, "freq_hz": freq, "fs": fs, "n": n}, hz
