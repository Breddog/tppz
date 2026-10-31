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
    st = Storage(str(tmp_path / "st"), 50)
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
