"""Розсилка живих даних (спектр, відео, події) з потоку сканера у WebSocket-клієнти."""

from __future__ import annotations

import asyncio
import threading
from typing import Any


class Subscriber:
    def __init__(self, loop: asyncio.AbstractEventLoop, maxsize: int, channel: str) -> None:
        self.loop = loop
        self.q: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
        self.channel = channel
        self.options: dict[str, Any] = {}

    def _put(self, item: Any) -> None:
        if self.q.full():  # повільний клієнт (мобільний інтернет) — викидаємо найстаріше
            try:
                self.q.get_nowait()
            except asyncio.QueueEmpty:
                pass
        self.q.put_nowait(item)


class Hub:
    def __init__(self) -> None:
        self._subs: list[Subscriber] = []
        self._lock = threading.Lock()

    def subscribe(self, channel: str, maxsize: int = 16) -> Subscriber:
        s = Subscriber(asyncio.get_running_loop(), maxsize, channel)
        with self._lock:
            self._subs.append(s)
        return s

    def unsubscribe(self, s: Subscriber) -> None:
        with self._lock:
            if s in self._subs:
                self._subs.remove(s)

    def viewed_ranges(self) -> set:
        """Діапазони, які зараз дивляться в застосунку (вибрані на вкладці «Ефір»)."""
        with self._lock:
            return {s.options.get("range") for s in self._subs
                    if s.channel == "live" and s.options.get("range") is not None}

    def count(self, channel: str) -> int:
        with self._lock:
            return sum(1 for s in self._subs if s.channel == channel)

    def option(self, channel: str, key: str, default: Any = None) -> Any:
        """Параметр, який передав клієнт каналу (перший, у кого він заданий)."""
        with self._lock:
            for s in self._subs:
                if s.channel == channel and s.options.get(key) is not None:
                    return s.options[key]
        return default

    def publish(self, channel: str, item: Any, filt=None) -> None:
        """Викликається з будь-якого потоку."""
        with self._lock:
            subs = [s for s in self._subs if s.channel == channel]
        for s in subs:
            if filt is not None and not filt(s):
                continue
            try:
                s.loop.call_soon_threadsafe(s._put, item)
            except RuntimeError:  # цикл закрито
                self.unsubscribe(s)
