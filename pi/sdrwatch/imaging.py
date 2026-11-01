"""Кодування кадрів (JPEG через Pillow, інакше PNG без залежностей) і запис кліпів MJPEG."""

from __future__ import annotations

import io
import os
import struct
import time
import zlib

import numpy as np

try:
    from PIL import Image  # python3-pil
except ImportError:  # pragma: no cover
    Image = None


def encode(img: np.ndarray, quality: int = 75, aspect: float = 4 / 3) -> tuple[bytes, str]:
    """Сірий кадр uint8 H×W → (байти, mime). Висота розтягується до потрібних пропорцій."""
    h, w = img.shape
    target_h = int(round(w / aspect))
    if Image is not None:
        im = Image.fromarray(img, "L")
        if target_h != h:
            im = im.resize((w, target_h), Image.BILINEAR)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=quality)
        return buf.getvalue(), "image/jpeg"
    if target_h != h:
        idx = np.linspace(0, h - 1, target_h).astype(int)
        img = img[idx]
    return _png(img), "image/png"


def _png(img: np.ndarray) -> bytes:
    h, w = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(t: bytes, d: bytes) -> bytes:
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


class ClipWriter:
    """Кліп = файл із послідовно записаних кадрів + індекс (зсув, довжина, час) у meta."""

    def __init__(self, storage, freq_hz: float, label: str, event_id: int | None = None,
                 max_s: float = 8.0) -> None:
        self.storage = storage
        self.max_s = max_s
        self.t0 = time.time()
        self.rel = f"clips/{time.strftime('%Y%m%d', time.localtime(self.t0))}/" \
                   f"{int(self.t0 * 1000)}_{int(freq_hz / 1e3)}.mjpeg"
        full = os.path.join(storage.root, self.rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        self.f = open(full, "wb")
        self.frames: list[list] = []
        self.size = 0
        self.mime = "image/jpeg"
        self.meta = {"freq_hz": freq_hz, "label": label, "frames": self.frames, "mime": self.mime}
        self.file_id = storage.register_file("clip", self.rel, 0, event_id, self.meta)
        self.closed = False

    @property
    def full(self) -> bool:
        return time.time() - self.t0 >= self.max_s

    def add(self, data: bytes, mime: str) -> None:
        if self.closed:
            return
        self.meta["mime"] = mime
        self.f.write(data)
        self.frames.append([self.size, len(data), round(time.time() - self.t0, 3)])
        self.size += len(data)

    def close(self) -> int:
        if not self.closed:
            self.closed = True
            self.f.close()
            self.meta["duration_s"] = round(time.time() - self.t0, 2)
            self.storage.update_file(self.file_id, self.size, self.meta)
        return self.file_id


def read_clip_frame(storage, file_id: int, n: int) -> tuple[bytes, str] | None:
    f = storage.get_file(file_id)
    if not f or f["kind"] != "clip":
        return None
    frames = f["meta"].get("frames", [])
    if not 0 <= n < len(frames):
        return None
    off, ln, _ = frames[n]
    try:
        with open(f["full_path"], "rb") as fh:
            fh.seek(off)
            return fh.read(ln), f["meta"].get("mime", "image/jpeg")
    except OSError:
        return None


def encode_rgb_jpeg(rgb, quality: int = 70, aspect: float = 4 / 3) -> bytes | None:
    """Кольоровий кадр H×W×3 → JPEG (MJPEG-потік на телефон). None — немає Pillow."""
    if Image is None:
        return None
    h, w, _ = rgb.shape
    im = Image.fromarray(rgb, "RGB")
    th = int(round(w / aspect))
    if th != h:
        im = im.resize((w, th), Image.BILINEAR)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality)
    return buf.getvalue()
