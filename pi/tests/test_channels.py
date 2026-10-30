from sdrwatch import channels as ch


def test_match_raceband():
    m = ch.match_channel(5769.9e6, kind="analog")
    assert m.channel.name in ("R4", "B3", "A6") and abs(m.offset_hz) < 2e6


def test_exact_r4():
    m = ch.match_channel(5769e6, kind="analog")
    assert m.channel.name == "R4" and m.offset_hz == 0


def test_priority_list_starts_with_same_band():
    lst = ch.priority_scan_list(5769e6)
    assert lst[0] == 5769e6
    r_band = {c.freq_hz for c in ch.BAND_BY_CODE["R"].channels()}
    assert set(lst[1:8]) <= r_band | {c.freq_hz for c in ch.ALL_CHANNELS}
    assert len(lst) == len(set(lst))


def test_wifi_names():
    assert ch.match_channel(2437e6, kind="wifi").channel.name == "Wi-Fi 6"
