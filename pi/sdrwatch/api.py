"""REST + WebSocket API для мобільного застосунку.

Авторизація: заголовок `Authorization: Bearer <token>` або параметр `?token=` (для WebSocket і картинок).
"""

from __future__ import annotations

import asyncio
import hmac
import os
import time

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

    def check_token(token: str | None) -> None:
        if not token or not hmac.compare_digest(token, st.cfg.api.token):
            raise HTTPException(401, "Невірний токен")

    last_seen = [0.0]

    def auth(request: Request, token: str | None = Query(None)) -> None:
        h = request.headers.get("authorization", "")
        check_token(h[7:] if h.lower().startswith("bearer ") else token)
        _mark_client(last_seen)

    # ---- без авторизації: перевірка доступності ---------------------------------
    @app.get("/api/ping")
    def ping():
        return {"app": "sdrwatch", "name": st.cfg.name, "id": st.device_id, "version": __version__}

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
        left = pairing_left()
        qr_svg, payload = "", ""
        if left > 0:
            import json
            payload = json.dumps(pairing_payload(st.cfg, request.url.hostname), ensure_ascii=False,
                                 separators=(",", ":"))
            qr_svg = _qr_svg(payload)
        s = st.engine.status()
        return _HOME.format(
            name=_esc(st.cfg.name), version=__version__, sdr=_esc(s["sdr"]["name"]), mode=s["mode"],
            active=s["active_signals"], temp=s["cpu_temp_c"] or "—",
            pairing=(f'<p>Сполучення відкрите ще <b>{left // 60} хв {left % 60} с</b>. У застосунку натисніть '
                     f'«Додати модуль» → «Знайти в локальній мережі» або відскануйте QR:</p>'
                     f'<div class="qr">{qr_svg or "<pre>" + _esc(payload) + "</pre>"}</div>')
            if left > 0 else
            '<p>Вікно сполучення закрите. Щоб додати телефон: вимкніть і ввімкніть живлення модуля '
            'та протягом 15 хвилин додайте його в застосунку.</p>')

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

    # ---- тестовий передавач ----------------------------------------------------------------------
    _tx_image: dict = {"data": None}

    @app.get("/api/tx", dependencies=[Depends(auth)])
    def tx_status():
        return st.engine.tx_status()

    @app.post("/api/tx/image", dependencies=[Depends(auth)])
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

    @app.post("/api/tx/start", dependencies=[Depends(auth)])
    def tx_start(req: TxReq):
        img = _tx_image["data"] if req.mode == "image" else None
        if req.mode == "image" and img is None:
            raise HTTPException(400, "Спершу завантажте картинку (/api/tx/image)")
        try:
            return st.engine.start_transmit(req.mode, req.freq_hz, req.gain_db, req.standard, img, req.seconds)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/api/tx/stop", dependencies=[Depends(auth)])
    def tx_stop():
        return st.engine.stop_transmit()

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

    # ---- віддалене оновлення (ПЗ модуля, прошивка HackRF) ---------------------------------------
    @app.get("/api/update", dependencies=[Depends(auth)])
    def update_status():
        sdr = st.engine.src.info()
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

    @app.post("/api/update/upload", dependencies=[Depends(auth)])
    async def update_upload(request: Request, kind: str, sha256: str, tag: str = ""):
        """Файл оновлення з телефону (тіло запиту — сам файл). Працює без інтернету на модулі."""
        data = await request.body()
        try:
            updater.stage(kind, data, sha256, tag)
        except UpdateError as e:
            raise HTTPException(400, str(e)) from e
        return updater.status()

    @app.post("/api/update/fetch", dependencies=[Depends(auth)])
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


_HOME = """<!doctype html><html lang="uk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{name} · SDR Watch</title>
<style>body{{font:16px/1.5 system-ui,sans-serif;margin:0;padding:24px;background:#0b0d12;color:#e3ecee}}
main{{max-width:520px;margin:auto}}h1{{font-size:22px}}.qr{{background:#fff;padding:12px;border-radius:8px;
display:inline-block}}.qr svg{{width:260px;height:260px}}dl{{display:grid;grid-template-columns:auto 1fr;gap:4px 16px}}
dt{{color:#93a6ad}}pre{{white-space:pre-wrap;word-break:break-all;color:#111}}</style></head><body><main>
<h1>{name}</h1><dl><dt>Версія</dt><dd>{version}</dd><dt>Приймач</dt><dd>{sdr}</dd><dt>Режим</dt><dd>{mode}</dd>
<dt>Активних сигналів</dt><dd>{active}</dd><dt>Температура CPU</dt><dd>{temp} °C</dd></dl>
<h2>Підключення телефону</h2>{pairing}</main></body></html>"""


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
