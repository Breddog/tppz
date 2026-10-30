import pytest

from sdrwatch.dsp.video import demodulate
from sdrwatch.sources.simulated import Emitter, SimulatedSource

FS = 20e6


def capture(kind, standard="PAL", offset=0.0, power=-55, noise=-62):
    s = SimulatedSource([Emitter(5800e6 + offset, kind, power_dbm=power, standard=standard)], noise_dbfs=noise)
    s.set_sample_rate(FS)
    s.set_gain(32, 30, False)
    s.tune(5800e6)
    return s.read(int(FS * 0.045))


@pytest.mark.parametrize("standard,lines", [("PAL", 288), ("NTSC", 240)])
def test_standard_detection(standard, lines):
    r = demodulate(capture("analog", standard), FS)
    assert r.is_video and r.standard == standard and not r.inverted
    assert r.image.shape == (lines, 480)
    assert r.line_corr > 0.9


def test_inverted_video_is_corrected():
    normal = demodulate(capture("analog"), FS)
    inv = demodulate(capture("analog_inverted"), FS)
    assert inv.is_video and inv.inverted
    # Після автокорекції полярності кадр такий самий, як у звичайного відео
    diff = abs(normal.image.astype(int)[50:250].mean() - inv.image.astype(int)[50:250].mean())
    assert diff < 15


def test_scrambled_detected_and_descrambled():
    r = demodulate(capture("analog_scrambled"), FS)
    assert r.is_video and r.scrambled == "rotate" and r.descrambled


def test_digital_has_no_video():
    s = SimulatedSource([Emitter(5800e6, "ofdm", power_dbm=-55, bandwidth_hz=18e6)])
    s.set_sample_rate(FS)
    s.set_gain(32, 30, False)
    s.tune(5800e6)
    assert not demodulate(s.read(int(FS * 0.045)), FS).is_video


def test_noise_is_not_video():
    s = SimulatedSource([])
    s.set_sample_rate(FS)
    s.tune(5800e6)
    assert not demodulate(s.read(int(FS * 0.045)), FS).is_video


def test_afc_reports_carrier_offset():
    a = demodulate(capture("analog", offset=0), FS).afc_offset_hz
    b = demodulate(capture("analog", offset=1.5e6), FS).afc_offset_hz
    assert abs((b - a) - 1.5e6) < 0.3e6
