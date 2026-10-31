"""Конфігурація модуля. Зберігається у JSON, змінюється через API з телефону."""

from __future__ import annotations

import json
import os
import secrets
import threading
from dataclasses import asdict, dataclass, field, fields, is_dataclass
from typing import Any

DEFAULT_CONFIG_PATH = os.environ.get("SDRWATCH_CONFIG", "/etc/sdrwatch/config.json")


@dataclass
class ScanRange:
    name: str
    start_hz: float
    stop_hz: float
    enabled: bool = True


@dataclass
class SdrConfig:
    # "soapy" (HackRF, RTL-SDR, Airspy, LimeSDR, Pluto через SoapySDR) або "sim"
    driver: str = "soapy"
    device_args: str = "driver=hackrf"
    sample_rate: float = 20e6
    # Корисна смуга (решта — спад фільтра АЦП, відкидається)
    usable_fraction: float = 0.8
    lna_gain: float = 32.0
    vga_gain: float = 30.0
    amp: bool = False
    auto_gain: bool = True
    ppm: float = 0.0
    # Зовнішній ВЧ-тракт: список шляхів {name, start_hz, stop_hz, gpio:{pin:0/1}, bias_tee, lo_hz, gain_db}
    # (див. frontend.py і docs/HARDWARE.md). Порожньо — антена напряму в SDR.
    frontend: list = field(default_factory=list)


@dataclass
class FullBandConfig:
    """Виявлення на всій ширині діапазону SDR (поза пріоритетними FPV-діапазонами)."""
    enabled: bool = True
    start_hz: float = 1e6
    # 0 — до верхньої межі SDR (або конвертера, якщо він є у frontend)
    stop_hz: float = 0.0
    # Скільки сегментів «повного» діапазону сканувати між проходами пріоритетних діапазонів:
    # FPV-діапазони оновлюються часто, решта ефіру — поступово
    segments_per_cycle: int = 40


@dataclass
class DspConfig:
    fft_size: int = 1024
    averages: int = 8
    # Поріг виявлення над рівнем шуму, дБ
    threshold_db: float = 8.0
    # Мінімальна ширина сигналу, Гц (відкидає поодинокі шумові біни)
    min_bandwidth_hz: float = 60e3
    # Скільки проходів поспіль сигнал має бути видно, щоб бути підтвердженим
    confirm_hits: int = 3
    # Через скільки секунд без сигналу вважати його втраченим
    lost_timeout_s: float = 6.0
    # Чутливість відео-аналізу (тривалість запису IQ на один аналіз, с)
    video_capture_s: float = 0.045
    # Ехо-фільтр: вивчити сталі шуми/завади при старті й не реагувати на них
    echo_filter: bool = False


@dataclass
class DistanceConfig:
    # Показник загасання: 2.0 — відкритий простір, 2.7 — передмістя, 3.3 — місто
    path_loss_exponent: float = 2.2
    rx_antenna_gain_dbi: float = 2.0
    # Калібрування RSSI: dBm = dBFS - підсилення + rx_cal_db
    rx_cal_db: float = 35.0


@dataclass
class StorageConfig:
    path: str = "/var/lib/sdrwatch"
    # Скільки місця на флешці виділити під кільцевий запис (як у відеореєстраторі)
    quota_mb: int = 2048
    record_video: bool = True
    video_clip_s: float = 8.0
    save_waterfall: bool = True


@dataclass
class NotifyConfig:
    enabled: bool = True
    # Мінімальний пріоритет для сповіщення: 0 — усе, 1 — середній, 2 — лише відео/керування
    min_priority: int = 1
    ntfy_url: str = ""          # напр. https://ntfy.sh/my-secret-topic
    telegram_token: str = ""
    telegram_chat_id: str = ""
    webhook_url: str = ""
    # Не повторювати сповіщення про ту саму частоту частіше ніж раз на N секунд
    cooldown_s: float = 120.0


@dataclass
class ApiConfig:
    host: str = "0.0.0.0"
    port: int = 8080
    token: str = ""
    # Скільки секунд після ввімкнення модуль сам видає токен застосунку в локальній мережі
    # (сполучення без монітора й SSH). 0 — вимкнено, лише QR з `sdrwatch pair`.
    pairing_window_s: int = 900


@dataclass
class UpdateConfig:
    # Репозиторій GitHub, звідки модуль сам бере оновлення (релізи pi-N і hackrf-N)
    repo: str = "Breddog/tppz"


@dataclass
class TxConfig:
    # Тестовий передавач. Дозвіл має увімкнути власник (правова відповідальність за ефір).
    allow: bool = True
    # Передавач сам вимикається через стільки секунд (захист від «забув вимкнути»)
    max_seconds: float = 300.0
    # Підсилення передачі за замовчуванням (HackRF VGA 0..47 дБ). Починайте з малого!
    default_gain_db: float = 20.0
    default_standard: str = "PAL"
    sample_rate: float = 16e6


@dataclass
class Config:
    name: str = "SDR-модуль"
    latitude: float | None = None
    longitude: float | None = None
    sdr: SdrConfig = field(default_factory=SdrConfig)
    dsp: DspConfig = field(default_factory=DspConfig)
    full_band: FullBandConfig = field(default_factory=FullBandConfig)
    distance: DistanceConfig = field(default_factory=DistanceConfig)
    storage: StorageConfig = field(default_factory=StorageConfig)
    notify: NotifyConfig = field(default_factory=NotifyConfig)
    api: ApiConfig = field(default_factory=ApiConfig)
    updates: UpdateConfig = field(default_factory=UpdateConfig)
    tx: TxConfig = field(default_factory=TxConfig)
    ranges: list[ScanRange] = field(default_factory=lambda: [
        ScanRange("5.8 ГГц FPV відео", 5_645e6, 5_945e6),
        ScanRange("2.4 ГГц керування / DJI / Wi-Fi", 2_400e6, 2_484e6),
        ScanRange("1.2–1.3 ГГц FPV відео", 1_080e6, 1_360e6),
        ScanRange("868/915 МГц ELRS / Crossfire", 860e6, 930e6),
        ScanRange("3.3 ГГц відео", 3_300e6, 3_500e6, enabled=False),
        ScanRange("5.1–5.3 ГГц DJI / відео", 5_150e6, 5_350e6, enabled=False),
        ScanRange("433 МГц телеметрія / LRS", 425e6, 445e6, enabled=False),
    ])

    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False, compare=False)
    _path: str = field(default=DEFAULT_CONFIG_PATH, repr=False, compare=False)

    # ---- serialisation -------------------------------------------------
    def to_dict(self, include_secrets: bool = False) -> dict[str, Any]:
        d = {f.name: _dump(getattr(self, f.name)) for f in fields(self) if not f.name.startswith("_")}
        if not include_secrets:
            d["api"] = {**d["api"], "token": "***"}
            d["notify"] = {**d["notify"], "telegram_token": "***" if self.notify.telegram_token else ""}
        return d

    def update(self, patch: dict[str, Any]) -> None:
        """Частково оновити конфіг (з телефону). Невідомі ключі ігноруються."""
        with self._lock:
            _apply(self, patch)

    def save(self, path: str | None = None) -> None:
        path = path or self._path
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(include_secrets=True), f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    @classmethod
    def load(cls, path: str | None = None) -> "Config":
        path = path or DEFAULT_CONFIG_PATH
        cfg = cls()
        cfg._path = path
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                _apply(cfg, json.load(f))
        if not cfg.api.token:
            cfg.api.token = secrets.token_urlsafe(24)
            try:
                cfg.save(path)
            except OSError:
                pass
        return cfg


def _dump(v: Any) -> Any:
    if is_dataclass(v):
        return {f.name: _dump(getattr(v, f.name)) for f in fields(v) if not f.name.startswith("_")}
    if isinstance(v, list):
        return [_dump(x) for x in v]
    return v


def _apply(obj: Any, patch: dict[str, Any]) -> None:
    for f in fields(obj):
        if f.name.startswith("_") or f.name not in patch:
            continue
        cur = getattr(obj, f.name)
        val = patch[f.name]
        if f.name == "ranges" and isinstance(val, list):
            setattr(obj, "ranges", [ScanRange(**{k: r[k] for k in ("name", "start_hz", "stop_hz", "enabled") if k in r})
                                    for r in val])
        elif is_dataclass(cur) and isinstance(val, dict):
            _apply(cur, val)
        elif f.name == "token" and val == "***":
            continue
        elif f.name == "telegram_token" and val == "***":
            continue
        else:
            if isinstance(cur, bool):
                val = bool(val)
            elif isinstance(cur, int) and not isinstance(cur, bool) and val is not None:
                val = int(val)
            elif isinstance(cur, float) and val is not None:
                val = float(val)
            setattr(obj, f.name, val)
