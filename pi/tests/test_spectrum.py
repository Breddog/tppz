import numpy as np

from sdrwatch.dsp import spectrum
from sdrwatch.sources.simulated import Emitter, SimulatedSource


def seg(emitters, center=5800e6):
    s = SimulatedSource(emitters)
    s.set_sample_rate(20e6)
    s.set_gain(32, 30, False)
    s.tune(center)
    sp = spectrum.remove_dc(spectrum.psd_db(s.read(1024 * 9), 1024, 8))[102:922]
    freqs = center + (np.arange(len(sp)) - len(sp) / 2 + 0.5) * 20e6 / 1024
    return sp, freqs


def test_no_false_detections_on_noise():
    hits = 0
    for _ in range(30):
        sp, fr = seg([])
        hits += len(spectrum.detect(sp, spectrum.local_floor(sp), fr, 8.0, 60e3))
    assert hits == 0


def test_cw_detected_at_right_frequency():
    sp, fr = seg([Emitter(5803e6, "cw", power_dbm=-90)])
    d = spectrum.detect(sp, spectrum.local_floor(sp), fr, 8.0, 10e3)
    assert len(d) == 1 and abs(d[0].freq_hz - 5803e6) < 50e3


def test_channel_power_matches_input_level():
    noise, _ = seg([])
    sp, fr = seg([Emitter(5800e6, "ofdm", power_dbm=-70, bandwidth_hz=10e6)])
    # Широкий сигнал займає більшу частину сегмента — рівень шуму беремо з «чистого» ефіру,
    # як це робить NoiseFloorTracker для всієї панорами
    d = spectrum.detect(sp, spectrum.local_floor(noise), fr, 8.0, 60e3)
    big = max(d, key=lambda x: x.bandwidth_hz)
    # dBm = dBFS − підсилення + CAL (симулятор: CAL=35)
    assert abs(big.power_dbfs - 62 + 35 - (-70)) < 1.5
    assert big.flatness > 0.7


def test_downsample_keeps_peaks():
    x = np.full(10000, -100.0)
    x[1234] = -20
    assert spectrum.downsample_max(x, 1024).max() == -20
