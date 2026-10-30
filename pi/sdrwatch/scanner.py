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
from .dsp import classifier, spectrum, video
from .hub import Hub
from .imaging import ClipWriter, encode
from .notifier import Notifier
from .storage import Storage
from .tracker import Track, Tracker

log = logging.getLogger(__name__)

SPECTRUM_POINTS = 1024
MAX_ANALYSES_PER_SWEEP = 2


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
        self.stats = {"sweep_s": 0.0, "sweeps": 0, "started": time.time(), "errors": 0, "last_error": ""}
        self._stop = threading.Event()
        self._reconf = threading.Event()
        self._lock = threading.RLock()
        self._thread: threading.Thread | None = None
        self.gain = [cfg.sdr.lna_gain, cfg.sdr.vga_gain, cfg.sdr.amp]
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
        self.src.open()
        self.src.set_sample_rate(self.cfg.sdr.sample_rate)
        self._apply_gain()
        self._build_plan()
        self._thread = threading.Thread(target=self._run, daemon=True, name="engine")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
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
                self.watch_status = {"lost_since": None}
            else:
                self._close_clip()
                self.recording = False
            self.mode = mode
        self._reconf.set()

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
        self.panoramas = pans
        self._need_plan = False

    # ---- робочий цикл ---------------------------------------------------------------
    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._reconf.clear()
                self._run_calls()
                if self._need_plan:
                    self._build_plan()
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
        self._stop.wait(2.0)
        try:
            self.src.close()
            self.src.open()
            self.src.set_sample_rate(self.cfg.sdr.sample_rate)
            self._apply_gain()
        except Exception:  # noqa: BLE001
            log.exception("Не вдалося перевідкрити SDR")

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
        return -self.src.total_gain_db + self.cfg.distance.rx_cal_db

    def _capture_spectrum(self, center: float) -> tuple[np.ndarray, np.ndarray]:
        d = self.cfg.dsp
        self.src.tune(center)
        iq = self.src.read(d.fft_size * (d.averages + 1))
        self._agc(iq)
        s = spectrum.remove_dc(spectrum.psd_db(iq, d.fft_size, d.averages)) + self.gain_offset_db
        return s, iq

    def _scan_cycle(self) -> None:
        t0 = time.time()
        for pano in list(self.panoramas):
            if self._interrupted():
                return
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
        for c in pano.centers:
            if self._interrupted():
                return
            s, _ = self._capture_spectrum(c)
            s = s[crop0:crop0 + pano.usable_bins]
            psl, ssl = pano.segment_slice(c)
            seg = s[ssl]
            pano.spec[psl] = seg
            pano.peak_hold[psl] = np.maximum(pano.peak_hold[psl] - 0.2, seg)
            floor = pano.floor.update(psl, seg)
            dets += spectrum.detect(seg, floor, pano.freqs(psl), d.threshold_db, d.min_bandwidth_hz)
        pano.sweeps += 1
        dets = spectrum.absorb_satellites(spectrum.merge_edge_detections(dets))
        to_analyze = self.tracker.update(dets, pano.name, pano.start_hz, pano.stop_hz, 0.0)
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

    # ---- аналіз сигналу ----------------------------------------------------------------
    def _analyze(self, t: Track, record_frames: int = 0) -> np.ndarray | None:
        fs = self.src.sample_rate
        t.last_analysis = time.time()
        img = None
        if t.fhss_key:
            # Для FHSS аналізуємо проміжок, де був останній «стрибок»
            center = t.hop_freqs[-1] if t.hop_freqs else t.freq_hz
            self.src.tune(center)
            iq = self.src.read(int(fs * 0.01))
            iqf = classifier.iq_features(iq, fs, 0.0, t.hop_bw_hz or 1e6)
            res = None
        else:
            self.src.tune(t.freq_hz)
            iq = self.src.read(int(fs * self.cfg.dsp.video_capture_s))
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
        t.distance = dist.estimate(t.classification.code, t.freq_hz, t.rssi_smooth, slope,
                                   dc.path_loss_exponent, dc.rx_antenna_gain_dbi).to_dict()

    def _record_auto_clip(self, t: Track, event_id: int) -> None:
        """Короткий кліп одразу після виявлення відео — для перегляду в історії."""
        if not self.cfg.storage.record_video or not (t.classification and t.classification.can_show_video):
            return
        fs = self.src.sample_rate
        clip = ClipWriter(self.storage, t.freq_hz, t.classification.label, event_id, max_s=60)
        try:
            self.src.tune(t.freq_hz)
            for _ in range(4):
                iq = self.src.read(int(fs * self.cfg.dsp.video_capture_s))
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

    def _probe(self, freq: float, bw: float) -> spectrum.Detection | None:
        d = self.cfg.dsp
        s, _ = self._capture_spectrum(freq)
        n = len(s)
        crop = (n - int(n * self.cfg.sdr.usable_fraction)) // 2
        s = s[crop:n - crop]
        fs = self.src.sample_rate
        freqs = freq + (np.arange(len(s)) - len(s) / 2 + 0.5) * fs / n
        floor = spectrum.local_floor(s)
        dets = spectrum.detect(s, floor, freqs, d.threshold_db, d.min_bandwidth_hz)
        near = [x for x in dets if abs(x.freq_hz - freq) < 5e6 and x.bandwidth_hz > bw * 0.4]
        return max(near, key=lambda x: x.snr_db) if near else None

    # ---- стеження / живе відео ------------------------------------------------------------
    def _watch_step(self) -> None:
        fs = self.src.sample_rate
        d = self.cfg.dsp
        f = self.watch_freq
        self.src.tune(f)
        iq = self.src.read(int(fs * d.video_capture_s))
        self._agc(iq)
        s = spectrum.remove_dc(spectrum.psd_db(iq[: d.fft_size * (d.averages + 1)], d.fft_size, d.averages))
        s = s + self.gain_offset_db
        floor = spectrum.local_floor(s)
        freqs = f + (np.arange(len(s)) - len(s) / 2 + 0.5) * fs / len(s)
        self.hub.publish("live", self._spectrum_msg(-1, "Стеження", freqs[0], freqs[-1], s, floor))

        res = video.demodulate(iq, fs, 0.0, force_invert=self.video_opts["invert"],
                               auto_contrast=self.video_opts["auto_contrast"],
                               descramble=self.video_opts["descramble"])
        st = self.watch_status
        now = time.time()
        if res.is_video:
            st["lost_since"] = None
            if self.video_opts["afc"] and abs(res.afc_offset_hz) > 150e3:
                # Плавне доналаштування на відео (AFC) — не більше 1 МГц за крок
                self.watch_freq = f + float(np.clip(res.afc_offset_hz * 0.4, -1e6, 1e6))
            if res.image is not None:
                data, mime = encode(res.image)
                self.hub.publish("video", data)
                if self.recording:
                    if self.clip is None or self.clip.full:
                        self._close_clip()
                        self.clip = ClipWriter(self.storage, f, "Запис стеження", max_s=self.cfg.storage.video_clip_s)
                    self.clip.add(data, mime)
        else:
            st["lost_since"] = st.get("lost_since") or now
            # Сигнал зник більше ніж на 2 с — шукаємо по сітці каналів
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
        m = ch.match_channel(self.watch_freq, kind="analog")
        self.hub.publish("live", {
            "type": "watch", "freq_hz": round(self.watch_freq), "video": res.to_dict(),
            "channel": m.to_dict() if m else None, "recording": self.recording,
            "searching": bool(st.get("hunt")), "ts": now,
        })

    def _close_clip(self) -> None:
        if self.clip is not None:
            self.clip.close()
            self.clip = None

    # ---- публікація ----------------------------------------------------------------------
    def _spectrum_msg(self, idx: int, name: str, f0: float, f1: float, spec: np.ndarray,
                      floor: np.ndarray) -> dict:
        spec = np.where(np.isnan(spec), floor, spec)
        spec = np.nan_to_num(spec, nan=-140.0)
        floor = np.nan_to_num(floor, nan=-140.0)
        return {
            "type": "spectrum", "range": idx, "name": name, "f_start": f0, "f_stop": f1, "ts": time.time(),
            "bins": np.round(spectrum.downsample_max(spec, SPECTRUM_POINTS), 1).tolist(),
            "floor": np.round(_downsample_mean(floor, SPECTRUM_POINTS), 1).tolist(),
            "threshold_db": self.cfg.dsp.threshold_db,
        }

    def _publish_spectrum(self, pano: Panorama) -> None:
        floor = pano.floor.get(slice(0, len(pano.spec)))
        msg = self._spectrum_msg(pano.index, pano.name, pano.start_hz, pano.stop_hz, pano.spec, floor)
        self.last_spectrum[pano.index] = msg
        self.hub.publish("live", msg)

    def _publish_signals(self) -> None:
        self.hub.publish("live", {"type": "signals", "signals": self.signals(), "ts": time.time()})

    def _store_waterfall(self, pano: Panorama) -> None:
        if not self.cfg.storage.save_waterfall:
            return
        row = spectrum.downsample_max(np.nan_to_num(pano.spec, nan=-140.0), SPECTRUM_POINTS)
        pano.wf_rows.append((time.time(), row))
        if time.time() - pano.wf_last_save > 60 or len(pano.wf_rows) > 2000:
            self.storage.save_waterfall(pano.name, pano.start_hz, pano.stop_hz, pano.wf_rows)
            pano.wf_rows = []
            pano.wf_last_save = time.time()

    # ---- для API ------------------------------------------------------------------------------
    def signals(self) -> list[dict]:
        return [t.to_dict() for t in self.tracker.active()]

    def status(self) -> dict:
        return {
            "mode": self.mode,
            "watch_freq_hz": self.watch_freq,
            "recording": self.recording,
            "gain": {"lna": self.gain[0], "vga": self.gain[1], "amp": self.gain[2],
                     "auto": self.cfg.sdr.auto_gain},
            "video_opts": self.video_opts,
            "sdr": self.src.info(),
            "sample_rate": self.src.sample_rate,
            "ranges": [{"index": p.index, "name": p.name, "start_hz": p.start_hz, "stop_hz": p.stop_hz,
                        "segments": len(p.centers), "sweeps": p.sweeps} for p in self.panoramas],
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
                                      dc.path_loss_exponent, dc.rx_antenna_gain_dbi)
        return dc.rx_cal_db


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
