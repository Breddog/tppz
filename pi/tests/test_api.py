import pytest
from fastapi.testclient import TestClient

from sdrwatch.__main__ import AppState
from sdrwatch.api import create_app
from sdrwatch.config import Config
from sdrwatch.hub import Hub
from sdrwatch.scanner import Engine
from sdrwatch.sources.simulated import SimulatedSource
from sdrwatch.storage import Storage


@pytest.fixture()
def client(tmp_path):
    cfg = Config()
    cfg._path = str(tmp_path / "config.json")
    cfg.api.token = "secret"
    cfg.storage.path = str(tmp_path / "st")
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource(), st, None, Hub())
    eng.start()
    yield TestClient(create_app(AppState(cfg, eng, st, Hub(), "sdr-test")))
    eng.stop()


def test_auth(client):
    assert client.get("/api/ping").status_code == 200
    assert client.get("/api/status").status_code == 401
    assert client.get("/api/status?token=bad").status_code == 401
    assert client.get("/api/status", headers={"Authorization": "Bearer secret"}).status_code == 200


def test_control_and_config(client):
    h = {"Authorization": "Bearer secret"}
    assert client.post("/api/control/watch", json={"freq_hz": 5800e6}, headers=h).json()["mode"] == "watch"
    assert client.post("/api/control/scan", headers=h).json()["mode"] == "scan"
    r = client.put("/api/config", json={"name": "Пост-1", "storage": {"quota_mb": 64}}, headers=h).json()
    assert r["name"] == "Пост-1" and r["storage"]["quota_mb"] == 64 and r["api"]["token"] == "***"
    assert len(client.get("/api/channels", headers=h).json()["bands"]) > 10


def test_pairing_window(client):
    p = client.get("/api/pair").json()
    assert p["app"] == "sdrwatch" and p["t"] == "secret" and p["u"]
    assert "<svg" in client.get("/").text


def test_pairing_closed(tmp_path):
    cfg = Config()
    cfg._path = str(tmp_path / "c.json")
    cfg.api.token = "secret"
    cfg.api.pairing_window_s = 0
    cfg.storage.path = str(tmp_path / "st")
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource(), st, None, Hub())
    c = TestClient(create_app(AppState(cfg, eng, st, Hub(), "sdr-test")))
    assert c.get("/api/pair").status_code == 403
    assert "закрите" in c.get("/").text


def test_announcer_payload(monkeypatch):
    import json
    import socket

    from sdrwatch import discovery

    sent = []

    class FakeSock:
        def setsockopt(self, *a):
            pass

        def sendto(self, data, addr):
            sent.append((json.loads(data), addr))
            if len(sent) >= 2:
                raise SystemExit

    monkeypatch.setattr(socket, "socket", lambda *a, **k: FakeSock())
    monkeypatch.setattr(discovery, "default_gateway", lambda: "192.168.43.1")
    a = discovery.Announcer(lambda: "Пост-1", "sdr-x", 8080, lambda: True)
    try:
        a.run()
    except SystemExit:
        pass
    dsts = {addr[0] for _, addr in sent}
    assert dsts == {"255.255.255.255", "192.168.43.1"}      # broadcast + телефон-шлюз
    assert all(addr[1] == discovery.ANNOUNCE_PORT for _, addr in sent)
    assert sent[0][0] == {"app": "sdrwatch", "name": "Пост-1", "id": "sdr-x", "port": 8080, "pairing": True}


def test_update_upload(client, tmp_path):
    import hashlib
    import json
    import os

    h = {"Authorization": "Bearer secret"}
    fw = (0x10089000).to_bytes(4, "little") + b"\x00" * 40000 + b"2026.01.3-sdrwatch-rx"
    good = hashlib.sha256(fw).hexdigest()
    r = client.post("/api/update/upload?kind=hackrf&sha256=" + "0" * 64, content=fw, headers=h)
    assert r.status_code == 400 and "Контрольна сума" in r.json()["detail"]
    r = client.post("/api/update/upload?kind=hackrf&sha256=x", content=b"junk", headers=h)
    assert r.status_code == 400
    r = client.post(f"/api/update/upload?kind=hackrf&sha256={good}&tag=hackrf-7", content=fw, headers=h)
    assert r.status_code == 200 and r.json()["state"] == "queued"
    st = client.get("/api/update", headers=h).json()
    assert st["status"]["state"] == "queued" and "hackrf_firmware" in st
    upd = os.path.join(str(tmp_path / "st"), "update")
    req = json.load(open(os.path.join(upd, "request.json")))
    assert req["kind"] == "hackrf" and req["sha256"] == good and req["tag"] == "hackrf-7"
    assert open(req["file"], "rb").read() == fw


def test_transmit(client):
    import io

    import numpy as np
    from PIL import Image

    h = {"Authorization": "Bearer secret"}
    assert client.get("/api/tx", headers=h).json()["can_transmit"] is True
    # carrier
    r = client.post("/api/tx/start", json={"mode": "carrier", "freq_hz": 433.5e6, "gain_db": 5, "seconds": 30}, headers=h)
    assert r.status_code == 200 and r.json()["active"] and r.json()["mode"] == "carrier"
    assert client.get("/api/status", headers=h).json()["mode"] == "transmit"
    assert client.post("/api/tx/stop", headers=h).json()["active"] is False
    # image mode потребує завантаженої картинки
    assert client.post("/api/tx/start", json={"mode": "image", "freq_hz": 5800e6}, headers=h).status_code == 400
    buf = io.BytesIO()
    Image.fromarray((np.random.rand(120, 160) * 255).astype("uint8"), "L").save(buf, "PNG")
    up = client.post("/api/tx/image", content=buf.getvalue(), headers=h)
    assert up.status_code == 200 and up.json()["width"] > 0
    r = client.post("/api/tx/start", json={"mode": "image", "freq_hz": 5800e6, "standard": "NTSC", "seconds": 20}, headers=h)
    assert r.status_code == 200 and r.json()["mode"] == "image" and r.json()["has_image"]
    client.post("/api/tx/stop", headers=h)
    # невідомий режим
    assert client.post("/api/tx/start", json={"mode": "xxx", "freq_hz": 1e9}, headers=h).status_code == 400


def test_transmit_disallowed(tmp_path):
    cfg = Config()
    cfg._path = str(tmp_path / "c.json")
    cfg.api.token = "secret"
    cfg.tx.allow = False
    cfg.storage.path = str(tmp_path / "st")
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource(), st, None, Hub())
    eng.start()
    try:
        c = TestClient(create_app(AppState(cfg, eng, st, Hub(), "sdr-test")))
        r = c.post("/api/tx/start", json={"mode": "carrier", "freq_hz": 433e6},
                   headers={"Authorization": "Bearer secret"})
        assert r.status_code == 400 and "вимкнено" in r.json()["detail"]
    finally:
        eng.stop()


def test_echo_filter(client):
    h = {"Authorization": "Bearer secret"}
    r = client.post("/api/control/echo_filter", json={"on": True, "relearn": True}, headers=h)
    assert r.status_code == 200 and r.json()["enabled"] is True
    assert client.get("/api/status", headers=h).json()["echo_filter"]["enabled"] is True
    assert client.post("/api/control/echo_filter", json={"on": False}, headers=h).json()["enabled"] is False


def test_single_user_lock(tmp_path):
    cfg = Config()
    cfg._path = str(tmp_path / "c.json")
    cfg.api.token = "secret"
    cfg.api.multi_user = False
    cfg.storage.path = str(tmp_path / "st")
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource(), st, None, Hub())
    eng.start()
    try:
        c = TestClient(create_app(AppState(cfg, eng, st, Hub(), "sdr-test")))

        def h(cid):
            return {"Authorization": "Bearer secret", "X-Client-Id": cid}

        assert c.post("/api/control/claim?name=A", headers=h("a")).json()["name"] == "A"
        assert c.post("/api/control/scan", headers=h("a")).status_code == 200
        # інший телефон не може керувати, але бачить
        assert c.post("/api/control/watch", json={"freq_hz": 5800e6}, headers=h("b")).status_code == 423
        assert c.get("/api/status", headers=h("b")).status_code == 200
        # перехоплення
        c.post("/api/control/claim?name=B", headers=h("b"))
        assert c.post("/api/control/scan", headers=h("b")).status_code == 200
        assert c.post("/api/control/pause", headers=h("a")).status_code == 423
        # багатокористувацький — обидва
        c.post("/api/control/multi_user?on=true", headers=h("b"))
        assert c.post("/api/control/scan", headers=h("a")).status_code == 200
        assert c.post("/api/control/scan", headers=h("b")).status_code == 200
    finally:
        eng.stop()


def test_network_and_home(client):
    h = {"Authorization": "Bearer secret"}
    # без NetworkManager у CI — info не падає, просто порожні/резервні дані
    net = client.get("/api/network", headers=h).json()
    assert "interfaces" in net and "hostname" in net
    assert client.get("/api/control/holder", headers=h).json()["multi_user"] is True
    home = client.get("/").text
    assert "Мережа" in home and "addwifi" in home and "sdrdetect" in home


def test_audio_and_autoscan(client):
    import time

    h = {"Authorization": "Bearer secret"}
    r = client.post("/api/audio/start", json={"freq_hz": 446.0e6, "mod": "nfm", "squelch_db": 10}, headers=h)
    assert r.status_code == 200 and r.json()["active"] and r.json()["mod"] == "nfm"
    assert client.post("/api/audio/params", json={"squelch_db": 20, "mod": "am"}, headers=h).json()["mod"] == "am"
    assert client.post("/api/audio/start", json={"mod": "xx", "freq_hz": 1e8}, headers=h).status_code == 400
    assert client.post("/api/audio/stop", headers=h).json()["active"] is False
    r = client.post("/api/control/video_autoscan", json={"on": True, "bands": ["R"]}, headers=h)
    assert r.status_code == 200 and r.json()["channels"] == 8
    time.sleep(0.3)
    assert client.get("/api/status", headers=h).json()["mode"] == "watch"
    client.post("/api/control/scan", headers=h)


def test_audio_demod_tone():
    """Демодульований звук рації — чистий тон 1 кГц без перевантаження (ЧМ і АМ)."""
    import numpy as np

    from sdrwatch.dsp.audio import AUDIO_RATE, SDR_RATE, TUNE_OFFSET, AudioDemod
    from sdrwatch.sources.simulated import Emitter, SimulatedSource

    for mode in ("nfm", "am"):
        f = 446e6
        s = SimulatedSource([Emitter(f, mode, power_dbm=-80, bandwidth_hz=20e3)], noise_dbfs=-60)
        s.set_sample_rate(SDR_RATE)
        s.set_gain(32, 30, False)
        s.tune(f + TUNE_OFFSET)
        d = AudioDemod(mode)
        pcm = np.concatenate([d.process(s.read(240000), -TUNE_OFFSET)[0] for _ in range(4)][1:]).astype(float)
        sp = np.abs(np.fft.rfft((pcm - pcm.mean()) * np.hanning(len(pcm))))
        fr = np.fft.rfftfreq(len(pcm), 1 / AUDIO_RATE)
        assert abs(fr[np.argmax(sp[5:]) + 5] - 1000) < 20
        assert 3000 < np.abs(pcm).max() < 32767      # чутно і без кліпінгу


def test_ws_baseband_streams_raw_video(tmp_path):
    from sdrwatch.dsp import baseband
    cfg = Config()
    cfg._path = str(tmp_path / "config.json")
    cfg.api.token = "secret"
    cfg.storage.path = str(tmp_path / "st")
    hub = Hub()
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource([]), st, None, hub)
    eng.start()
    try:
        c = TestClient(create_app(AppState(cfg, eng, st, hub, "sdr-test")))
        h = {"Authorization": "Bearer secret"}
        c.post("/api/control/watch", json={"freq_hz": 5800e6}, headers=h)
        with c.websocket_connect("/ws/baseband?token=secret&quality=economy") as ws:
            got = None
            for _ in range(20):
                m = ws.receive()
                if m.get("bytes"):
                    got = m["bytes"]
                    break
            assert got is not None
            head, hz = baseband.parse_packet(got)
            assert head["bits"] == 4 and head["n"] > 50000
        r = c.post("/api/control/video_autoscan", json={"on": True, "bands": ["R"], "circular": True,
                                                         "dwell_s": 2}, headers=h).json()
        assert r["autoscan"] and r["channels"] == 8
    finally:
        eng.stop()
