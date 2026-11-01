"""Абстракція SDR-приймача."""

from __future__ import annotations

import abc

import numpy as np


class SdrSource(abc.ABC):
    """Мінімальний інтерфейс приймача: налаштування частоти, підсилення, читання IQ."""

    name: str = "sdr"
    min_freq_hz: float = 1e6
    max_freq_hz: float = 6e9
    max_sample_rate: float = 20e6

    def __init__(self) -> None:
        self.center_hz: float = 0.0
        self.sample_rate: float = 0.0
        self.lna_gain: float = 0.0
        self.vga_gain: float = 0.0
        self.amp: bool = False
        self.firmware: str | None = None
        self.hw_info: dict = {}

    @property
    def total_gain_db(self) -> float:
        return self.lna_gain + self.vga_gain + (14.0 if self.amp else 0.0)

    @abc.abstractmethod
    def open(self, rate: float | None = None) -> None: ...

    @abc.abstractmethod
    def close(self) -> None: ...

    @abc.abstractmethod
    def tune(self, freq_hz: float) -> None: ...

    @abc.abstractmethod
    def set_sample_rate(self, rate: float) -> None: ...

    @abc.abstractmethod
    def set_gain(self, lna: float, vga: float, amp: bool) -> None: ...

    @abc.abstractmethod
    def read(self, n: int) -> np.ndarray:
        """Повертає n комплексних відліків complex64, нормованих до ±1."""

    # ---- передавання (тестовий генератор) ------------------------------------
    can_transmit: bool = False

    def start_tx(self, freq_hz: float, sample_rate: float, gain_db: float, amp: bool = False) -> None:
        """Перейти в режим передачі. Приймання при цьому зупиняється (SDR напівдуплексний)."""
        raise NotImplementedError("Цей приймач не вміє передавати")

    def write_tx(self, iq: np.ndarray) -> int:
        """Передати блок відліків complex64 (±1). Повертає скільки передано."""
        raise NotImplementedError

    def stop_tx(self) -> None:
        """Завершити передачу й повернутися до приймання."""

    def info(self) -> dict:
        return {
            "name": self.name,
            "min_freq_hz": self.min_freq_hz,
            "max_freq_hz": self.max_freq_hz,
            "max_sample_rate": self.max_sample_rate,
            "can_transmit": self.can_transmit,
            "firmware": self.firmware,
            "rx_only_firmware": bool(self.firmware and "sdrwatch" in self.firmware),
        }
