"""REST + WebSocket API для мобільного застосунку.

Авторизація: заголовок `Authorization: Bearer <token>` або параметр `?token=` (для WebSocket і картинок).
"""

from __future__ import annotations

import asyncio
import hmac
import os
import struct
import time

import numpy as np

from fastapi import Depends, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from pydantic import BaseModel

from . import __version__
from . import channels as ch
from .discovery import pairing_payload
from .updates import Updater, UpdateError
from .imaging import read_clip_frame


class WatchReq(BaseModel):
    freq_hz: float | None = None
    track_id: str | None = None


class GainReq(BaseModel):
    lna: float | None = None
    vga: float | None = None
    amp: bool | None = None
    auto: bool | None = None


class VideoReq(BaseModel):
    invert: bool | None = None          # None — авто
    auto_contrast: bool | None = None
    descramble: bool | None = None
    afc: bool | None = None
    invert_auto: bool | None = None     # True — повернути авто-визначення полярності


class RecordReq(BaseModel):
    on: bool


class EchoReq(BaseModel):
    on: bool
    relearn: bool = False


class AudioReq(BaseModel):
    freq_hz: float | None = None
    mod: str = "nfm"                 # nfm | wfm | am
    squelch_db: float = 10.0
    scan_start_hz: float | None = None   # автоскан: діапазон і крок сітки
    scan_stop_hz: float | None = None
    scan_step_hz: float = 12.5e3
    scan_freqs: list[float] | None = None   # сканування збережених частот (пам'ять)
    hold_s: float = 2.0                     # затримка після кінця передачі, с
    lockout: list[float] | None = None      # заблоковані (пропущені) частоти


class AudioParams(BaseModel):
    squelch_db: float | None = None
    mod: str | None = None
    freq_hz: float | None = None


class TimeReq(BaseModel):
    ts: float
    lat: float | None = None
    lon: float | None = None


class VideoAutoscanReq(BaseModel):
    on: bool
    bands: list[str] | None = None
    circular: bool = True
    dwell_s: float = 3.0
    mode: str = "grids"            # grids | full | range
    start_hz: float | None = None
    stop_hz: float | None = None
    audio: bool = True             # шукати й голос (вузькі сигнали < 1.3 ГГц)


class WifiReq(BaseModel):
    ssid: str
    password: str = ""
    priority: int = 5


class TxReq(BaseModel):
    mode: str                       # carrier | tone | bars | image | noise
    freq_hz: float
    gain_db: float | None = None
    standard: str | None = None     # PAL | NTSC (для відео)
    seconds: float | None = None


class CalibrateReq(BaseModel):
    freq_hz: float
    distance_m: float
    eirp_dbm: float = 14.0


class RangeToggle(BaseModel):
    index: int
    enabled: bool


def create_app(app_state) -> FastAPI:
    """app_state: об'єкт з полями cfg, engine, storage, hub, device_id."""
    app = FastAPI(title="SDR Watch", version=__version__)
    st = app_state
    started = time.monotonic()

    def pairing_left() -> int:
        w = st.cfg.api.pairing_window_s
        return max(0, int(w - (time.monotonic() - started))) if w > 0 else 0

    app.state.pairing_open = lambda: pairing_left() > 0
    updater = Updater(st.cfg.storage.path, st.cfg.updates.repo)
    ch.load(st.cfg.storage.path)      # база сіток: оновлена з теки сховища або вбудована
    from .health import Health
    health = Health(st.cfg.storage.path)
    health.start(st.hub)

    def check_token(token: str | None) -> None:
        if not token or not hmac.compare_digest(token, st.cfg.api.token):
            raise HTTPException(401, "Невірний токен")

    last_seen = [0.0]
    # Керування в режимі «тільки один користувач»: хто тримає керування і до коли
    control = {"holder": None, "name": "", "until": 0.0}
    CONTROL_TTL = 60.0

    def _client_id(request: Request) -> str:
        return request.headers.get("x-client-id") or (request.client.host if request.client else "?")

    def auth(request: Request, token: str | None = Query(None)) -> None:
        h = request.headers.get("authorization", "")
        check_token(h[7:] if h.lower().startswith("bearer ") else token)
        _mark_client(last_seen)

    def control_holder() -> dict:
        import time as _t
        if control["holder"] and _t.time() > control["until"]:
            control["holder"] = None
        return {"multi_user": st.cfg.api.multi_user, "holder": control["holder"], "name": control["name"],
                "viewers": st.hub.count("live")}

    def require_control(request: Request, token: str | None = Query(None)) -> None:
        """Для дій, що змінюють стан. У режимі «тільки один» — лише поточний власник керування."""
        auth(request, token)
        if st.cfg.api.multi_user:
            return
        import time as _t
        cid = _client_id(request)
        if control["holder"] and control["holder"] != cid and _t.time() <= control["until"]:
            raise HTTPException(423, f"Керує інший користувач ({control['name'] or 'інший телефон'}). "
                                     f"Перехопіть керування, щоб керувати.")
        control["holder"] = cid
        control["until"] = _t.time() + CONTROL_TTL

    # ---- без авторизації: перевірка доступності ---------------------------------
    @app.get("/api/ping")
    def ping():
        return {"app": "sdrwatch", "name": st.cfg.name, "id": st.device_id, "version": __version__,
                "build": updater.installed_build()}

    # ---- хто керує (режим «тільки один користувач») ---------------------------------
    @app.get("/api/control/holder", dependencies=[Depends(auth)])
    def holder():
        return control_holder()

    @app.post("/api/control/claim", dependencies=[Depends(auth)])
    def claim(request: Request, name: str = Query("")):
        import time as _t
        control["holder"] = _client_id(request)
        control["name"] = name[:40]
        control["until"] = _t.time() + CONTROL_TTL
        return control_holder()

    @app.post("/api/control/release", dependencies=[Depends(auth)])
    def release(request: Request):
        if control["holder"] == _client_id(request):
            control["holder"] = None
            control["name"] = ""
        return control_holder()

    @app.post("/api/control/multi_user", dependencies=[Depends(require_control)])
    def set_multi_user(on: bool = Query(...)):
        st.cfg.api.multi_user = bool(on)
        st.cfg.save()
        return control_holder()

    # ---- сполучення з телефоном без монітора й SSH ------------------------------------
    @app.get("/api/pair")
    def pair(request: Request):
        """Перші N хвилин після ввімкнення віддає токен застосунку (лише в локальній мережі)."""
        if pairing_left() <= 0:
            raise HTTPException(403, "Вікно сполучення закрите. Перезавантажте модуль (вимкніть і ввімкніть "
                                     "живлення) і додайте його протягом 15 хвилин, або відскануйте QR з sdrwatch pair")
        return pairing_payload(st.cfg, request.url.hostname)

    @app.get("/", response_class=HTMLResponse)
    def home(request: Request):
        import json

        from . import network
        left = pairing_left()
        qr_svg, payload = "", ""
        token_for_js = ""
        if left > 0:
            payload = json.dumps(pairing_payload(st.cfg, request.url.hostname), ensure_ascii=False,
                                 separators=(",", ":"))
            qr_svg = _qr_svg(payload)
            token_for_js = st.cfg.api.token
        s = st.engine.status()
        pairing_html = (
            f'<p>Сполучення відкрите ще <b>{left // 60} хв {left % 60} с</b>. У застосунку натисніть '
            f'«Додати модуль» → «Знайти в локальній мережі» або відскануйте QR:</p>'
            f'<div class="qr">{qr_svg or "<pre>" + _esc(payload) + "</pre>"}</div>'
            if left > 0 else
            '<p>Вікно сполучення закрите. Щоб додати телефон: вимкніть і ввімкніть живлення модуля '
            'та протягом 15 хвилин додайте його в застосунку.</p>')
        try:
            net = network.info(st.cfg.name)
        except Exception as e:  # noqa: BLE001
            net = {"hostname": st.cfg.name, "interfaces": [], "wifi": {}, "saved_wifi": [], "error": str(e)}
        return _render_home(st.cfg, s, pairing_html, net, token_for_js, updater.installed_build())

    # ---- стан і сигнали -----------------------------------------------------------------
    @app.get("/api/status", dependencies=[Depends(auth)])
    def status():
        return {"name": st.cfg.name, "id": st.device_id, "version": __version__, "time": time.time(),
                "location": {"lat": st.cfg.latitude, "lon": st.cfg.longitude},
                **st.engine.status(), "storage": st.storage.usage()}

    @app.get("/api/health", dependencies=[Depends(auth)])
    def get_health():
        """Стан модуля: температура/навантаження ЦП, живлення, пам'ять, флешка + історія за годину."""
        return health.report()

    @app.post("/api/time", dependencies=[Depends(auth)])
    def set_time(req: TimeReq):
        """Телефон передає свій час і координати: у Pi немає годинника з батарейкою, а GPS — у телефоні."""
        drift = req.ts - time.time()
        fixed = False
        if abs(drift) > 30:
            import subprocess
            try:
                fixed = subprocess.run(["sudo", "-n", "/usr/bin/date", "-u", "-s", f"@{int(req.ts)}"],
                                       capture_output=True, timeout=5).returncode == 0
            except (OSError, subprocess.SubprocessError):
                fixed = False
        if req.lat is not None and req.lon is not None:
            moved = st.cfg.latitude is None or abs((st.cfg.latitude or 0) - req.lat) + abs(
                (st.cfg.longitude or 0) - req.lon) > 0.0005
            st.cfg.latitude, st.cfg.longitude = round(req.lat, 6), round(req.lon, 6)
            if moved:
                try:
                    st.cfg.save()
                except OSError:
                    pass
        return {"drift_s": round(drift, 1), "clock_fixed": fixed}

    @app.get("/api/signals", dependencies=[Depends(auth)])
    def signals():
        return {"signals": st.engine.signals(), "ts": time.time()}

    @app.get("/api/signals/{track_id}", dependencies=[Depends(auth)])
    def signal(track_id: str):
        d = st.engine.signal_detail(track_id)
        if not d:
            raise HTTPException(404, "Сигнал не знайдено")
        return d

    @app.get("/api/spectrum", dependencies=[Depends(auth)])
    def last_spectrum():
        return {"spectra": [jsonable(m) for m in st.engine.last_spectrum.values()]}

    @app.get("/api/channels", dependencies=[Depends(auth)])
    def channels():
        return {"version": ch.DB_INFO.get("version", 0), "updated": ch.DB_INFO.get("updated"),
                "bands": ch.bands_as_dict(),
                "links": [{"name": r.name, "start_hz": r.start_hz, "stop_hz": r.stop_hz, "kind": r.kind}
                          for r in ch.LINK_RANGES]}

    @app.put("/api/channels", dependencies=[Depends(require_control)])
    async def put_channels(request: Request):
        """Нова база частотних сіток (з GitHub через телефон) — без перепрошивки модуля."""
        db = await request.json()
        try:
            ch.validate(db)
            ch.save_user_db(st.cfg.storage.path, db)
            ch.apply(db)
            st.engine.reload_channels()
        except (ValueError, KeyError, TypeError) as e:
            raise HTTPException(400, str(e)) from e
        return {"version": ch.DB_INFO.get("version"), "bands": len(ch.BANDS), "channels": len(ch.ALL_CHANNELS)}

    # ---- історія (кільцевий запис на флешці) ------------------------------------------------
    @app.get("/api/events", dependencies=[Depends(auth)])
    def events(since_id: int = 0, before_id: int | None = None, limit: int = 100, min_priority: int = 0,
               class_code: str | None = None, ts_from: float | None = None, ts_to: float | None = None):
        return {"events": st.storage.events(since_id, before_id, limit, min_priority, class_code, ts_from, ts_to)}

    @app.get("/api/events/{event_id}", dependencies=[Depends(auth)])
    def event(event_id: int):
        e = st.storage.event(event_id)
        if not e:
            raise HTTPException(404, "Подію не знайдено")
        return e

    @app.get("/api/media/{file_id}", dependencies=[Depends(auth)])
    def media(file_id: int):
        f = st.storage.get_file(file_id)
        if not f or not os.path.exists(f["full_path"]):
            raise HTTPException(404, "Файл перезаписано або не існує")
        if f["kind"] == "clip":
            return {k: v for k, v in f.items() if k != "full_path"}
        return FileResponse(f["full_path"], media_type=f["meta"].get("mime", "application/octet-stream"))

    @app.get("/api/clips/{file_id}/frame/{n}", dependencies=[Depends(auth)])
    def clip_frame(file_id: int, n: int):
        r = read_clip_frame(st.storage, file_id, n)
        if r is None:
            raise HTTPException(404, "Кадр недоступний")
        return Response(r[0], media_type=r[1])

    @app.get("/api/clips", dependencies=[Depends(auth)])
    def clips(limit: int = 50):
        with st.storage._lock:
            rows = st.storage.db.execute(
                "SELECT id, ts, size, event_id, meta FROM files WHERE kind='clip' ORDER BY ts DESC LIMIT ?",
                (min(limit, 500),)).fetchall()
        import json
        out = []
        for r in rows:
            m = json.loads(r["meta"] or "{}")
            out.append({"id": r["id"], "ts": r["ts"], "size": r["size"], "event_id": r["event_id"],
                        "freq_hz": m.get("freq_hz"), "label": m.get("label"),
                        "frames": len(m.get("frames", [])), "duration_s": m.get("duration_s")})
        return {"clips": out}

    @app.get("/api/waterfall", dependencies=[Depends(auth)])
    def waterfall(range_name: str, ts_from: float, ts_to: float, max_rows: int = 400):
        return st.storage.waterfall(range_name, ts_from, ts_to, max_rows)

    @app.get("/api/waterfall/ranges", dependencies=[Depends(auth)])
    def waterfall_ranges():
        return {"ranges": st.storage.waterfall_ranges()}

    @app.get("/api/storage", dependencies=[Depends(auth)])
    def storage_usage():
        return st.storage.usage()

    @app.post("/api/storage/clear", dependencies=[Depends(require_control)])
    def storage_clear():
        st.storage.clear()
        return {"ok": True}

    # ---- конфіг -------------------------------------------------------------------------------
    @app.get("/api/config", dependencies=[Depends(auth)])
    def get_config():
        return st.cfg.to_dict()

    @app.put("/api/config", dependencies=[Depends(require_control)])
    async def put_config(request: Request):
        patch = await request.json()
        patch.pop("api", None)  # порт/токен міняються лише локально на Raspberry
        st.cfg.update(patch)
        st.cfg.save()
        st.engine.reconfigure()
        if st.engine.notifier:
            st.engine.notifier.device_name = st.cfg.name
        return st.cfg.to_dict()

    @app.post("/api/ranges/toggle", dependencies=[Depends(require_control)])
    def toggle_range(req: RangeToggle):
        if not 0 <= req.index < len(st.cfg.ranges):
            raise HTTPException(400, "Немає такого діапазону")
        st.cfg.ranges[req.index].enabled = req.enabled
        st.cfg.save()
        st.engine.reconfigure()
        return {"ranges": [r.__dict__ for r in st.cfg.ranges]}

    # ---- дистанційне керування -------------------------------------------------------------------
    @app.post("/api/control/scan", dependencies=[Depends(require_control)])
    def ctl_scan():
        st.engine.set_mode("scan")
        return st.engine.status()

    @app.post("/api/control/pause", dependencies=[Depends(require_control)])
    def ctl_pause():
        st.engine.set_mode("paused")
        return st.engine.status()

    @app.post("/api/control/watch", dependencies=[Depends(require_control)])
    def ctl_watch(req: WatchReq):
        try:
            st.engine.set_mode("watch", req.freq_hz, req.track_id)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return st.engine.status()

    @app.post("/api/control/gain", dependencies=[Depends(require_control)])
    def ctl_gain(req: GainReq):
        st.engine.set_gain(req.lna, req.vga, req.amp, req.auto)
        st.cfg.save()
        return st.engine.status()

    @app.post("/api/control/video", dependencies=[Depends(require_control)])
    def ctl_video(req: VideoReq):
        o = st.engine.video_opts
        if req.invert_auto:
            o["invert"] = None
        elif req.invert is not None:
            o["invert"] = req.invert
        for k in ("auto_contrast", "descramble", "afc"):
            v = getattr(req, k)
            if v is not None:
                o[k] = v
        return {"video_opts": o}

    @app.post("/api/control/record", dependencies=[Depends(require_control)])
    def ctl_record(req: RecordReq):
        st.engine.set_recording(req.on)
        return {"recording": st.engine.recording}

    @app.post("/api/control/echo_filter", dependencies=[Depends(require_control)])
    def ctl_echo(req: EchoReq):
        res = st.engine.set_echo_filter(req.on, req.relearn)
        st.cfg.save()
        return res

    # ---- звук з ефіру ----------------------------------------------------------------------------
    @app.get("/api/audio", dependencies=[Depends(auth)])
    def audio_status():
        return st.engine.audio_status()

    @app.post("/api/audio/start", dependencies=[Depends(require_control)])
    def audio_start(req: AudioReq):
        scan = None
        if req.scan_freqs:
            scan = {"freqs": req.scan_freqs, "hold_s": req.hold_s, "lockout": req.lockout}
        elif req.scan_start_hz and req.scan_stop_hz:
            scan = {"start_hz": req.scan_start_hz, "stop_hz": req.scan_stop_hz, "step_hz": req.scan_step_hz,
                    "hold_s": req.hold_s, "lockout": req.lockout}
        try:
            return st.engine.start_audio(req.freq_hz, req.mod, req.squelch_db, scan)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/api/audio/params", dependencies=[Depends(require_control)])
    def audio_params(req: AudioParams):
        return st.engine.set_audio_params(req.squelch_db, req.mod, req.freq_hz)

    @app.post("/api/audio/skip", dependencies=[Depends(require_control)])
    def audio_skip():
        """Пропустити поточну частоту (блокування) і шукати далі."""
        return st.engine.audio_skip()

    @app.post("/api/audio/resume", dependencies=[Depends(require_control)])
    def audio_resume(unlock: float | None = Query(None)):
        return st.engine.audio_resume(unlock)

    @app.post("/api/audio/stop", dependencies=[Depends(require_control)])
    def audio_stop():
        return st.engine.stop_audio()

    @app.post("/api/control/video_autoscan", dependencies=[Depends(require_control)])
    def video_autoscan(req: VideoAutoscanReq):
        try:
            return st.engine.set_video_autoscan(req.on, req.bands, req.circular, req.dwell_s, req.mode,
                                                req.start_hz, req.stop_hz, req.audio)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    # ---- тестовий передавач ----------------------------------------------------------------------
    _tx_image: dict = {"data": None}

    @app.get("/api/tx", dependencies=[Depends(auth)])
    def tx_status():
        return st.engine.tx_status()

    @app.post("/api/tx/image", dependencies=[Depends(require_control)])
    async def tx_image(request: Request):
        """Завантажити картинку для режиму відео (тіло — байти зображення)."""
        from .transmitter import load_image
        data = await request.body()
        try:
            img = load_image(data)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(400, f"Не вдалося прочитати зображення: {e}") from e
        _tx_image["data"] = img
        return {"ok": True, "width": img.shape[1], "height": img.shape[0]}

    @app.post("/api/tx/start", dependencies=[Depends(require_control)])
    def tx_start(req: TxReq):
        img = _tx_image["data"] if req.mode == "image" else None
        if req.mode == "image" and img is None:
            raise HTTPException(400, "Спершу завантажте картинку (/api/tx/image)")
        try:
            return st.engine.start_transmit(req.mode, req.freq_hz, req.gain_db, req.standard, img, req.seconds)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/api/tx/stop", dependencies=[Depends(require_control)])
    def tx_stop():
        return st.engine.stop_transmit()

    @app.post("/api/calibrate", dependencies=[Depends(require_control)])
    def calibrate(req: CalibrateReq):
        cal = st.engine.calibrate(req.freq_hz, req.distance_m, req.eirp_dbm)
        st.cfg.save()
        return {"rx_cal_db": round(cal, 1)}

    # ---- мережа (Wi-Fi / Ethernet) -----------------------------------------------------------
    @app.get("/api/network", dependencies=[Depends(auth)])
    def network_info():
        from . import network
        return network.info(st.cfg.name)

    @app.get("/api/network/scan", dependencies=[Depends(auth)])
    def network_scan():
        from . import network
        return {"networks": network.scan_wifi()}

    @app.post("/api/network/wifi", dependencies=[Depends(require_control)])
    def network_add_wifi(req: WifiReq):
        from . import network
        try:
            return network.add_wifi(req.ssid, req.password, req.priority)
        except PermissionError as e:
            raise HTTPException(403, f"Немає дозволу змінювати мережу: {e}") from e
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/api/network/forget", dependencies=[Depends(require_control)])
    def network_forget(name: str = Query(...)):
        from . import network
        try:
            return network.forget_wifi(name)
        except PermissionError as e:
            raise HTTPException(403, str(e)) from e
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/api/control/restart", dependencies=[Depends(require_control)])
    async def ctl_restart():
        # systemd перезапустить сервіс (Restart=always)
        asyncio.get_running_loop().call_later(0.5, os._exit, 0)
        return {"ok": True}

    # ---- віддалене оновлення (ПЗ модуля, прошивка HackRF) ---------------------------------------
    @app.get("/api/update", dependencies=[Depends(auth)])
    def update_status():
        sdr = st.engine.sdr_info()
        return {"sdrwatch_version": __version__, "build": updater.installed_build(),
                "hackrf_firmware": sdr.get("firmware"), "rx_only_firmware": sdr.get("rx_only_firmware"),
                "sdr": sdr.get("name"), "status": updater.status()}

    @app.get("/api/update/available", dependencies=[Depends(auth)])
    def update_available():
        """Модуль сам дивиться релізи на GitHub (потрібен інтернет на модулі)."""
        try:
            return updater.latest()
        except (OSError, ValueError) as e:
            raise HTTPException(503, f"Модуль не має доступу до GitHub: {e}") from e

    @app.post("/api/update/upload", dependencies=[Depends(require_control)])
    async def update_upload(request: Request, kind: str, sha256: str, tag: str = ""):
        """Файл оновлення з телефону (тіло запиту — сам файл). Працює без інтернету на модулі."""
        data = await request.body()
        try:
            updater.stage(kind, data, sha256, tag)
        except UpdateError as e:
            raise HTTPException(400, str(e)) from e
        return updater.status()

    @app.post("/api/update/fetch", dependencies=[Depends(require_control)])
    def update_fetch(kind: str):
        """Модуль сам завантажує останній реліз з GitHub і встановлює."""
        try:
            updater.fetch_and_stage(kind)
        except UpdateError as e:
            raise HTTPException(400, str(e)) from e
        except OSError as e:
            raise HTTPException(503, f"Не вдалося завантажити: {e}") from e
        return updater.status()

    # ---- WebSocket: живий спектр/водоспад, сигнали, події -------------------------------------------
    @app.websocket("/ws/live")
    async def ws_live(ws: WebSocket, token: str | None = None, binary: int = 0):
        """Живі дані. binary=1 — кадри спектра бінарні (див. spectrum_bytes), решта — JSON."""
        try:
            check_token(token)
        except HTTPException:
            await ws.close(code=4401)
            return
        await ws.accept()
        sub = st.hub.subscribe("live", maxsize=64)
        try:
            await ws.send_json({"type": "hello", "status": st.engine.status(), "signals": st.engine.signals(),
                                "health": health.current})
            for m in list(st.engine.last_spectrum.values()):
                await (ws.send_bytes(spectrum_bytes(m)) if binary else ws.send_json(jsonable(m)))
            recv = asyncio.create_task(_client_opts(ws, sub))
            last_sent: dict = {}
            try:
                while True:
                    try:
                        msg = await asyncio.wait_for(sub.q.get(), timeout=10)
                    except asyncio.TimeoutError:
                        await ws.send_json({"type": "ping", "ts": time.time()})
                        continue
                    if msg.get("type") == "spectrum":
                        rng = sub.options.get("range")
                        if rng is not None and msg.get("range") not in (rng, -1, -2, -3):
                            continue
                        # не частіше за fps клієнта (типово 15/с) — інакше телефон «захлинається»
                        key = (msg.get("range"), bool(msg.get("zoom")))
                        now = time.monotonic()
                        if now - last_sent.get(key, 0) < 1 / float(sub.options.get("fps") or 15):
                            continue
                        last_sent[key] = now
                        if binary:
                            await ws.send_bytes(spectrum_bytes(msg))
                            continue
                    await ws.send_json(jsonable(msg))
            finally:
                recv.cancel()
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            st.hub.unsubscribe(sub)

    @app.websocket("/ws/video")
    async def ws_video(ws: WebSocket, token: str | None = None):
        try:
            check_token(token)
        except HTTPException:
            await ws.close(code=4401)
            return
        await ws.accept()
        sub = st.hub.subscribe("video", maxsize=3)
        try:
            while True:
                try:
                    frame = await asyncio.wait_for(sub.q.get(), timeout=10)
                except asyncio.TimeoutError:
                    await ws.send_json({"type": "ping"})
                    continue
                await ws.send_bytes(frame)
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            st.hub.unsubscribe(sub)

    @app.websocket("/ws/baseband")
    async def ws_baseband(ws: WebSocket, token: str | None = None, quality: str = "normal"):
        """Сирий відеосигнал після ЧМ-дискримінатора (див. dsp/baseband.py) — декодує телефон.

        quality: economy (≈3 Мвідл/с, 4 біти) | normal (≈4 Мвідл/с, 8 біт) | detail (≈6.7 Мвідл/с).
        """
        try:
            check_token(token)
        except HTTPException:
            await ws.close(code=4401)
            return
        await ws.accept()
        sub = st.hub.subscribe("baseband", maxsize=2)   # затримка важливіша за повноту: старі поля викидаємо
        sub.options["quality"] = quality
        try:
            while True:
                try:
                    pkt = await asyncio.wait_for(sub.q.get(), timeout=10)
                except asyncio.TimeoutError:
                    await ws.send_json({"type": "ping"})
                    continue
                await ws.send_bytes(pkt)
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            st.hub.unsubscribe(sub)

    @app.websocket("/ws/audioiq")
    async def ws_audioiq(ws: WebSocket, token: str | None = None):
        """Вузька смуга звукового каналу (див. dsp/audio.py iq_packet) — демодулює телефон."""
        try:
            check_token(token)
        except HTTPException:
            await ws.close(code=4401)
            return
        await ws.accept()
        sub = st.hub.subscribe("audioiq", maxsize=6)
        try:
            while True:
                try:
                    pkt = await asyncio.wait_for(sub.q.get(), timeout=10)
                except asyncio.TimeoutError:
                    await ws.send_json({"type": "ping"})
                    continue
                await ws.send_bytes(pkt)
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            st.hub.unsubscribe(sub)

    @app.websocket("/ws/audio")
    async def ws_audio(ws: WebSocket, token: str | None = None):
        """Звук: бінарні блоки PCM 16-біт LE моно 24 кГц (лише коли відкритий шумодав)."""
        try:
            check_token(token)
        except HTTPException:
            await ws.close(code=4401)
            return
        await ws.accept()
        sub = st.hub.subscribe("audio", maxsize=8)
        try:
            while True:
                try:
                    chunk = await asyncio.wait_for(sub.q.get(), timeout=10)
                except asyncio.TimeoutError:
                    await ws.send_json({"type": "ping"})
                    continue
                await ws.send_bytes(chunk)
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            st.hub.unsubscribe(sub)

    @app.exception_handler(TimeoutError)
    async def _timeout(_, exc):
        return JSONResponse({"detail": "Приймач зайнятий, спробуйте ще раз"}, status_code=503)

    return app


SPEC_HEADER = struct.Struct("<4sBBhdddfI")


def spectrum_bytes(m: dict) -> bytes:
    """Бінарний кадр спектра: заголовок + int16 (дБ×10) рівні + int16 шум. У ~6 разів менше за JSON.

    magic b"SPEC", ver 1, flags (bit0 — збільшена ділянка), range i16, f_start f64, f_stop f64,
    ts f64, threshold f32, n u32; далі n×int16 bins, n×int16 floor.
    """
    bins = np.asarray(m["bins"], dtype=np.float32)
    floor = np.asarray(m["floor"], dtype=np.float32)
    head = SPEC_HEADER.pack(b"SPEC", 1, 1 if m.get("zoom") else 0, int(m["range"]), float(m["f_start"]),
                            float(m["f_stop"]), float(m["ts"]), float(m.get("threshold_db", 8.0)), len(bins))
    q = lambda a: np.clip(np.round(a * 10), -32000, 32000).astype("<i2").tobytes()  # noqa: E731
    return head + q(bins) + q(floor)


def jsonable(m: dict) -> dict:
    if isinstance(m.get("bins"), np.ndarray):
        m = {**m, "bins": np.round(m["bins"], 1).tolist(), "floor": np.round(m["floor"], 1).tolist()}
    return m


async def _client_opts(ws: WebSocket, sub) -> None:
    """Клієнт може надіслати {"range": N} — отримувати спектр лише одного діапазону."""
    try:
        while True:
            m = await ws.receive_json()
            if isinstance(m, dict):
                for k in ("range", "zoom", "fps"):
                    if k in m:
                        sub.options[k] = m[k]
    except Exception:  # noqa: BLE001 — з'єднання закрито
        return


def _esc(v) -> str:
    import html
    return html.escape(str(v))


def _qr_svg(data: str) -> str:
    try:
        import qrcode
        import qrcode.image.svg
    except ImportError:
        return ""
    import io
    img = qrcode.make(data, image_factory=qrcode.image.svg.SvgPathImage, box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf)
    return buf.getvalue().decode().split("?>", 1)[-1]


_HEAD = """<!doctype html><html lang="uk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>__TITLE__ · SDR Watch</title>
<style>body{font:16px/1.5 system-ui,sans-serif;margin:0;padding:20px;background:#0b0d12;color:#e3ecee}
main{max-width:560px;margin:auto}h1{font-size:22px}h2{font-size:17px;margin-top:26px;border-top:1px solid #26363d;padding-top:16px}
.qr{background:#fff;padding:12px;border-radius:8px;display:inline-block}.qr svg{width:240px;height:240px}
dl{display:grid;grid-template-columns:auto 1fr;gap:4px 14px}dt{color:#93a6ad}
pre{white-space:pre-wrap;word-break:break-all;color:#111}code{background:#162029;padding:1px 5px;border-radius:4px}
table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:5px 8px;border-bottom:1px solid #1c2730;font-size:14px}
input,button{font:15px system-ui;padding:9px;border-radius:7px;border:1px solid #2a3b44;background:#101720;color:#e3ecee;margin:3px 0}
button{background:#0e7c86;border:0;cursor:pointer;color:#fff;font-weight:600}button.d{background:#7a2a2a}
.row{display:flex;gap:8px;flex-wrap:wrap}.row input{flex:1;min-width:140px}.ok{color:#6cc07f}.err{color:#e06a61}
.net{background:#121a22;border:1px solid #1c2730;border-radius:8px;padding:6px 12px;margin:6px 0}</style></head><body><main>"""


def _render_home(cfg, status: dict, pairing_html: str, net: dict, token_js: str, build: str | None = None) -> str:
    import json as _json
    name = _esc(cfg.name)
    rows = [f"<tr><td>{_esc(i['device'])}</td><td>{_esc(i['type'])}</td>"
            f"<td>{_esc(', '.join(i['ips']) or '—')}</td><td>{_esc(i.get('connection') or '')}</td></tr>"
            for i in net.get("interfaces", [])]
    iface_tbl = ("<table><tr><th>Інтерфейс</th><th>Тип</th><th>IP-адреса</th><th>Мережа</th></tr>"
                 + "".join(rows) + "</table>") if rows else "<p>Інтерфейси не визначені.</p>"
    wifi = net.get("wifi", {}).get("connected_ssid")
    wifi_now = (f"<p>Поточний Wi-Fi: <b>{_esc(wifi['ssid'])}</b> (сигнал {_esc(wifi.get('signal',''))}%)</p>"
                if wifi else "<p>Wi-Fi не підключено (працює через Ethernet або точку доступу).</p>")
    saved = "".join(
        f'<div class="net">{_esc(w["name"])} '
        f'<button class="d" style="float:right;padding:3px 10px" onclick="forget(\'{_esc(w["name"])}\')">забути</button></div>'
        for w in net.get("saved_wifi", []))
    body = f"""{_HEAD.replace("__TITLE__", name)}
<h1>{name}</h1>
<dl><dt>Версія</dt><dd>{__version__}{(' · збірка ' + _esc(build)) if build else ''}</dd><dt>Приймач</dt><dd>{_esc(status['sdr']['name'])}
{'(не підключено)' if not status.get('sdr_connected', True) else ''}</dd>
<dt>Режим</dt><dd>{_esc(status['mode'])}</dd><dt>Активних сигналів</dt><dd>{status['active_signals']}</dd>
<dt>Температура CPU</dt><dd>{status['cpu_temp_c'] or '—'} °C</dd>
<dt>Хост</dt><dd>{_esc(net.get('hostname',''))}.local</dd></dl>

<h2>Мережа</h2>
{iface_tbl}
{wifi_now}

<h2>Підключення телефону</h2>
{pairing_html}

<h2>Налаштування мережі</h2>
<p>Резервна точка доступу телефону: <code>sdrdetect</code> / <code>12345678</code>
(якщо немає спільної мережі — увімкніть її на телефоні, модуль підключиться сам).</p>
<div id="auth"><p>Токен доступу (з QR або застосунку):</p>
<input id="tok" type="password" placeholder="токен" style="width:100%"></div>
<h3 style="font-size:15px">Додати Wi-Fi</h3>
<div class="row"><input id="ssid" placeholder="Назва мережі (SSID)">
<input id="psk" type="password" placeholder="Пароль (порожньо — відкрита)"></div>
<button onclick="addwifi()">Зберегти і підключитися</button>
<button onclick="scan()" style="background:#2a3b44">Показати мережі поблизу</button>
<div id="scan"></div>
<h3 style="font-size:15px">Збережені мережі</h3>
{saved or '<p>Немає збережених Wi-Fi.</p>'}
<div id="msg"></div>
<script>
var TOKEN={_json.dumps(token_js)};
if(TOKEN){{document.getElementById('tok').value=TOKEN;}}
function tok(){{return document.getElementById('tok').value||TOKEN;}}
function msg(t,ok){{var m=document.getElementById('msg');m.className=ok?'ok':'err';m.textContent=t;}}
function H(){{return {{'Authorization':'Bearer '+tok(),'Content-Type':'application/json'}};}}
async function addwifi(){{
 var ssid=document.getElementById('ssid').value,psk=document.getElementById('psk').value;
 if(!ssid){{msg('Вкажіть назву мережі',false);return;}}
 msg('Підключення…',true);
 try{{var r=await fetch('/api/network/wifi',{{method:'POST',headers:H(),body:JSON.stringify({{ssid:ssid,password:psk}})}});
  var j=await r.json(); if(!r.ok)throw j.detail||'помилка';
  msg(j.connected?('Підключено до '+ssid):('Збережено: '+ssid+(j.message?' ('+j.message+')':'')),true);
  setTimeout(function(){{location.reload();}},2500);
 }}catch(e){{msg(''+e,false);}}
}}
async function forget(n){{
 if(!confirm('Забути мережу '+n+'?'))return;
 try{{var r=await fetch('/api/network/forget?name='+encodeURIComponent(n),{{method:'POST',headers:H()}});
  var j=await r.json(); if(!r.ok)throw j.detail||'помилка'; location.reload();
 }}catch(e){{msg(''+e,false);}}
}}
async function scan(){{
 msg('Пошук мереж…',true);
 try{{var r=await fetch('/api/network/scan',{{headers:H()}});var j=await r.json();
  if(!r.ok)throw j.detail||'помилка';
  document.getElementById('scan').innerHTML=j.networks.map(function(n){{
   return '<div class="net" onclick="document.getElementById(\\'ssid\\').value=\\''+n.ssid.replace(/'/g,'')+'\\'" style="cursor:pointer">'
   +n.ssid+' <span style="float:right;color:#93a6ad">'+n.signal+'% '+(n.security||'')+'</span></div>';}}).join('');
  msg('Натисніть мережу, щоб підставити назву',true);
 }}catch(e){{msg(''+e,false);}}
}}
</script>
</main></body></html>"""
    return body


CLIENT_STAMP = os.path.join(os.environ.get("RUNTIME_DIRECTORY", "/run/sdrwatch"), "last_client")


def _mark_client(last: list) -> None:
    """Позначка «застосунок був на зв'язку» для сторожа мережі (sdrwatch-netwatch):
    якщо телефон довго не підключається, модуль перейде на точку доступу sdrdetect."""
    now = time.time()
    if now - last[0] < 10:
        return
    last[0] = now
    try:
        with open(CLIENT_STAMP, "w") as f:
            f.write(str(int(now)))
    except OSError:
        pass
