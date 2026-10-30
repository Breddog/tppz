"""REST + WebSocket API для мобільного застосунку.

Авторизація: заголовок `Authorization: Bearer <token>` або параметр `?token=` (для WebSocket і картинок).
"""

from __future__ import annotations

import asyncio
import hmac
import os
import time

from fastapi import Depends, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel

from . import __version__
from . import channels as ch
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

    def check_token(token: str | None) -> None:
        if not token or not hmac.compare_digest(token, st.cfg.api.token):
            raise HTTPException(401, "Невірний токен")

    def auth(request: Request, token: str | None = Query(None)) -> None:
        h = request.headers.get("authorization", "")
        check_token(h[7:] if h.lower().startswith("bearer ") else token)

    # ---- без авторизації: перевірка доступності ---------------------------------
    @app.get("/api/ping")
    def ping():
        return {"app": "sdrwatch", "name": st.cfg.name, "id": st.device_id, "version": __version__}

    # ---- стан і сигнали -----------------------------------------------------------------
    @app.get("/api/status", dependencies=[Depends(auth)])
    def status():
        return {"name": st.cfg.name, "id": st.device_id, "version": __version__, "time": time.time(),
                "location": {"lat": st.cfg.latitude, "lon": st.cfg.longitude},
                **st.engine.status(), "storage": st.storage.usage()}

    @app.get("/api/signals", dependencies=[Depends(auth)])
    def signals():
        return {"signals": st.engine.signals(), "ts": time.time()}

    @app.get("/api/signals/{track_id}", dependencies=[Depends(auth)])
    def signal(track_id: str):
        t = st.engine.tracker.tracks.get(track_id)
        if not t:
            raise HTTPException(404, "Сигнал не знайдено")
        d = t.to_dict()
        d["rssi_history"] = list(t.rssi_history)
        return d

    @app.get("/api/spectrum", dependencies=[Depends(auth)])
    def last_spectrum():
        return {"spectra": list(st.engine.last_spectrum.values())}

    @app.get("/api/channels", dependencies=[Depends(auth)])
    def channels():
        return {"bands": ch.bands_as_dict(),
                "links": [{"name": r.name, "start_hz": r.start_hz, "stop_hz": r.stop_hz, "kind": r.kind}
                          for r in ch.LINK_RANGES]}

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

    @app.post("/api/storage/clear", dependencies=[Depends(auth)])
    def storage_clear():
        st.storage.clear()
        return {"ok": True}

    # ---- конфіг -------------------------------------------------------------------------------
    @app.get("/api/config", dependencies=[Depends(auth)])
    def get_config():
        return st.cfg.to_dict()

    @app.put("/api/config", dependencies=[Depends(auth)])
    async def put_config(request: Request):
        patch = await request.json()
        patch.pop("api", None)  # порт/токен міняються лише локально на Raspberry
        st.cfg.update(patch)
        st.cfg.save()
        st.engine.reconfigure()
        if st.engine.notifier:
            st.engine.notifier.device_name = st.cfg.name
        return st.cfg.to_dict()

    @app.post("/api/ranges/toggle", dependencies=[Depends(auth)])
    def toggle_range(req: RangeToggle):
        if not 0 <= req.index < len(st.cfg.ranges):
            raise HTTPException(400, "Немає такого діапазону")
        st.cfg.ranges[req.index].enabled = req.enabled
        st.cfg.save()
        st.engine.reconfigure()
        return {"ranges": [r.__dict__ for r in st.cfg.ranges]}

    # ---- дистанційне керування -------------------------------------------------------------------
    @app.post("/api/control/scan", dependencies=[Depends(auth)])
    def ctl_scan():
        st.engine.set_mode("scan")
        return st.engine.status()

    @app.post("/api/control/pause", dependencies=[Depends(auth)])
    def ctl_pause():
        st.engine.set_mode("paused")
        return st.engine.status()

    @app.post("/api/control/watch", dependencies=[Depends(auth)])
    def ctl_watch(req: WatchReq):
        try:
            st.engine.set_mode("watch", req.freq_hz, req.track_id)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return st.engine.status()

    @app.post("/api/control/gain", dependencies=[Depends(auth)])
    def ctl_gain(req: GainReq):
        st.engine.set_gain(req.lna, req.vga, req.amp, req.auto)
        st.cfg.save()
        return st.engine.status()

    @app.post("/api/control/video", dependencies=[Depends(auth)])
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

    @app.post("/api/control/record", dependencies=[Depends(auth)])
    def ctl_record(req: RecordReq):
        st.engine.set_recording(req.on)
        return {"recording": st.engine.recording}

    @app.post("/api/calibrate", dependencies=[Depends(auth)])
    def calibrate(req: CalibrateReq):
        cal = st.engine.calibrate(req.freq_hz, req.distance_m, req.eirp_dbm)
        st.cfg.save()
        return {"rx_cal_db": round(cal, 1)}

    @app.post("/api/control/restart", dependencies=[Depends(auth)])
    async def ctl_restart():
        # systemd перезапустить сервіс (Restart=always)
        asyncio.get_running_loop().call_later(0.5, os._exit, 0)
        return {"ok": True}

    # ---- WebSocket: живий спектр/водоспад, сигнали, події -------------------------------------------
    @app.websocket("/ws/live")
    async def ws_live(ws: WebSocket, token: str | None = None):
        try:
            check_token(token)
        except HTTPException:
            await ws.close(code=4401)
            return
        await ws.accept()
        sub = st.hub.subscribe("live", maxsize=64)
        try:
            await ws.send_json({"type": "hello", "status": st.engine.status(), "signals": st.engine.signals()})
            for m in list(st.engine.last_spectrum.values()):
                await ws.send_json(m)
            recv = asyncio.create_task(_client_opts(ws, sub))
            try:
                while True:
                    try:
                        msg = await asyncio.wait_for(sub.q.get(), timeout=10)
                    except asyncio.TimeoutError:
                        await ws.send_json({"type": "ping", "ts": time.time()})
                        continue
                    rng = sub.options.get("range")
                    if msg.get("type") == "spectrum" and rng is not None and msg.get("range") not in (rng, -1):
                        continue
                    await ws.send_json(msg)
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

    @app.exception_handler(TimeoutError)
    async def _timeout(_, exc):
        return JSONResponse({"detail": "Приймач зайнятий, спробуйте ще раз"}, status_code=503)

    return app


async def _client_opts(ws: WebSocket, sub) -> None:
    """Клієнт може надіслати {"range": N} — отримувати спектр лише одного діапазону."""
    try:
        while True:
            m = await ws.receive_json()
            if isinstance(m, dict) and "range" in m:
                sub.options["range"] = m["range"]
    except Exception:  # noqa: BLE001 — з'єднання закрито
        return
