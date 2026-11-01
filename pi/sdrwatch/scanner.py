"""Головний цикл модуля: сканування діапазонів, аналіз, відстеження, відео, запис.

Режими:
  scan   — циклічне сканування увімкнених діапазонів, виявлення та класифікація;
  watch  — стеження за однією частотою: живе відео, AFC, запис кліпів,
           при втраті — автоматичний пошук по сітці каналів;
  paused — приймач зупинено.
"""

from __future__ import annotations

import concurrent.futures
import logging
import math
import queue
import threading
import time
from dataclasses import dataclass, field

import numpy as np

from . import channels as ch
from . import distance as dist
from .dsp import baseband, classifier, spectrum, video
from .frontend import FrontEnd
from .hub import Hub
from .imaging import ClipWriter, encode
from .notifier import Notifier
from .storage import Storage
from .tracker import Track, Tracker

log = logging.getLogger(__name__)

SPECTRUM_POINTS = 1024
FULL_SPECTRUM_POINTS = 2048
FULL_BAND_INDEX = 100       # індекс панорами «Повний діапазон» (поза списком cfg.ranges)
MAX_ANALYSES_PER_SWEEP = 1   # аналіз IQ найдорожчий — не більше одного за прохід діапазону


@dataclass
class Panorama:
    index: int
    name: str
    start_hz: float
    stop_hz: float
    bin_hz: float
    centers: list[float]
    usable_bins: int
    spec: np.ndarray
    peak_hold: np.ndarray
    floor: spectrum.NoiseFloorTracker
    wf_rows: list = field(default_factory=list)
    wf_last_save: float = field(default_factory=time.time)
    sweeps: int = 0
    full: bool = False          # «повний діапазон» — сканується порціями між пріоритетними
    cursor: int = 0
    pass_started: float = field(default_factory=time.time)
    pass_s: float = 0.0         # тривалість останнього повного проходу
    static_db: np.ndarray | None = None   # ехо-фільтр: рівень сталих шумів/завад (за бінами)
    learn_left: int = 0                   # скільки ще проходів «вивчати» сталий фон

    def freqs(self, sl: slice) -> np.ndarray:
        return self.start_hz + (np.arange(sl.start, sl.stop) + 0.5) * self.bin_hz

    def segment_slice(self, center: float) -> tuple[slice, slice]:
        """(зріз панорами, зріз спектра сегмента) для сегмента з центром center."""
        first = center - self.usable_bins / 2 * self.bin_hz
        i0 = int(round((first - self.start_hz) / self.bin_hz))
        a, b = max(0, i0), min(len(self.spec), i0 + self.usable_bins)
        return slice(a, b), slice(a - i0, b - i0)


@dataclass
class Hunt:
    """Пріоритетний пошук втраченого сигналу по сітці каналів."""
    track_id: str
    freqs: list[float]
    until: float
    pos: int = 0


class Engine:
    def __init__(self, cfg, source, storage: Storage, notifier: Notifier | None, hub: Hub) -> None:
        self.cfg = cfg
        self.src = source
        self._inverted = False
        self.storage = storage
        self.notifier = notifier
        self.hub = hub
        self.tracker = Tracker(cfg.dsp.confirm_hits, cfg.dsp.lost_timeout_s)
        self.tracker.listeners.append(self._on_track_event)
        self._pending: list[tuple[str, Track]] = []
        self.panoramas: list[Panorama] = []
        self.mode = "scan"
        self.watch_freq: float | None = None
        self.watch_track: str | None = None
        self.video_opts = {"invert": None, "auto_contrast": True, "descramble": True, "afc": True}
        self.recording = False
        self.clip: ClipWriter | None = None
        self.hunts: list[Hunt] = []
        self.watch_status: dict = {}
        self.tx: dict | None = None            # активна передача: параметри + буфер
        self._tx_active = False
        self._opened = False                   # чи відкрито приймач (HackRF може бути відсутній)
        self.audio: dict | None = None         # режим звуку: частота, модуляція, шумодав, автоскан
        self._audio_active = False
        self._next_open = 0.0
        self.stats = {"sweep_s": 0.0, "sweeps": 0, "started": time.time(), "errors": 0, "last_error": ""}
        self._stop = threading.Event()
        self._reconf = threading.Event()
        self._lock = threading.RLock()
        self._thread: threading.Thread | None = None
        self.gain = [cfg.sdr.lna_gain, cfg.sdr.vga_gain, cfg.sdr.amp]
        self.fe = FrontEnd(cfg.sdr.frontend, source)
        self.last_spectrum: dict[int, dict] = {}
        self._need_plan = False
        self._calls: queue.Queue = queue.Queue()

    def call(self, fn, timeout: float = 15.0):
        """Виконати fn у потоці приймача (SDR не можна чіпати з кількох потоків одночасно)."""
        fut: concurrent.futures.Future = concurrent.futures.Future()
        self._calls.put((fn, fut))
        self._reconf.set()
        return fut.result(timeout=timeout)

    def _run_calls(self) -> None:
        while True:
            try:
                fn, fut = self._calls.get_nowait()
            except queue.Empty:
                return
            try:
                fut.set_result(fn())
            except Exception as e:  # noqa: BLE001
                fut.set_exception(e)

    # ---- керування -------------------------------------------------------------
    def start(self) -> None:
        # SDR відкриваємо «м'яко»: якщо приймача ще немає (не підключений HackRF),
        # сервіс усе одно стартує, а підключення повторюється у фоні. Так веб-сервер
        # і застосунок працюють навіть без приймача (показують «SDR не підключено»).
        self._opened = self._try_open()
        self._thread = threading.Thread(target=self._run, daemon=True, name="engine")
        self._thread.start()

    def _try_open(self) -> bool:
        try:
            self.src.open()
            self.src.set_sample_rate(self.cfg.sdr.sample_rate)
            self._apply_gain()
            self._build_plan()
            self.stats["last_error"] = ""
            return True
        except Exception as e:  # noqa: BLE001 — приймача може не бути або він зайнятий
            self.stats["last_error"] = f"SDR недоступний: {e}"
            log.warning("SDR не відкрито (%s) — працюю без приймача, повторю згодом", e)
            try:
                self.src.close()
            except Exception:  # noqa: BLE001
                pass
            return False

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
        self._tx_end()
        self._audio_end()
        self._close_clip()
        self.src.close()

    def set_mode(self, mode: str, freq_hz: float | None = None, track_id: str | None = None) -> None:
        with self._lock:
            if mode == "watch":
                if track_id and track_id in self.tracker.tracks:
                    t = self.tracker.tracks[track_id]
                    freq_hz = t.freq_hz
                if freq_hz is None:
                    raise ValueError("Потрібна частота або id сигналу")
                self.watch_freq = float(freq_hz)
                self.watch_track = track_id
                # Ручне стеження (повзунок/ввід частоти) — без автопошуку по сітці, стоїмо де сказали
                self.watch_status = {"lost_since": None, "manual": track_id is None}
            else:
                self._close_clip()
                self.recording = False
            if mode != "transmit":
                self.tx = None       # перехід у будь-який інший режим зупиняє передачу
            if mode != "audio":
                self.audio = None
            self.mode = mode
        self._reconf.set()

    # ---- звук з ефіру -----------------------------------------------------------------------
    def start_audio(self, freq_hz: float | None, mod: str = "nfm", squelch_db: float = 10.0,
                    scan: dict | None = None) -> dict:
        """Слухати частоту (або автоскан діапазону зі зупинкою на сигналі)."""
        from .dsp import audio as au
        if mod not in au.MODES:
            raise ValueError("Невідома модуляція")
        if scan:
            start, stop = float(scan["start_hz"]), float(scan["stop_hz"])
            step = float(scan.get("step_hz") or 12.5e3)
            if stop <= start or step <= 0:
                raise ValueError("Невірний діапазон автоскану")
            scan = {"start_hz": start, "stop_hz": stop, "step_hz": step, "hold_s": float(scan.get("hold_s", 2.0))}
            freq_hz = freq_hz or start
        if freq_hz is None:
            raise ValueError("Потрібна частота")
        with self._lock:
            self._close_clip()
            self.tx = None
            self.audio = {"freq_hz": float(freq_hz), "mod": mod, "squelch_db": float(squelch_db),
                          "scan": scan, "center": float(freq_hz) + au.TUNE_OFFSET,
                          "demod": au.AudioDemod(mod), "open": False, "level_db": None,
                          "locked": scan is None, "last_open": 0.0, "tuned": None}
            self.mode = "audio"
        self._reconf.set()
        return self.audio_status()

    def set_audio_params(self, squelch_db: float | None = None, mod: str | None = None) -> dict:
        a = self.audio
        if a:
            if squelch_db is not None:
                a["squelch_db"] = float(squelch_db)
            if mod and mod != a["mod"]:
                a["mod"] = mod
                a["demod"].set_mode(mod)
        return self.audio_status()

    def stop_audio(self) -> dict:
        with self._lock:
            self.audio = None
            if self.mode == "audio":
                self.mode = "scan"
        self._reconf.set()
        return self.audio_status()

    def audio_status(self) -> dict:
        a = self.audio
        if not a or self.mode != "audio":
            return {"active": False}
        return {"active": True, "freq_hz": round(a["freq_hz"]), "mod": a["mod"], "squelch_db": a["squelch_db"],
                "open": a["open"], "level_db": a["level_db"], "scanning": bool(a["scan"]) and not a["locked"],
                "scan": a["scan"]}

    def _audio_step(self) -> None:
        from .dsp import audio as au
        a = self.audio
        if not a:
            self.mode = "scan"
            return
        if not self._audio_active:
            self.src.set_sample_rate(au.SDR_RATE)
            self._audio_active = True
            a["tuned"] = None
        now = time.time()
        sc = a["scan"]
        if sc and not a["locked"]:
            # Автоскан: одне вікно ±1 МГц за запис, шукаємо канали сітки вище шумодава
            if a["tuned"] != a["center"]:
                self._tune(a["center"])
                a["tuned"] = a["center"]
            iq = self._read(int(au.SDR_RATE * 0.015))
            peaks = au.window_peaks(iq, a["center"], sc["step_hz"], sc["start_hz"], sc["stop_hz"],
                                    a["squelch_db"])
            if peaks:
                a["freq_hz"], a["level_db"] = peaks[0][0], round(peaks[0][1], 1)
                a["locked"], a["last_open"] = True, now
                a["demod"] = au.AudioDemod(a["mod"])
            else:
                nxt = a["center"] + 2.0e6
                if nxt - 1.0e6 > sc["stop_hz"]:
                    nxt = sc["start_hz"] + 1.0e6
                a["center"] = nxt
                a["freq_hz"] = max(sc["start_hz"], nxt - 1.0e6)
            self.hub.publish("live", {"type": "audio", **self.audio_status(), "ts": now})
            return
        # Слухаємо: блок 100 мс → звук
        if a["tuned"] != a["center"] or abs(a["freq_hz"] - a["center"]) > 1.05e6:
            if abs(a["freq_hz"] - a["center"]) > 1.05e6:
                a["center"] = a["freq_hz"] + au.TUNE_OFFSET
            self._tune(a["center"])
            a["tuned"] = a["center"]
        # Блоки по 50 мс — менша затримка звуку
        iq = self._read(int(au.SDR_RATE * 0.05))
        lvl = au.window_peaks(iq[:32768], a["center"], 1.0, a["freq_hz"], a["freq_hz"], -999.0)
        a["level_db"] = round(lvl[0][1], 1) if lvl else None
        a["open"] = a["level_db"] is not None and a["level_db"] >= a["squelch_db"]
        if self.hub.count("audioiq") > 0:
            # Телефон демодулює сам: віддаємо лише вирізаний канал (48 / 240 кГц)
            x, rate, _ = a["demod"].channel(iq, a["freq_hz"] - a["center"])
            self.hub.publish("audioiq", au.iq_packet(x, rate, a["freq_hz"], a["mod"], a["level_db"],
                                                     a["squelch_db"], a["open"]))
        if a["open"]:
            a["last_open"] = now
            if self.hub.count("audio") > 0:      # старі застосунки / веб — готовий звук з модуля
                pcm, _ = a["demod"].process(iq, a["freq_hz"] - a["center"])
                self.hub.publish("audio", pcm.tobytes())
        elif sc and now - a["last_open"] > sc["hold_s"]:
            a["locked"] = False            # сигнал зник — продовжуємо автоскан з наступного вікна
            a["center"] += 2.0e6
        # Живий спектр навколо частоти (2.4 МГц) — раз на 4 блоки
        a["n"] = a.get("n", 0) + 1
        if a["n"] % 4:
            self.hub.publish("live", {"type": "audio", **self.audio_status(), "ts": now})
            return
        d = self.cfg.dsp
        spec = spectrum.remove_dc(spectrum.psd_db(iq[: d.fft_size * (d.averages + 1)], d.fft_size, d.averages))
        spec = spec + self.gain_offset_db
        freqs = a["center"] + (np.arange(len(spec)) - len(spec) / 2 + 0.5) * au.SDR_RATE / len(spec)
        self.hub.publish("live", self._spectrum_msg(-2, "Звук", freqs[0], freqs[-1], spec, spectrum.local_floor(spec)))
        self.hub.publish("live", {"type": "audio", **self.audio_status(), "ts": now})

    def _audio_end(self) -> None:
        if self._audio_active:
            self._audio_active = False
            self.src.set_sample_rate(self.cfg.sdr.sample_rate)

    def set_video_autoscan(self, on: bool, bands: list[str] | None = None, circular: bool = True,
                           dwell_s: float = 3.0, mode: str = "grids", start_hz: float | None = None,
                           stop_hz: float | None = None, audio: bool = True) -> dict:
        """Круговий автоскан відео (+ пошук голосу).

        mode: «grids» — канали вибраних сіток; «full» — весь діапазон SDR; «range» — від start до stop.
        Іде по порядку, коло за колом. Знайдене відео показує dwell_s секунд (circular) або стоїть на ньому.
        Повний діапазон і «від–до» — двоступенево: швидкий спектр вікнами по ~16 МГц, перевірка
        синхроімпульсів лише там, де є широкий сигнал. Вузькі сигнали (<1.3 ГГц) — кандидати голосу.
        """
        if not on:
            if self.watch_status:
                self.watch_status.pop("autoscan", None)
            return {"autoscan": False}
        info = self.src.info() if self._opened else {}
        lo_dev = float(info.get("min_freq_hz") or 1e6)
        hi_dev = float(info.get("max_freq_hz") or 6e9)
        fs = self.src.sample_rate or self.cfg.sdr.sample_rate
        step = fs * self.cfg.sdr.usable_fraction
        freqs: list[float] = []
        if mode == "grids":
            for code in bands or ["R", "F", "A", "B", "E"]:
                b = ch.BAND_BY_CODE.get(code)
                if not b:
                    continue
                for c in b.channels():
                    if all(abs(c.freq_hz - f) > 2e6 for f in freqs):
                        freqs.append(c.freq_hz)
            freqs.sort()
        else:
            lo = max(lo_dev, float(start_hz) if (mode == "range" and start_hz) else lo_dev)
            hi = min(hi_dev, float(stop_hz) if (mode == "range" and stop_hz) else hi_dev)
            if hi - lo < 1e6:
                raise ValueError("Діапазон «від–до» замалий")
            f = lo + step / 2
            while f - step / 2 < hi:
                freqs.append(min(f, hi_dev - fs / 2))
                f += step
        if not freqs:
            raise ValueError("Немає каналів для автоскану")
        if self.mode != "watch":
            self.set_mode("watch", freqs[0])
        old = (self.watch_status or {}).get("autoscan") or {}
        self.watch_status["autoscan"] = {
            "mode": mode, "freqs": freqs, "idx": 0, "found": old.get("found", {}), "last_video": 0.0,
            "circular": bool(circular), "dwell_s": float(dwell_s), "arrived": time.time(), "rounds": 0,
            "audio": bool(audio), "start_hz": freqs[0], "stop_hz": freqs[-1], "dwell_until": 0.0,
            "verify": [], "round_started": time.time(), "round_s": None, "pos_hz": freqs[0],
        }
        self.watch_freq = freqs[0]
        return {"autoscan": True, "channels": len(freqs), "mode": mode}

    def _found_add(self, auto: dict, kind: str, f: float, level: float, extra: dict | None = None) -> dict:
        m0 = ch.match_channel(f, kind="analog") if kind == "video" else None
        if kind == "video":
            key = m0.channel.name if m0 else f"V{f / 1e6:.0f}"
        else:
            key = f"A{round(f / 12.5e3) * 12.5e3 / 1e6:.4f}"
        e = auto["found"].get(key)
        now = time.time()
        if e is None:
            e = auto["found"][key] = {"key": key, "type": kind, "freq_mhz": round(f / 1e6, 4 if kind == "audio" else 1),
                                      "channel": m0.channel.name if m0 else None, "first_seen": now, "hits": 0}
        e.update({"last_seen": now, "level_db": round(level, 1), **(extra or {})})
        e["hits"] += 1
        if len(auto["found"]) > 200:   # найстаріші — геть
            for k in sorted(auto["found"], key=lambda k: auto["found"][k]["last_seen"])[:20]:
                auto["found"].pop(k, None)
        return e

    def _search_step(self, auto: dict) -> None:
        """Одне вікно швидкого пошуку (режими «full» / «range»)."""
        d = self.cfg.dsp
        fs = self.src.sample_rate
        if auto["verify"]:
            # Перевірка кандидата: чи є рядкова синхронізація (тобто аналогове відео)
            f, bw, lvl = auto["verify"].pop(0)
            self._tune(f)
            iq = self._read(int(fs * baseband.FIELD_S))
            pkt, info = baseband.make_packet(iq, fs, f, self.hub.option("baseband", "quality", "normal"))
            if info["is_video"]:
                self.hub.publish("baseband", pkt)
                self._found_add(auto, "video", f + info["afc_offset_hz"], lvl, {"standard": info["standard"]})
                self.watch_freq = f + info["afc_offset_hz"]
                auto["dwell_until"] = time.time() + auto["dwell_s"]
                auto["last_video"] = time.time()
            return
        i = auto["idx"]
        c = auto["freqs"][i]
        auto["pos_hz"] = c
        s, _ = self._capture_spectrum(c)
        n = len(s)
        crop = (n - int(n * self.cfg.sdr.usable_fraction)) // 2
        s = s[crop:n - crop]
        freqs = c + (np.arange(len(s)) - len(s) / 2 + 0.5) * fs / n
        floor = spectrum.local_floor(s)
        if i % 4 == 0:
            self.hub.publish("live", self._spectrum_msg(-1, "Пошук", freqs[0], freqs[-1], s, floor))
        for det in spectrum.detect(s, floor, freqs, d.threshold_db, 60e3):
            if det.bandwidth_hz >= 2.5e6:
                auto["verify"].append((det.freq_hz, det.bandwidth_hz, det.snr_db))
        if auto["audio"] and c < 1.35e9:
            # Вузькі сигнали (рації, голос): піки шириною 1–3 біни, помітно вище шуму
            bin_hz = fs / n
            exc = s - floor
            for k in np.flatnonzero((exc > d.threshold_db + 4) & (exc >= np.roll(exc, 1)) & (exc >= np.roll(exc, -1))):
                if 2 <= k < len(s) - 2 and np.sum(exc[k - 2:k + 3] > d.threshold_db) <= 3:
                    f = float(freqs[k])
                    if abs(f - c) > 3 * bin_hz:                 # не DC-пік HackRF
                        self._found_add(auto, "audio", f, float(exc[k]))
        auto["idx"] = (i + 1) % len(auto["freqs"])
        if auto["idx"] == 0:
            now = time.time()
            auto["rounds"] += 1
            auto["round_s"] = round(now - auto["round_started"], 2)
            auto["round_started"] = now

    def start_transmit(self, mode: str, freq_hz: float, gain_db: float | None = None,
                       standard: str | None = None, image: np.ndarray | None = None,
                       seconds: float | None = None) -> dict:
        """Увімкнути тестовий передавач. Приймання зупиняється на час передачі."""
        from . import transmitter as txmod
        if not self.cfg.tx.allow:
            raise ValueError("Передавання вимкнено в налаштуваннях модуля")
        if not getattr(self.src, "can_transmit", False):
            raise ValueError("Цей приймач не вміє передавати (потрібен HackRF)")
        if mode not in txmod.MODES:
            raise ValueError("Невідомий режим передачі")
        fs = self.cfg.tx.sample_rate
        gain = self.cfg.tx.default_gain_db if gain_db is None else float(gain_db)
        std = standard or self.cfg.tx.default_standard
        wf = txmod.build_waveform(mode, fs, image=image, standard=std, amplitude=0.9)
        limit = self.cfg.tx.max_seconds
        secs = limit if seconds is None else min(float(seconds), limit)
        with self._lock:
            self._close_clip()
            self.recording = False
            self.tx = {"mode": mode, "freq_hz": float(freq_hz), "gain_db": gain, "standard": std,
                       "sample_rate": fs, "buffer": wf, "until": time.time() + secs, "seconds": secs,
                       "started": time.time(), "has_image": image is not None}
            self.mode = "transmit"
        self._reconf.set()
        return self.tx_status()

    def stop_transmit(self) -> dict:
        with self._lock:
            self.tx = None
            if self.mode == "transmit":
                self.mode = "scan"
        self._reconf.set()
        return self.tx_status()

    def tx_status(self) -> dict:
        t = self.tx
        if not t:
            return {"active": False, "can_transmit": bool(getattr(self.src, "can_transmit", False)),
                    "allowed": self.cfg.tx.allow, "max_seconds": self.cfg.tx.max_seconds}
        import math as _m
        return {"active": self.mode == "transmit", "mode": t["mode"], "freq_hz": round(t["freq_hz"]),
                "gain_db": t["gain_db"], "standard": t["standard"], "seconds": t["seconds"],
                "remaining_s": max(0, _m.ceil(t["until"] - time.time())), "has_image": t["has_image"],
                "can_transmit": True, "allowed": self.cfg.tx.allow, "max_seconds": self.cfg.tx.max_seconds}

    def _transmit_step(self) -> None:
        t = self.tx
        if not t:
            self.mode = "scan"
            return
        if not self._tx_active:
            self.src.start_tx(t["freq_hz"], t["sample_rate"], t["gain_db"], amp=False)
            self._tx_active = True
            self.hub.publish("live", {"type": "tx", **self.tx_status(), "ts": time.time()})
        buf = t["buffer"]
        # Передаємо буфер циклічно блоками; після кожного перевіряємо авто-стоп і запити
        block = 65536
        for i in range(0, len(buf), block):
            if self._interrupted() or time.time() >= t["until"]:
                break
            self.src.write_tx(buf[i:i + block])
        if time.time() >= t["until"]:
            log.info("TX авто-стоп (%.0f с)", t["seconds"])
            self._tx_end()
            with self._lock:
                self.tx = None
                self.mode = "scan"
            self.hub.publish("live", {"type": "tx", "active": False, "reason": "timeout", "ts": time.time()})

    def _tx_end(self) -> None:
        if self._tx_active:
            try:
                self.src.stop_tx()
            finally:
                self._tx_active = False

    def set_echo_filter(self, on: bool, relearn: bool = False, learn_sweeps: int = 2) -> dict:
        """Ехо-фільтр сталих шумів. relearn — перевчити базову лінію з поточного ефіру."""
        self.cfg.dsp.echo_filter = bool(on)
        for p in self.panoramas:
            if not on:
                p.static_db = None
                p.learn_left = 0
            elif relearn or p.static_db is None:
                p.static_db = np.full(len(p.spec), np.nan, np.float32)
                p.learn_left = max(1, learn_sweeps)
        self._reconf.set()
        return self.echo_status()

    def echo_status(self) -> dict:
        learning = any(p.learn_left > 0 for p in self.panoramas)
        return {"enabled": self.cfg.dsp.echo_filter, "learning": learning,
                "learn_left": max((p.learn_left for p in self.panoramas), default=0)}

    def set_recording(self, on: bool) -> None:
        with self._lock:
            self.recording = on
            if not on:
                self._close_clip()

    def set_gain(self, lna: float | None = None, vga: float | None = None, amp: bool | None = None,
                 auto: bool | None = None) -> None:
        s = self.cfg.sdr
        if lna is not None:
            s.lna_gain = float(lna)
        if vga is not None:
            s.vga_gain = float(vga)
        if amp is not None:
            s.amp = bool(amp)
        if auto is not None:
            s.auto_gain = bool(auto)
        self.gain = [s.lna_gain, s.vga_gain, s.amp]
        self._reconf.set()

    def reconfigure(self) -> None:
        """Після зміни діапазонів / параметрів у конфігу."""
        self.tracker.confirm_hits = self.cfg.dsp.confirm_hits
        self.tracker.lost_timeout_s = self.cfg.dsp.lost_timeout_s
        self.storage.set_quota(self.cfg.storage.quota_mb)
        self._reconf.set()
        self._need_plan = True

    # ---- план сканування -----------------------------------------------------------
    def _build_plan(self) -> None:
        fs = self.src.sample_rate
        n = self.cfg.dsp.fft_size
        bin_hz = fs / n
        usable = int(n * self.cfg.sdr.usable_fraction) // 2 * 2
        step = usable * bin_hz
        pans = []
        for i, r in enumerate(self.cfg.ranges):
            if not r.enabled:
                continue
            lo = max(r.start_hz, self.src.min_freq_hz)
            hi = min(r.stop_hz, self.src.max_freq_hz)
            if hi <= lo:
                log.warning("Діапазон %s поза межами приймача", r.name)
                continue
            n_seg = max(1, math.ceil((hi - lo) / step))
            centers = [lo + step / 2 + k * step for k in range(n_seg)]
            nb = int(math.ceil((hi - lo) / bin_hz))
            pans.append(Panorama(i, r.name, lo, hi, bin_hz, centers, usable,
                                 np.full(nb, np.nan, np.float32), np.full(nb, -200.0, np.float32),
                                 spectrum.NoiseFloorTracker(nb)))
        fb = self.cfg.full_band
        if fb.enabled:
            lo = max(fb.start_hz, self.src.min_freq_hz)
            hi = fb.stop_hz or self.fe.max_freq_hz(self.src.max_freq_hz)
            # Сегменти, які вже повністю покриті пріоритетними діапазонами, не дублюємо
            covered = [(p.start_hz, p.stop_hz) for p in pans]
            n_seg = max(1, math.ceil((hi - lo) / step))
            centers = [c for c in (lo + step / 2 + k * step for k in range(n_seg))
                       if not any(a <= c - step / 2 and c + step / 2 <= b for a, b in covered)]
            nb = int(math.ceil((hi - lo) / bin_hz))
            if centers:
                pans.append(Panorama(FULL_BAND_INDEX, "Повний діапазон", lo, hi, bin_hz, centers, usable,
                                     np.full(nb, np.nan, np.float32), np.full(nb, -200.0, np.float32),
                                     spectrum.NoiseFloorTracker(nb), full=True))
        if self.cfg.dsp.echo_filter:
            for p in pans:
                p.static_db = np.full(len(p.spec), np.nan, np.float32)
                p.learn_left = 2
        self.panoramas = pans
        self._need_plan = False

    # ---- робочий цикл ---------------------------------------------------------------
    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._reconf.clear()
                self._run_calls()
                # Приймача немає — тримаємо сервіс живим і періодично пробуємо відкрити SDR
                if not self._opened:
                    if time.time() >= self._next_open:
                        self._opened = self._try_open()
                        if self._opened:
                            log.info("SDR підключено — починаю сканування")
                        else:
                            self._next_open = time.time() + 3.0   # наступна спроба через 3 с
                    if not self._opened:
                        self._stop.wait(1.0)
                        continue
                if self._need_plan:
                    self._build_plan()
                # Вийшли з режиму передачі — повернути приймання
                if self._audio_active and self.mode != "audio":
                    self._audio_end()
                if self.mode == "audio":
                    self._audio_step()
                    continue
                if self._tx_active and self.mode != "transmit":
                    self._tx_end()
                if self.mode == "transmit":
                    self._transmit_step()
                    continue
                self._apply_gain()
                if self.mode == "paused":
                    self._stop.wait(0.5)
                elif self.mode == "watch":
                    self._watch_step()
                else:
                    self._scan_cycle()
            except Exception as e:  # noqa: BLE001 — приймач може «відвалитися» по USB
                self.stats["errors"] += 1
                self.stats["last_error"] = str(e)
                log.exception("Помилка циклу")
                self._recover()

    def _recover(self) -> None:
        # Приймач «відвалився» (USB) — позначаємо закритим; цикл сам перевідкриє його через _try_open
        self._tx_active = False
        self._opened = False
        self._next_open = time.time() + 2.0
        try:
            self.src.close()
        except Exception:  # noqa: BLE001
            pass
        self._stop.wait(2.0)

    def _apply_gain(self) -> None:
        lna, vga, amp = self.gain
        if (self.src.lna_gain, self.src.vga_gain, self.src.amp) != (lna, vga, amp):
            self.src.set_gain(lna, vga, amp)

    def _agc(self, iq: np.ndarray) -> None:
        """Захист від перевантаження АЦП: сильний сигнал поруч «засліплює» приймач."""
        if not self.cfg.sdr.auto_gain or len(iq) == 0:
            return
        m = float(np.percentile(np.abs(iq[:4096]), 99.9))
        lna, vga, amp = self.gain
        if m > 0.9:
            if amp:
                amp = False
            elif lna > 8:
                lna -= 8
            elif vga > 4:
                vga -= 4
        elif m < 0.05 and lna < self.cfg.sdr.lna_gain:
            lna = min(self.cfg.sdr.lna_gain, lna + 8)
        self.gain = [lna, vga, amp]
        self._apply_gain()

    @property
    def gain_offset_db(self) -> float:
        """Поправка dBFS → dBm (приблизно; уточнюється калібруванням)."""
        return -self.src.total_gain_db - self.fe.external_gain_db + self.cfg.distance.rx_cal_db

    def _tune(self, rf_hz: float) -> None:
        """Налаштування з урахуванням зовнішнього тракту (комутатор антен, LNA, конвертер)."""
        self.fe.tune(rf_hz)

    def _read(self, n: int) -> np.ndarray:
        iq = self.src.read(n)
        # Сторожовий таймер: HackRF іноді «зависає» по USB і віддає нулі — перепідключаємо
        now = time.time()
        if len(iq) and np.any(iq[:256]):
            self._last_good = now
        elif now - getattr(self, "_last_good", now) > 5.0:
            self._last_good = now
            raise RuntimeError("HackRF не дає даних 5 с — перепідключення")
        # Конвертер із гетеродином вище сигналу дзеркалить спектр — повертаємо як в ефірі
        return np.conj(iq) if self.fe.inverted else iq

    def _capture_spectrum(self, center: float) -> tuple[np.ndarray, np.ndarray]:
        d = self.cfg.dsp
        self._tune(center)
        iq = self._read(d.fft_size * (d.averages + 1))
        self._agc(iq)
        s = spectrum.remove_dc(spectrum.psd_db(iq, d.fft_size, d.averages)) + self.gain_offset_db
        return s, iq

    def _scan_cycle(self) -> None:
        t0 = time.time()
        # Фокус перегляду: діапазон, відкритий у застосунку, скануємо кожен цикл, решту — кожен 4-й.
        # Так спектр/водоспад на екрані оновлюються в рази частіше, а виявлення по інших триває.
        focus = self.hub.viewed_ranges()
        self._cycle_n = getattr(self, "_cycle_n", 0) + 1
        for pano in list(self.panoramas):
            if self._interrupted():
                return
            if focus and pano.index not in focus and self._cycle_n % 4:
                continue
            self._run_hunts()
            self._sweep(pano)
        self.stats["sweep_s"] = round(time.time() - t0, 3)
        self.stats["sweeps"] += 1
        self._publish_signals()
        if not self.panoramas:
            self._stop.wait(1.0)

    def _interrupted(self) -> bool:
        return self._stop.is_set() or self._reconf.is_set()

    def _sweep(self, pano: Panorama) -> None:
        d = self.cfg.dsp
        n = d.fft_size
        crop0 = (n - pano.usable_bins) // 2
        dets: list[spectrum.Detection] = []
        centers = pano.centers
        if pano.full:
            k = max(1, self.cfg.full_band.segments_per_cycle)
            centers = pano.centers[pano.cursor:pano.cursor + k]
        for c in centers:
            if self._interrupted():
                return
            s, _ = self._capture_spectrum(c)
            s = s[crop0:crop0 + pano.usable_bins]
            psl, ssl = pano.segment_slice(c)
            seg = s[ssl]
            pano.spec[psl] = seg
            pano.peak_hold[psl] = np.maximum(pano.peak_hold[psl] - 0.2, seg)
            floor = pano.floor.update(psl, seg)
            # Ехо-фільтр: вивчаємо сталий фон (власні завади, спури Pi/USB, постійні передавачі),
            # а потім піднімаємо поріг там, де цей фон завжди є — щоб не реагувати на нього.
            if pano.static_db is not None and pano.learn_left > 0:
                stat = pano.static_db[psl]
                pano.static_db[psl] = np.where(np.isnan(stat), seg, np.maximum(stat, seg))
                continue   # поки вчимося — не детектуємо (щоб сталі завади не стали сигналами)
            if pano.static_db is not None:
                stat = np.nan_to_num(pano.static_db[psl], nan=-300.0)
                # Розширюємо завадy на ±2 біни (спектральне розтікання) і лишаємо 4 дБ запасу,
                # щоб коливання підсилення не «проривали» фільтр
                stat = np.maximum.reduce([stat, np.roll(stat, 1), np.roll(stat, -1),
                                          np.roll(stat, 2), np.roll(stat, -2)])
                floor = np.maximum(floor, stat - 4.0)
            dets += spectrum.detect(seg, floor, pano.freqs(psl), d.threshold_db, d.min_bandwidth_hz)
        lo_hz, hi_hz, timeout = pano.start_hz, pano.stop_hz, None
        if pano.full:
            half = pano.usable_bins * pano.bin_hz / 2
            lo_hz, hi_hz = centers[0] - half, centers[-1] + half
            pano.cursor += len(centers)
            if pano.cursor >= len(pano.centers):
                pano.cursor = 0
                pano.sweeps += 1
                pano.pass_s = time.time() - pano.pass_started
                pano.pass_started = time.time()
                if pano.learn_left > 0:
                    pano.learn_left -= 1
            # Сюди повертаємось лише раз за повний прохід — втрата лише після кількох пропусків
            timeout = max(self.cfg.dsp.lost_timeout_s, 2.5 * (pano.pass_s or 30.0))
        else:
            pano.sweeps += 1
            if pano.learn_left > 0:
                pano.learn_left -= 1
        dets = spectrum.absorb_satellites(spectrum.merge_edge_detections(dets))
        to_analyze = self.tracker.update(dets, pano.name, lo_hz, hi_hz, 0.0, lost_timeout_s=timeout)
        if pano.full:
            to_analyze += self._confirm_in_place(pano, lo_hz, hi_hz, timeout)
        # Спершу — нові та широкосмугові (відео) сигнали
        to_analyze.sort(key=lambda t: (t.classification is not None, -t.bandwidth_hz))
        for t in to_analyze[:MAX_ANALYSES_PER_SWEEP]:
            if self._interrupted():
                break
            self._analyze(t)
        for t in self.tracker.tracks.values():
            if t.range_name == pano.name and t.state == "confirmed":
                if t.fhss_key and t.iq_obj is not None:
                    self._classify(t)  # стрибки накопичуються з кожним проходом
                self._update_distance(t)
        self._flush_events()
        self._publish_spectrum(pano)
        self._store_waterfall(pano)

    def _confirm_in_place(self, pano: Panorama, lo: float, hi: float, timeout: float | None) -> list[Track]:
        """На повному діапазоні до сегмента повертаємось лише раз за прохід, тому нового кандидата
        підтверджуємо одразу повторними замірами — шумовий сплеск їх не пройде."""
        out: list[Track] = []
        for t in list(self.tracker.tracks.values()):
            if t.state != "candidate" or t.range_name != pano.name or not (lo <= t.freq_hz <= hi):
                continue
            for _ in range(self.cfg.dsp.confirm_hits - 1):
                found = self._probe(t.freq_hz, t.bandwidth_hz * 0.3, max_off=max(1e6, t.bandwidth_hz / 2))
                if found is None:
                    break
                out += self.tracker.update([found], pano.name, found.freq_hz - 1, found.freq_hz + 1, 0.0,
                                           lost_timeout_s=timeout)
        return [t for t in out if t.state == "confirmed"]

    # ---- аналіз сигналу ----------------------------------------------------------------
    def _analyze(self, t: Track, record_frames: int = 0) -> np.ndarray | None:
        fs = self.src.sample_rate
        t.last_analysis = time.time()
        img = None
        if t.fhss_key:
            # Для FHSS аналізуємо проміжок, де був останній «стрибок»
            center = t.hop_freqs[-1] if t.hop_freqs else t.freq_hz
            self._tune(center)
            iq = self._read(int(fs * 0.01))
            iqf = classifier.iq_features(iq, fs, 0.0, t.hop_bw_hz or 1e6)
            res = None
        else:
            self._tune(t.freq_hz)
            iq = self._read(int(fs * self.cfg.dsp.video_capture_s))
            iqf = classifier.iq_features(iq, fs, 0.0, t.bandwidth_hz)
            res = None
            kinds = {r.kind for r in ch.link_ranges_for(t.freq_hz)}
            if t.bandwidth_hz >= 1.5e6 and iqf.envelope_cv < 0.6 and ("video" in kinds or t.bandwidth_hz < 25e6):
                res = video.demodulate(iq, fs, 0.0, force_invert=self.video_opts["invert"],
                                       auto_contrast=self.video_opts["auto_contrast"],
                                       descramble=self.video_opts["descramble"])
        t.iq = iqf.to_dict()
        t.iq_obj, t.video_obj = iqf, res
        self._classify(t)
        if res is not None and res.is_video:
            t.video = res.to_dict()
            img = res.image
            if img is not None:
                data, mime = encode(img)
                t.thumbnail_id = self.storage.add_file(
                    "thumb", f"thumbs/{int(time.time() * 1000)}_{t.id}.{mime.split('/')[1]}", data,
                    event_id=t.event_id, meta={"mime": mime, "freq_hz": t.freq_hz})
        else:
            t.video = None
        self._update_distance(t)
        return img

    def _classify(self, t: Track) -> None:
        res = t.video_obj if (t.video_obj is not None and t.video_obj.is_video) else None
        c = classifier.classify(t.freq_hz, t.hop_bw_hz if t.fhss_key else t.bandwidth_hz,
                                t.flatness, t.edge, t.iq_obj, res, hopping=t.hopping, presence=t.presence)
        self.tracker.set_classification(t, c)

    def _update_distance(self, t: Track) -> None:
        if not t.classification:
            return
        dc = self.cfg.distance
        # Тренд рахуємо лише після 8 с спостереження — інакше він шумить
        slope = t.rssi_slope if (t.last_seen - t.first_seen > 8 and not t.fhss_key) else 0.0
        gain, in_band = self.cfg.antenna.gain_at(t.freq_hz, dc.rx_antenna_gain_dbi)
        t.distance = dist.estimate(t.classification.code, t.freq_hz, t.rssi_smooth, slope,
                                   dc.path_loss_exponent, gain).to_dict()
        t.distance["antenna_in_band"] = in_band

    def _record_auto_clip(self, t: Track, event_id: int) -> None:
        """Короткий кліп одразу після виявлення відео — для перегляду в історії."""
        if not self.cfg.storage.record_video or not (t.classification and t.classification.can_show_video):
            return
        fs = self.src.sample_rate
        clip = ClipWriter(self.storage, t.freq_hz, t.classification.label, event_id, max_s=60)
        try:
            self._tune(t.freq_hz)
            for _ in range(4):
                iq = self._read(int(fs * self.cfg.dsp.video_capture_s))
                r = video.demodulate(iq, fs, 0.0, force_invert=self.video_opts["invert"],
                                     descramble=self.video_opts["descramble"])
                if r.image is not None:
                    clip.add(*encode(r.image))
        finally:
            clip.close()

    # ---- події -------------------------------------------------------------------------
    def _on_track_event(self, kind: str, t: Track) -> None:
        self._pending.append((kind, t))
        if kind == "lost" and t.classification and t.classification.code.startswith(("analog", "digital")):
            kind_grid = "digital" if t.classification.code.startswith("digital") else "analog"
            self.hunts.append(Hunt(t.id, ch.priority_scan_list(t.freq_hz, kind_grid), time.time() + 30))

    def _flush_events(self) -> None:
        pending, self._pending = self._pending, []
        for kind, t in pending:
            if kind in ("new", "reacquired") and t.classification is None:
                self._analyze(t)
            d = t.to_dict()
            eid = self.storage.add_event(kind, d)
            if kind == "new":
                t.event_id = eid
                if t.thumbnail_id:
                    self.storage.link_file(t.thumbnail_id, eid)
                if t.classification and t.classification.can_show_video:
                    self._record_auto_clip(t, eid)
            d["event_id"] = eid
            img = None
            if t.thumbnail_id:
                f = self.storage.get_file(t.thumbnail_id)
                if f:
                    try:
                        img = open(f["full_path"], "rb").read()
                    except OSError:
                        pass
            if self.notifier:
                self.notifier.maybe_notify(kind, d, img)
            self.hub.publish("live", {"type": "event", "kind": kind, "event_id": eid, "track": d,
                                      "ts": time.time()})

    # ---- пріоритетний пошук ----------------------------------------------------------------
    def _run_hunts(self, max_checks: int = 4) -> None:
        now = time.time()
        self.hunts = [h for h in self.hunts if h.until > now and h.track_id in self.tracker.tracks
                      and self.tracker.tracks[h.track_id].state == "lost"]
        for h in self.hunts[:1]:
            t = self.tracker.tracks[h.track_id]
            for _ in range(max_checks):
                if h.pos >= len(h.freqs):
                    h.pos = 0
                f = h.freqs[h.pos]
                h.pos += 1
                found = self._probe(f, t.bandwidth_hz)
                if found is not None:
                    log.info("Сигнал %s знайдено знову на %.1f МГц", t.id, found.freq_hz / 1e6)
                    t.freq_hz = found.freq_hz
                    if self.mode == "watch" and self.watch_track == t.id:
                        self.watch_freq = found.freq_hz
                    self.tracker.update([found], t.range_name, found.freq_hz - 1, found.freq_hz + 1, 0.0)
                    self.hunts.remove(h)
                    self._flush_events()
                    return

    def _probe(self, freq: float, bw: float, max_off: float = 5e6) -> spectrum.Detection | None:
        d = self.cfg.dsp
        s, _ = self._capture_spectrum(freq)
        n = len(s)
        crop = (n - int(n * self.cfg.sdr.usable_fraction)) // 2
        s = s[crop:n - crop]
        fs = self.src.sample_rate
        freqs = freq + (np.arange(len(s)) - len(s) / 2 + 0.5) * fs / n
        floor = self._known_floor(freqs)
        if floor is None:
            floor = spectrum.local_floor(s)
        dets = spectrum.detect(s, floor, freqs, d.threshold_db, d.min_bandwidth_hz)
        near = [x for x in dets if abs(x.freq_hz - freq) < max_off and x.bandwidth_hz > bw * 0.4]
        return max(near, key=lambda x: x.snr_db) if near else None

    def _known_floor(self, freqs: np.ndarray) -> np.ndarray | None:
        """Рівень шуму з панорами (якщо частоти вже скановано): широкий сигнал на весь сегмент
        не підніме поріг, як було б з миттєвою оцінкою лише по цьому сегменту."""
        for p in sorted(self.panoramas, key=lambda p: p.full):
            if p.start_hz <= freqs[0] and freqs[-1] <= p.stop_hz:
                idx = ((freqs - p.start_hz) / p.bin_hz).astype(int).clip(0, len(p.spec) - 1)
                f = p.floor.get(slice(0, len(p.spec)))[idx]
                if not np.isnan(f).any():
                    return f.astype(np.float32)
        return None

    # ---- стеження / живе відео ------------------------------------------------------------
    def _watch_step(self) -> None:
        auto0 = self.watch_status.get("autoscan")
        if auto0 and auto0.get("mode") in ("full", "range"):
            now = time.time()
            staying = now < auto0["dwell_until"] or (not auto0["circular"] and now - auto0["last_video"] < 1.0
                                                      and auto0["last_video"] > 0)
            if not staying:
                t0 = time.monotonic()
                while time.monotonic() - t0 < 0.15:       # кілька вікон за крок, але статус — регулярно
                    self._search_step(auto0)
                    if time.time() < auto0["dwell_until"]:
                        break
                self._publish_watch(auto0, None)
                return
        fs = self.src.sample_rate
        d = self.cfg.dsp
        f = self.watch_freq
        self._tune(f)
        # Телефон декодує сам (канал «baseband»): Pi лише дискримінатор + проріджування — швидко.
        phone = self.hub.count("baseband") > 0
        legacy = self.hub.count("video") > 0 or self.recording
        cap = baseband.FIELD_S if (phone and not legacy) else d.video_capture_s
        iq = self._read(int(fs * cap))
        self._agc(iq)
        self._watch_n = getattr(self, "_watch_n", 0) + 1
        if not phone or self._watch_n % 3 == 0:     # спектр — не щокадру, щоб не гальмувати відео
            s = spectrum.remove_dc(spectrum.psd_db(iq[: d.fft_size * (d.averages + 1)], d.fft_size, d.averages))
            s = s + self.gain_offset_db
            floor = spectrum.local_floor(s)
            freqs = f + (np.arange(len(s)) - len(s) / 2 + 0.5) * fs / len(s)
            self.hub.publish("live", self._spectrum_msg(-1, "Стеження", freqs[0], freqs[-1], s, floor))

        info = None
        if phone:
            # Не частіше MAX_FPS: швидкий Pi інакше «заллє» мережу полями, яких екран не встигне показати
            wait = 1 / baseband.MAX_FPS - (time.monotonic() - getattr(self, "_bb_last", 0.0))
            if wait > 0:
                time.sleep(wait)
            self._bb_last = time.monotonic()
            n_field = int(fs * baseband.FIELD_S)
            pkt, info = baseband.make_packet(iq[:n_field], fs, f, self.hub.option("baseband", "quality", "normal"))
            self.hub.publish("baseband", pkt)
        if legacy:
            res = video.demodulate(iq, fs, 0.0, force_invert=self.video_opts["invert"],
                                   auto_contrast=self.video_opts["auto_contrast"],
                                   descramble=self.video_opts["descramble"])
            # ЗАВЖДИ віддаємо кадр: є відео — картинка, немає — реальний сніг
            img = res.image if (res.is_video and res.image is not None) else video.raw_raster(iq, fs)
            data, mime = encode(img)
            self.hub.publish("video", data)
            if self.recording:
                if self.clip is None or self.clip.full:
                    self._close_clip()
                    self.clip = ClipWriter(self.storage, f, "Запис стеження", max_s=self.cfg.storage.video_clip_s)
                self.clip.add(data, mime)
            vinfo = res.to_dict()
        else:
            vinfo = info or video.VideoResult().to_dict()
        if info is not None and legacy:
            vinfo = {**vinfo, "decoder": "phone", "fs_out": info["fs_out"], "kbps": info["kbps"]}
        res = _VInfo(vinfo)
        st = self.watch_status
        now = time.time()
        manual = st.get("manual", False)   # ручне сканування повзунком — без «полювання»
        auto = st.get("autoscan")
        if auto and auto.get("mode", "grids") == "grids":
            arrived = auto.setdefault("arrived", now)
            nxt = False
            if res.is_video:
                auto["last_video"] = now
                self._found_add(auto, "video", f, float(vinfo.get("snr_db") or 0),
                                {"standard": vinfo.get("standard")})
                # Круговий режим: показати картинку dwell_s і йти далі по колу; інакше стояти, поки є відео
                nxt = auto.get("circular") and now - arrived > auto.get("dwell_s", 3.0)
            elif now - max(auto["last_video"], arrived) > auto.get("empty_s", 0.3):
                nxt = True    # порожній канал — далі (час на канал ≈ кілька полів відео)
            if nxt:
                auto["idx"] = (auto["idx"] + 1) % len(auto["freqs"])
                if auto["idx"] == 0:
                    auto["rounds"] = auto.get("rounds", 0) + 1
                    auto["round_s"] = round(now - auto.get("round_started", now), 2)
                    auto["round_started"] = now
                auto["arrived"] = now
                auto["last_video"] = 0.0
                self.watch_freq = auto["freqs"][auto["idx"]]
                auto["pos_hz"] = self.watch_freq
        elif auto and res.is_video:
            auto["last_video"] = now          # пошук «full/range» стоїть на знайденому відео
            self._found_add(auto, "video", f, float(vinfo.get("snr_db") or 0), {"standard": vinfo.get("standard")})
        if res.is_video:
            st["lost_since"] = None
            st["hunt"] = None
            if self.video_opts["afc"] and abs(res.afc_offset_hz) > 150e3:
                # Плавне доналаштування на відео (AFC) — не більше 1 МГц за крок
                self.watch_freq = f + float(np.clip(res.afc_offset_hz * 0.4, -1e6, 1e6))
        elif not manual and not auto:
            st["lost_since"] = st.get("lost_since") or now
            # Сигнал зник більше ніж на 2 с — шукаємо по сітці каналів (лише у режимі стеження за сигналом)
            if now - st["lost_since"] > 2.0:
                hunt = st.get("hunt")
                if not hunt:
                    hunt = st["hunt"] = ch.priority_scan_list(f, "analog")
                    st["hunt_pos"] = 0
                pos = st["hunt_pos"] % len(hunt)
                st["hunt_pos"] = pos + 1
                found = self._probe(hunt[pos], 5e6)
                if found is not None:
                    self.watch_freq = found.freq_hz
                    st["lost_since"] = None
                    st["hunt"] = None
        self._publish_watch(auto, vinfo)

    def _publish_watch(self, auto: dict | None, vinfo: dict | None) -> None:
        st = self.watch_status
        now = time.time()
        if vinfo is None:
            vinfo = {"is_video": False, "searching": True}
        m = ch.match_channel(self.watch_freq, kind="analog")
        found = sorted(auto["found"].values(), key=lambda e: e["freq_mhz"]) if auto else []
        self.hub.publish("live", {
            "type": "watch", "freq_hz": round(self.watch_freq), "video": vinfo,
            "channel": m.to_dict() if m else None, "recording": self.recording,
            "manual": st.get("manual", False), "searching": bool(st.get("hunt")), "ts": now,
            "autoscan": ({"mode": auto.get("mode", "grids"), "index": auto["idx"], "total": len(auto["freqs"]),
                          "circular": bool(auto.get("circular")), "rounds": auto.get("rounds", 0),
                          "dwell_s": auto.get("dwell_s", 3.0), "round_s": auto.get("round_s"),
                          "pos_hz": round(auto.get("pos_hz") or self.watch_freq),
                          "start_hz": auto.get("start_hz"), "stop_hz": auto.get("stop_hz"),
                          "dwelling": now < auto.get("dwell_until", 0), "audio": auto.get("audio", True),
                          "found": [{**e, "channel": e.get("channel") or e["key"]} for e in found]}
                         if auto else None),
        })

    def _close_clip(self) -> None:
        if self.clip is not None:
            self.clip.close()
            self.clip = None

    # ---- публікація ----------------------------------------------------------------------
    def _spectrum_msg(self, idx: int, name: str, f0: float, f1: float, spec: np.ndarray,
                      floor: np.ndarray, points: int = SPECTRUM_POINTS) -> dict:
        """Кадр спектра. Масиви — numpy float32: API сам вирішує, як їх віддати
        (бінарно для застосунку або JSON для старих клієнтів)."""
        spec = np.where(np.isnan(spec), floor, spec)
        spec = np.nan_to_num(spec, nan=-140.0)
        floor = np.nan_to_num(floor, nan=-140.0)
        return {
            "type": "spectrum", "range": idx, "name": name, "f_start": f0, "f_stop": f1, "ts": time.time(),
            "bins": spectrum.downsample_max(spec, points).astype(np.float32),
            "floor": _downsample_mean(floor, points).astype(np.float32),
            "threshold_db": self.cfg.dsp.threshold_db,
        }

    def _publish_zoom(self, pano: Panorama, spec: np.ndarray, floor: np.ndarray) -> None:
        """Збільшена ділянка (застосунок розвів пальцями): віддаємо її з повною деталізацією."""
        z = self.hub.option("live", "zoom")
        if not isinstance(z, dict) or z.get("range") != pano.index:
            return
        lo, hi = float(z.get("lo", pano.start_hz)), float(z.get("hi", pano.stop_hz))
        a = max(0, int((lo - pano.start_hz) / pano.bin_hz))
        b = min(len(spec), int(np.ceil((hi - pano.start_hz) / pano.bin_hz)) + 1)
        if b - a < 8 or b - a >= len(spec) * 0.9:
            return
        msg = self._spectrum_msg(pano.index, pano.name, pano.start_hz + a * pano.bin_hz,
                                 pano.start_hz + b * pano.bin_hz, spec[a:b], floor[a:b], SPECTRUM_POINTS)
        msg["zoom"] = True
        self.hub.publish("live", msg)

    def _publish_spectrum(self, pano: Panorama) -> None:
        spec, floor = pano.spec, pano.floor.get(slice(0, len(pano.spec)))
        if pano.full:
            # Повна панорама показує й пріоритетні діапазони (їх скануємо окремо, частіше)
            spec, floor = spec.copy(), floor.copy()
            for p in self.panoramas:
                if p.full:
                    continue
                i0 = int(round((p.start_hz - pano.start_hz) / pano.bin_hz))
                a, b = max(0, i0), min(len(spec), i0 + len(p.spec))
                if b > a:
                    spec[a:b] = p.spec[a - i0:b - i0]
                    floor[a:b] = p.floor.get(slice(a - i0, b - i0))
        msg = self._spectrum_msg(pano.index, pano.name, pano.start_hz, pano.stop_hz, spec, floor,
                                 FULL_SPECTRUM_POINTS if pano.full else SPECTRUM_POINTS)
        self.last_spectrum[pano.index] = msg
        self.hub.publish("live", msg)
        self._publish_zoom(pano, spec, floor)

    def _publish_signals(self) -> None:
        self.hub.publish("live", {"type": "signals", "signals": self.signals(), "ts": time.time()})

    def _store_waterfall(self, pano: Panorama) -> None:
        if not self.cfg.storage.save_waterfall or (pano.full and pano.cursor != 0):
            return
        row = spectrum.downsample_max(np.nan_to_num(pano.spec, nan=-140.0), SPECTRUM_POINTS)
        pano.wf_rows.append((time.time(), row))
        if time.time() - pano.wf_last_save > 60 or len(pano.wf_rows) > 2000:
            self.storage.save_waterfall(pano.name, pano.start_hz, pano.stop_hz, pano.wf_rows)
            pano.wf_rows = []
            pano.wf_last_save = time.time()

    # ---- для API ------------------------------------------------------------------------------
    def sdr_info(self) -> dict:
        return self.src.info()

    def signal_detail(self, track_id: str) -> dict | None:
        t = self.tracker.tracks.get(track_id)
        if not t:
            return None
        d = t.to_dict()
        d["rssi_history"] = list(t.rssi_history)
        return d

    def signals(self) -> list[dict]:
        return [t.to_dict() for t in self.tracker.active()]

    def status(self) -> dict:
        return {
            "mode": self.mode,
            "sdr_connected": self._opened,
            "watch_freq_hz": self.watch_freq,
            "recording": self.recording,
            "tx": self.tx_status(),
            "echo_filter": self.echo_status(),
            "audio": self.audio_status(),
            "dsp": {"fft_size": self.cfg.dsp.fft_size, "averages": self.cfg.dsp.averages,
                    "threshold_db": self.cfg.dsp.threshold_db, "confirm_hits": self.cfg.dsp.confirm_hits,
                    "rbw_hz": round(self.src.sample_rate / max(1, self.cfg.dsp.fft_size)) if self.src.sample_rate else None},
            "focus": sorted(r for r in self.hub.viewed_ranges() if isinstance(r, int)),
            "gain": {"lna": self.gain[0], "vga": self.gain[1], "amp": self.gain[2],
                     "auto": self.cfg.sdr.auto_gain},
            "video_opts": self.video_opts,
            "sdr": self.src.info(),
            "sample_rate": self.src.sample_rate,
            "ranges": [{"index": p.index, "name": p.name, "start_hz": p.start_hz, "stop_hz": p.stop_hz,
                        "segments": len(p.centers), "sweeps": p.sweeps, "full": p.full,
                        "pass_s": round(p.pass_s, 1) if p.full else None} for p in self.panoramas],
            "frontend": self.fe.info(),
            "stats": self.stats,
            "uptime_s": round(time.time() - self.stats["started"]),
            "active_signals": sum(1 for t in self.tracker.tracks.values() if t.state == "confirmed"),
            "hunting": [h.track_id for h in self.hunts],
            "cpu_temp_c": _cpu_temp(),
        }

    def calibrate(self, freq_hz: float, distance_m: float, eirp_dbm: float) -> float:
        """Калібрування RSSI відомим передавачем: модуль вимірює рівень на freq_hz."""
        return self.call(lambda: self._calibrate(freq_hz, distance_m, eirp_dbm))

    def _calibrate(self, freq_hz: float, distance_m: float, eirp_dbm: float) -> float:
        s, _ = self._capture_spectrum(freq_hz)
        peak_dbfs = float(np.max(s)) - self.gain_offset_db
        dc = self.cfg.distance
        dc.rx_cal_db = dist.calibrate(peak_dbfs, self.src.total_gain_db, freq_hz, distance_m, eirp_dbm,
                                      dc.path_loss_exponent, self.cfg.antenna.gain_at(freq_hz, dc.rx_antenna_gain_dbi)[0])
        return dc.rx_cal_db


class _VInfo:
    """Однаковий доступ до результату повного (Pi) і легкого (для телефона) аналізу."""

    def __init__(self, d: dict) -> None:
        self.is_video = bool(d.get("is_video"))
        self.afc_offset_hz = float(d.get("afc_offset_hz") or 0.0)


def _downsample_mean(x: np.ndarray, n: int) -> np.ndarray:
    if len(x) <= n:
        return x
    edges = np.linspace(0, len(x), n + 1).astype(int)
    return np.add.reduceat(x, edges[:-1]) / np.diff(edges)


def _cpu_temp() -> float | None:
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000, 1)
    except (OSError, ValueError):
        return None
