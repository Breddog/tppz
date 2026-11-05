import time

import numpy as np
import pytest

from sdrwatch.dsp import baseband
from sdrwatch.sources.simulated import Emitter, SimulatedSource

FS = 20e6


def capture(kind="analog", standard="PAL", power=-55, noise=-62):
    s = SimulatedSource([Emitter(5800e6, kind, power_dbm=power, standard=standard)], noise_dbfs=noise)
    s.set_sample_rate(FS)
    s.set_gain(32, 30, False)
    s.tune(5800e6)
    return s.read(int(FS * baseband.FIELD_S))


@pytest.mark.parametrize("quality", ["economy", "normal", "detail"])
def test_packet_roundtrip(quality):
    pkt, info = baseband.make_packet(capture(), FS, 5800e6, quality)
    head, hz = baseband.parse_packet(pkt)
    assert head["freq_hz"] == 5800e6 and head["n"] == len(hz)
    assert info["is_video"] and info["standard"] == "PAL" and not info["inverted"]
    # Потік має влазити у Wi-Fi/точку доступу (≈20 полів/с)
    assert info["kbps"] < (60000 if quality == "detail" else 52000)


def test_inverted_flag_and_noise():
    _, inv = baseband.make_packet(capture("analog_inverted"), FS, 5800e6)
    assert inv["is_video"] and inv["inverted"]
    _, noise = baseband.make_packet(capture("ofdm"), FS, 5800e6)
    assert not noise["is_video"]


def test_ntsc():
    _, info = baseband.make_packet(capture(standard="NTSC"), FS, 5800e6)
    assert info["is_video"] and info["standard"] == "NTSC"


def test_fast_enough():
    iq = capture()
    t = time.perf_counter()
    for _ in range(5):
        baseband.make_packet(iq, FS, 5800e6)
    assert (time.perf_counter() - t) / 5 < 0.1


def test_dump_sample_for_phone_tests(tmp_path):
    # Зразок для перевірки декодера застосунку (mobile/test/baseband_sample.bin)
    pkt, _ = baseband.make_packet(capture(), FS, 5800e6, "normal")
    assert pkt[:4] == b"SDRB"


def test_color_component_for_phone():
    """color=True: у пакеті є кольорова складова (CHRM) з піднесучою PAL; без color — немає."""
    import struct

    from sdrwatch.dsp import baseband
    from sdrwatch.sources.simulated import Emitter, SimulatedSource
    s = SimulatedSource([Emitter(5800e6, "analog_color", power_dbm=-55)], noise_dbfs=-62)
    s.set_sample_rate(20e6)
    s.set_gain(32, 30, False)
    s.tune(5800e6)
    iq = s.read(int(20e6 * baseband.FIELD_S))
    plain, _ = baseband.make_packet(iq, 20e6, 5800e6, "normal")
    pkt, info = baseband.make_packet(iq, 20e6, 5800e6, "normal", color=True)
    assert info["color"] and not (struct.unpack_from("<H", plain, 6)[0] & 4)
    flags = struct.unpack_from("<H", pkt, 6)[0]
    n = struct.unpack_from("<I", pkt, 28)[0]
    off = baseband.HEADER.size + n
    magic, cfs, fsc, scale, delay, nc = baseband.CHROMA.unpack_from(pkt, off)
    assert flags & 4 and magic == b"CHRM" and abs(fsc - 4.43361875e6) < 1 and abs(cfs - 1e6) < 1
    assert len(pkt) == off + baseband.CHROMA.size + 2 * nc and len(pkt) < 2 * len(plain)
