import pytest

from sdrwatch.config import Config
from sdrwatch.hub import Hub
from sdrwatch.scanner import Engine
from sdrwatch.sources.simulated import SimulatedSource
from sdrwatch.storage import Storage


@pytest.fixture(scope="module")
def engine(tmp_path_factory):
    cfg = Config()
    cfg.storage.path = str(tmp_path_factory.mktemp("st"))
    cfg.full_band.enabled = False  # тут перевіряємо лише FPV-діапазони; повний — у test_full_band
    src = SimulatedSource()
    e = Engine(cfg, src, Storage(cfg.storage.path, 50), None, Hub())
    src.open()
    src.set_sample_rate(20e6)
    e._build_plan()
    for _ in range(7):
        e._scan_cycle()
    return e


def by_class(engine):
    out = {}
    for s in engine.signals():
        out.setdefault(s["class"]["code"], []).append(s)
    return out


def test_scene_classified(engine):
    c = by_class(engine)
    assert {s["video"]["standard"] for s in c["analog_video"]} == {"PAL", "NTSC"}
    assert len(c["analog_video_inverted"]) == 1
    assert len(c["analog_video_scrambled"]) == 1
    assert len(c["digital_video"]) == 1
    assert len(c["control_link"]) == 2


def test_known_grid_and_distance(engine):
    s = [x for x in engine.signals() if x["class"]["code"] == "analog_video_inverted"][0]
    assert s["channel"]["name"] in ("F8", "R7", "A1") and abs(s["freq_hz"] - 5880e6) < 4e6
    assert s["distance"]["min_m"] <= s["distance"]["likely_m"] <= s["distance"]["max_m"]
    assert abs(s["rssi_dbm"] - (-65)) < 3


def test_events_and_media_stored(engine):
    ev = engine.storage.events(limit=100)
    assert any(e["kind"] == "new" and e["class_code"] == "analog_video" for e in ev)
    assert any(m["kind"] == "clip" for e in ev for m in e["media"])


def test_full_band(tmp_path):
    from sdrwatch.sources.simulated import Emitter

    cfg = Config()
    cfg.storage.path = str(tmp_path)
    cfg.ranges = cfg.ranges[:1]                     # лише 5.8 ГГц як пріоритетний
    cfg.full_band.segments_per_cycle = 120          # увесь інший ефір за 3 цикли
    src = SimulatedSource([Emitter(4_300e6, "analog", power_dbm=-60, seed=11),
                           Emitter(100e6, "cw", power_dbm=-50),
                           Emitter(5_880e6, "analog", power_dbm=-60, seed=4)])
    e = Engine(cfg, src, Storage(cfg.storage.path, 50), None, Hub())
    src.open()
    src.set_sample_rate(20e6)
    e._build_plan()
    full = [p for p in e.panoramas if p.full][0]
    assert full.start_hz == 1e6 and full.stop_hz == 6e9
    # Сегменти, вже покриті діапазоном 5.8 ГГц, у повному не дублюються
    assert not any(5_660e6 < c < 5_930e6 for c in full.centers)
    for _ in range(3):
        e._scan_cycle()
    got = {(s["range"], s["class"]["code"]) for s in e.signals()}
    assert ("Повний діапазон", "analog_video") in got          # 4.3 ГГц — поза FPV-сітками
    assert ("Повний діапазон", "known_service") in got         # FM 100 МГц — фон, без сповіщень
    assert ("5.8 ГГц FPV відео", "analog_video") in got
    msg = e.last_spectrum[full.index]
    assert len(msg["bins"]) == 2048 and max(msg["bins"]) > -100


def test_frontend_converter_and_paths():
    from sdrwatch.frontend import FrontEnd

    class Src:
        def __init__(self):
            self.f = None
            self.bias = None

        def tune(self, f):
            self.f = f

        def set_bias_tee(self, on):
            self.bias = on

    src = Src()
    fe = FrontEnd([
        {"name": "LNA 0.5–6 ГГц", "start_hz": 500e6, "stop_hz": 6e9, "gpio": {17: 1}, "bias_tee": True, "gain_db": 20},
        {"name": "Конвертер 6–8 ГГц", "start_hz": 6e9, "stop_hz": 8e9, "gpio": {17: 0}, "lo_hz": 9e9},
    ], src)
    fe.tune(5.8e9)
    assert src.f == 5.8e9 and src.bias is True and not fe.inverted and fe.external_gain_db == 20
    fe.tune(7.2e9)
    assert src.f == 1.8e9 and fe.inverted and src.bias is False
    assert fe.max_freq_hz(6e9) == 8e9
