"""Керування зовнішнім ВЧ-трактом (фронтендом) під час сканування повного діапазону.

Під кожен піддіапазон модуль сам обирає «шлях»:
  * антену / смуговий фільтр — через ВЧ-комутатор SP4T/SP8T, керований GPIO Raspberry Pi;
  * живлення малошумного підсилювача (LNA) по коаксіалу — bias-tee SDR;
  * конвертер частоти для діапазону понад межу SDR (напр. 6–8 ГГц → 2–4 ГГц).
    Тоді SDR налаштовується на проміжну частоту, а вся обробка й надалі працює в
    справжніх радіочастотах. Для конвертера з гетеродином вище сигналу спектр інвертується.
Якщо фронтенд не налаштовано — працює один шлях «напряму», як зі стоковою антеною.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

log = logging.getLogger(__name__)


@dataclass
class RfPath:
    name: str
    start_hz: float
    stop_hz: float
    gpio: dict[int, int] = field(default_factory=dict)   # {номер GPIO (BCM): 0/1}
    bias_tee: bool = False                               # живити LNA по коаксіалу
    lo_hz: float = 0.0                                   # гетеродин конвертера (0 — без конвертера)
    gain_db: float = 0.0                                 # підсилення зовнішнього LNA (для RSSI)

    def contains(self, f: float) -> bool:
        return self.start_hz <= f <= self.stop_hz

    def if_freq(self, rf_hz: float) -> tuple[float, bool]:
        """(частота налаштування SDR, чи інвертовано спектр)."""
        if not self.lo_hz:
            return rf_hz, False
        if self.lo_hz < rf_hz:
            return rf_hz - self.lo_hz, False      # гетеродин нижче: IF = RF − LO
        return self.lo_hz - rf_hz, True           # гетеродин вище: IF = LO − RF, спектр дзеркальний

    @classmethod
    def from_dict(cls, d: dict) -> "RfPath":
        return cls(name=d.get("name", "path"), start_hz=float(d["start_hz"]), stop_hz=float(d["stop_hz"]),
                   gpio={int(k): int(v) for k, v in (d.get("gpio") or {}).items()},
                   bias_tee=bool(d.get("bias_tee", False)), lo_hz=float(d.get("lo_hz", 0.0)),
                   gain_db=float(d.get("gain_db", 0.0)))


class _Gpio:
    """GPIO через gpiozero (Raspberry Pi OS). Без нього — лише запис у журнал."""

    def __init__(self) -> None:
        self.pins: dict[int, object] = {}
        try:
            from gpiozero import DigitalOutputDevice  # noqa: F401
            self.ok = True
        except Exception:  # noqa: BLE001 — не Raspberry Pi або немає бібліотеки
            self.ok = False

    def set(self, pin: int, value: int) -> None:
        if not self.ok:
            return
        from gpiozero import DigitalOutputDevice
        dev = self.pins.get(pin)
        if dev is None:
            dev = self.pins[pin] = DigitalOutputDevice(pin)
        dev.value = 1 if value else 0


class FrontEnd:
    def __init__(self, paths: list[dict] | None, source) -> None:
        self.paths = [RfPath.from_dict(p) for p in (paths or [])]
        self.src = source
        self.gpio = _Gpio() if self.paths else None
        self.current: RfPath | None = None
        self.inverted = False

    @property
    def enabled(self) -> bool:
        return bool(self.paths)

    def max_freq_hz(self, default: float) -> float:
        conv = [p.stop_hz for p in self.paths if p.lo_hz]
        return max([default, *conv])

    def path_for(self, rf_hz: float) -> RfPath | None:
        for p in self.paths:
            if p.contains(rf_hz):
                return p
        return None

    def tune(self, rf_hz: float) -> None:
        """Обрати шлях і налаштувати SDR так, щоб на вході була частота rf_hz."""
        p = self.path_for(rf_hz)
        if p is not self.current:
            self._activate(p)
        if p is None:
            self.inverted = False
            self.src.tune(rf_hz)
            return
        f_if, self.inverted = p.if_freq(rf_hz)
        self.src.tune(f_if)

    def _activate(self, p: RfPath | None) -> None:
        self.current = p
        if p is None:
            return
        for pin, v in p.gpio.items():
            self.gpio.set(pin, v)
        set_bias = getattr(self.src, "set_bias_tee", None)
        if set_bias:
            set_bias(p.bias_tee)
        log.debug("ВЧ-шлях: %s", p.name)

    @property
    def external_gain_db(self) -> float:
        return self.current.gain_db if self.current else 0.0

    def info(self) -> list[dict]:
        return [{"name": p.name, "start_hz": p.start_hz, "stop_hz": p.stop_hz, "converter": bool(p.lo_hz),
                 "bias_tee": p.bias_tee, "active": p is self.current} for p in self.paths]
