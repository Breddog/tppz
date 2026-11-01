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
    cfg.tx.allow = True
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


@pytest.mark.parametrize("mode,extra", [("full", {}), ("range", {"start_hz": 5600e6, "stop_hz": 5950e6})])
def test_autoscan_search_modes_find_video(tmp_path, mode, extra):
    import time as _t
    cfg = Config()
    cfg._path = str(tmp_path / "config.json")
    cfg.api.token = "secret"
    cfg.storage.path = str(tmp_path / "st")
    hub = Hub()
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource(), st, None, hub)
    eng.start()
    try:
        c = TestClient(create_app(AppState(cfg, eng, st, hub, "sdr-test")))
        h = {"Authorization": "Bearer secret"}
        r = c.post("/api/control/video_autoscan", json={"on": True, "mode": mode, "circular": True,
                                                         "dwell_s": 0.5, **extra}, headers=h).json()
        assert r["autoscan"] and r["mode"] == mode
        deadline = _t.time() + 60
        found = []
        while _t.time() < deadline:
            auto = eng.watch_status.get("autoscan") or {}
            found = [e for e in auto.get("found", {}).values() if e["type"] == "video"]
            if any(5760 < e["freq_mhz"] < 5780 for e in found):
                break
            _t.sleep(0.5)
        assert any(5760 < e["freq_mhz"] < 5780 for e in found), found
    finally:
        eng.stop()


def test_audio_iq_channel_for_phone():
    """Канал для демодуляції на телефоні: 48 кГц (ЧМ вузька/АМ), 240 кГц (ЧМ широка), тон 1 кГц зберігається."""
    import struct

    import numpy as np

    from sdrwatch.dsp.audio import SDR_RATE, TUNE_OFFSET, AudioDemod, iq_packet
    from sdrwatch.sources.simulated import Emitter, SimulatedSource

    f = 446e6
    s = SimulatedSource([Emitter(f, "nfm", power_dbm=-80, bandwidth_hz=20e3)], noise_dbfs=-60)
    s.set_sample_rate(SDR_RATE)
    s.set_gain(32, 30, False)
    s.tune(f + TUNE_OFFSET)
    d = AudioDemod("nfm")
    xs = [d.channel(s.read(120000), -TUNE_OFFSET) for _ in range(4)]
    assert all(r == 48000 for _, r, _ in xs)
    x = np.concatenate([a for a, _, _ in xs[1:]])
    fm = np.angle(x[1:] * np.conj(x[:-1]))
    sp = np.abs(np.fft.rfft((fm - fm.mean()) * np.hanning(len(fm))))
    fr = np.fft.rfftfreq(len(fm), 1 / 48000)
    assert abs(fr[np.argmax(sp[5:]) + 5] - 1000) < 20
    pkt = iq_packet(xs[1][0], 48000, f, "nfm", 25.0, 10.0, True)
    magic, ver, mode, flags, freq, rate, scale, lvl, sq, n = struct.unpack_from("<4sBBHdffffI", pkt)
    assert magic == b"SDRA" and n == len(xs[1][0]) and flags == 1 and len(pkt) == 36 + 4 * n


def test_audio_scanner_found_skip_memory(tmp_path):
    """Сканер звуку: знаходить канали, пропускає заблоковані, сканує збережені частоти."""
    import time as _t

    from sdrwatch.sources.simulated import Emitter
    cfg = Config()
    cfg.storage.path = str(tmp_path / "st")
    hub = Hub()
    em = [Emitter(446.10625e6, "nfm", power_dbm=-70, bandwidth_hz=12e3, seed=1),
          Emitter(446.15625e6, "nfm", power_dbm=-70, bandwidth_hz=12e3, seed=2)]
    eng = Engine(cfg, SimulatedSource(em), Storage(cfg.storage.path, 50), None, hub)
    eng.start()
    try:
        eng.start_audio(None, "nfm", 10.0, {"start_hz": 446.00625e6, "stop_hz": 446.19375e6, "step_hz": 12.5e3,
                                             "hold_s": 0.3})

        def wait_lock(timeout=10):
            t0 = _t.time()
            while _t.time() - t0 < timeout:
                st = eng.audio_status()
                if st.get("active") and not st["scanning"]:
                    return st
                _t.sleep(0.1)
            raise AssertionError("не зупинився на сигналі")

        st = wait_lock()
        first = st["freq_hz"]
        assert abs(first - 446.10625e6) < 7e3 or abs(first - 446.15625e6) < 7e3
        assert st["scan"]["found"]
        st = eng.audio_skip()                         # заблокувати й шукати далі
        assert any(abs(f - first) < 1 for f in st["scan"]["lockout"])
        _t.sleep(0.5)
        st = wait_lock()
        assert abs(st["freq_hz"] - first) > 20e3      # інший канал, заблокований пропущено
        # Пам'ять: лише збережені частоти
        eng.start_audio(None, "nfm", 10.0, {"freqs": [446.15625e6, 433.5e6], "hold_s": 0.3, "lockout": []})
        st = wait_lock()
        assert abs(st["freq_hz"] - 446.15625e6) < 1
    finally:
        eng.stop()


def test_channels_db_update(client, tmp_path):
    h = {"Authorization": "Bearer secret"}
    db = client.get("/api/channels", headers=h).json()
    assert db["version"] >= 1 and len(db["bands"]) > 20
    new = {"version": db["version"] + 1, "bands": [
        {"code": "R", "title": "Raceband", "kind": "analog", "freqs_mhz": [5658, 5695], "popular": True},
        {"code": "Z", "title": "Нова сітка", "kind": "analog", "freqs_mhz": [5999]}], "links": []}
    r = client.put("/api/channels", json=new, headers=h)
    assert r.status_code == 200 and r.json()["bands"] == 2
    assert any(b["code"] == "Z" for b in client.get("/api/channels", headers=h).json()["bands"])
    bad = {"version": 99, "bands": [{"code": "Q", "title": "x", "kind": "analog", "freqs_mhz": [99999]}]}
    assert client.put("/api/channels", json=bad, headers=h).status_code == 400
    from sdrwatch import channels as ch
    ch.load()   # повернути вбудовану базу для інших тестів


def test_fast_sweep_mode(tmp_path):
    """Швидкий огляд режимом sweep прошивки HackRF: спектр усього діапазону й виявлення без перебудов."""
    import os
    import sys
    import time as _t
    cfg = Config()
    cfg.storage.path = str(tmp_path / "st")
    cfg.sdr.sweep_cmd = [sys.executable, os.path.join(os.path.dirname(__file__), "tools", "fake_hackrf_sweep.py")]
    cfg.sdr.sweep_bin_hz = 250e3
    eng = Engine(cfg, SimulatedSource([]), Storage(cfg.storage.path, 50), None, Hub())
    eng.start()
    try:
        t0 = _t.time()
        while _t.time() - t0 < 40:
            if eng.stats.get("fast_sweep") and any(abs(t.freq_hz - 5800e6) < 3e6 for t in eng.tracker.tracks.values()):
                break
            _t.sleep(0.3)
        assert eng.stats.get("fast_sweep"), eng.stats
        assert any(abs(t.freq_hz - 5800e6) < 3e6 for t in eng.tracker.tracks.values())
        full = [p for p in eng.panoramas if p.full][0]
        assert full.pass_s > 0
        # відео/звук — sweep зупиняється, звичайний потік відкривається
        eng.set_mode("watch", 5800e6)
        _t.sleep(1.5)
        assert eng.sweeper is None and eng._opened
    finally:
        eng.stop()


def test_wfm_broadcast_with_strong_neighbour():
    """FM-мовлення: сильна сусідня станція (+400 кГц, на 20 дБ сильніша) не повинна забивати канал шумом."""
    import numpy as np

    from sdrwatch.dsp.audio import SDR_RATE, TUNE_OFFSET, AudioDemod
    from sdrwatch.sources.simulated import Emitter, SimulatedSource
    f = 101.5e6
    s = SimulatedSource([Emitter(f, "wfm", power_dbm=-60, bandwidth_hz=200e3),
                         Emitter(f + 400e3, "wfm", power_dbm=-40, bandwidth_hz=200e3, seed=3)], noise_dbfs=-70)
    s.set_sample_rate(SDR_RATE)
    s.set_gain(32, 30, False)
    s.tune(f + TUNE_OFFSET)
    d = AudioDemod("wfm")
    x = np.concatenate([d.channel(s.read(120000), -TUNE_OFFSET)[0] for _ in range(5)][1:])
    fm = np.angle(x[1:] * np.conj(x[:-1]))
    fm = fm - fm.mean()
    sp = np.abs(np.fft.rfft(fm * np.hanning(len(fm)))) ** 2
    fr = np.fft.rfftfreq(len(fm), 1 / 240e3)
    tone = sp[(fr > 900) & (fr < 1100)].sum()
    audio = sp[(fr > 100) & (fr < 15e3)].sum()
    assert tone / audio > 0.8, tone / audio


def test_audio_autostore_and_preview(tmp_path):
    """Як в авто: «пошук усіх станцій» знаходить усі й вмикає найсильнішу; «скан» слухає N с і йде далі."""
    import time as _t

    from sdrwatch.sources.simulated import Emitter
    cfg = Config()
    cfg.storage.path = str(tmp_path / "st")
    em = [Emitter(f * 1e6, "wfm", power_dbm=p, bandwidth_hz=200e3, seed=i)
          for i, (f, p) in enumerate([(88.8, -65), (95.4, -55), (101.5, -60), (104.0, -62)])]
    eng = Engine(cfg, SimulatedSource(em), Storage(cfg.storage.path, 50), None, Hub())
    eng.start()
    try:
        eng.start_audio(None, "wfm", 10.0, {"start_hz": 87.5e6, "stop_hz": 108e6, "step_hz": 100e3, "store": True})
        t0 = _t.time()
        while _t.time() - t0 < 20:
            st = eng.audio_status()
            if st["scan"] and st["scan"]["holding"]:
                break
            _t.sleep(0.2)
        found = sorted(round(e["freq_hz"] / 1e5) / 10 for e in st["scan"]["found"])
        for f in (88.8, 95.4, 101.5, 104.0):
            assert f in found, found
        assert abs(st["freq_hz"] - 95.4e6) < 50e3          # найсильніша
        # «Скан»: по 0.5 с на станцію — частота має змінюватися сама
        eng.start_audio(None, "wfm", 10.0, {"start_hz": 87.5e6, "stop_hz": 108e6, "step_hz": 100e3,
                                             "preview_s": 0.5, "lockout": []})
        seen = set()
        t0 = _t.time()
        while _t.time() - t0 < 12 and len(seen) < 3:
            st = eng.audio_status()
            if not st["scanning"]:
                seen.add(round(st["freq_hz"] / 1e5))
            _t.sleep(0.1)
        assert len(seen) >= 3, seen
    finally:
        eng.stop()


def test_video_autoscan_full_uses_sweep(tmp_path):
    """Автоскан відео «весь діапазон»: спектр — режимом sweep, відео підтверджується звичайним потоком."""
    import os
    import sys
    import time as _t

    from sdrwatch.sources.simulated import Emitter
    cfg = Config()
    cfg.storage.path = str(tmp_path / "st")
    cfg.sdr.sweep_cmd = [sys.executable, os.path.join(os.path.dirname(__file__), "tools", "fake_hackrf_sweep.py")]
    cfg.sdr.sweep_bin_hz = 250e3
    eng = Engine(cfg, SimulatedSource([Emitter(5800e6, "analog", power_dbm=-55)]), Storage(cfg.storage.path, 50),
                 None, Hub())
    eng.start()
    try:
        _t.sleep(1.0)
        eng.set_video_autoscan(True, mode="range", start_hz=5600e6, stop_hz=5950e6, dwell_s=0.5)
        t0 = _t.time()
        found = []
        while _t.time() - t0 < 30:
            auto = eng.watch_status.get("autoscan") or {}
            found = [e for e in auto.get("found", {}).values() if e["type"] == "video"]
            if found and eng.stats.get("fast_sweep"):
                break
            _t.sleep(0.3)
        assert eng.stats.get("fast_sweep")
        assert any(5795 < e["freq_mhz"] < 5805 for e in found), found
    finally:
        eng.stop()


def test_color_video_mjpeg(tmp_path):
    """Кольорове відео: модуль розшифровує PAL і шле JPEG; кольори смуг правильні."""
    import io

    from PIL import Image

    from sdrwatch.dsp.video import demodulate
    from sdrwatch.sources.simulated import Emitter
    s = SimulatedSource([Emitter(5800e6, "analog_color", power_dbm=-55)], noise_dbfs=-62)
    s.set_sample_rate(20e6)
    s.set_gain(32, 30, False)
    s.tune(5800e6)
    r = demodulate(s.read(int(20e6 * 0.045)), 20e6, color=True)
    assert r.is_video and r.rgb is not None and r.color_quality > 0.5
    row = r.rgb[100:200].mean(axis=0)
    bar = lambda k: row[int((k + 0.5) * 320 / 8)]  # noqa: E731
    assert bar(1)[2] < 60 and bar(1)[0] > 60                 # жовтий: мало синього
    assert bar(5)[0] > bar(5)[1] + 80                        # червоний
    assert bar(6)[2] > bar(6)[0] + 60                        # синій
    # через WebSocket
    cfg = Config()
    cfg._path = str(tmp_path / "config.json")
    cfg.api.token = "secret"
    cfg.storage.path = str(tmp_path / "st")
    hub = Hub()
    st = Storage(cfg.storage.path, 50)
    eng = Engine(cfg, SimulatedSource([Emitter(5800e6, "analog_color", power_dbm=-55)]), st, None, hub)
    eng.start()
    try:
        c = TestClient(create_app(AppState(cfg, eng, st, hub, "sdr-test")))
        c.post("/api/control/watch", json={"freq_hz": 5800e6}, headers={"Authorization": "Bearer secret"})
        with c.websocket_connect("/ws/videoc?token=secret") as ws:
            got = None
            for _ in range(20):
                m = ws.receive()
                if m.get("bytes"):
                    got = m["bytes"]
                    break
        im = Image.open(io.BytesIO(got))
        assert im.mode == "RGB" and im.size[0] == 320
    finally:
        eng.stop()
