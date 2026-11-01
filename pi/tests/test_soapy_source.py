"""Порядок роботи з драйвером SoapySDR (без справжнього HackRF): частота — до запуску потоку,
зміна частоти — новий потік (старий не перезапускається), без даних двічі — CF32."""
import sys
import types

import numpy as np


class FakeDev:
    log: list = []

    def __init__(self, args):
        self.rate = 10e6
        FakeDev.log.clear()

    def getFrequencyRange(self, d, c):
        return []

    def getHardwareInfo(self):
        return {"version": "2024.02.1"}

    def getNativeStreamFormat(self, d, c):
        return ("CS8", 128.0)

    def setSampleRate(self, d, c, r):
        self.rate = r
        FakeDev.log.append(("rate", r))

    def getSampleRate(self, d, c):
        return self.rate

    def setBandwidth(self, d, c, b):
        pass

    def setupStream(self, d, fmt):
        FakeDev.log.append(("setup", fmt))
        return object()

    def activateStream(self, s):
        FakeDev.log.append(("activate", self.rate))

    def deactivateStream(self, s):
        FakeDev.log.append(("deactivate",))

    def closeStream(self, s):
        FakeDev.log.append(("close",))

    def getNumChannels(self, d):
        return 1

    def readStream(self, s, bufs, n, timeoutUs=0):
        return types.SimpleNamespace(ret=n)


def test_stream_lifecycle(monkeypatch):
    fake = types.ModuleType("SoapySDR")
    fake.Device = FakeDev
    fake.SOAPY_SDR_RX, fake.SOAPY_SDR_TX, fake.SOAPY_SDR_CF32 = 1, 0, "CF32"
    monkeypatch.setitem(sys.modules, "SoapySDR", fake)
    from sdrwatch.sources.soapy import SoapySource
    src = SoapySource("driver=hackrf")
    src.open(20e6)
    # частота виставлена ДО створення й запуску потоку
    i_rate = FakeDev.log.index(("rate", 20e6))
    i_setup = next(i for i, e in enumerate(FakeDev.log) if e[0] == "setup")
    assert i_rate < i_setup and FakeDev.log[i_setup] == ("setup", "CS8")
    assert ("activate", 20e6) in FakeDev.log
    # зміна частоти: старий потік закрито, новий створено й запущено вже на 2.4 МГц
    FakeDev.log.clear()
    src.set_sample_rate(2.4e6)
    assert FakeDev.log[:2] == [("deactivate",), ("close",)]
    assert ("rate", 2.4e6) in FakeDev.log and ("activate", 2.4e6) in FakeDev.log
    assert src.sample_rate == 2.4e6
    # та сама частота — нічого не перезапускається
    FakeDev.log.clear()
    src.set_sample_rate(2.4e6)
    assert FakeDev.log == []
    # читання CS8 → complex64
    iq = src.read(1000)
    assert iq.dtype == np.complex64 and len(iq) == 1000
    # двічі без даних — далі CF32
    src.note_no_data()
    src.note_no_data()
    src.close()
    src.open(20e6)
    assert ("setup", "CF32") in FakeDev.log
