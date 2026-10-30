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
