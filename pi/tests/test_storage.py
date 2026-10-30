import numpy as np

from sdrwatch.storage import Storage


def test_ring_buffer_overwrites_oldest(tmp_path):
    st = Storage(str(tmp_path), quota_mb=1)
    st.quota_bytes = 100_000
    ids = [st.add_file("thumb", f"thumbs/{i}.jpg", b"x" * 30_000) for i in range(10)]
    assert st.usage()["used_bytes"] <= 100_000
    assert st.get_file(ids[0]) is None and st.get_file(ids[-1]) is not None


def test_events_query(tmp_path):
    st = Storage(str(tmp_path))
    for i in range(5):
        st.add_event("new", {"id": f"s{i}", "freq_hz": 5800e6 + i, "class": {"code": "analog_video", "priority": 2}})
    assert len(st.events(limit=3)) == 3
    assert [e["id"] for e in st.events(since_id=3)] == [4, 5]


def test_waterfall_roundtrip(tmp_path):
    st = Storage(str(tmp_path))
    rows = [(1000.0 + i, np.full(64, -90.0 + i, np.float32)) for i in range(5)]
    st.save_waterfall("5.8", 5.6e9, 5.9e9, rows)
    w = st.waterfall("5.8", 0, 2000)
    assert len(w["rows"]) == 5 and abs(w["rows"][4][0] - (-86.0)) < 0.6
