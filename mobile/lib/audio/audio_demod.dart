import 'dart:math' as math;
import 'dart:typed_data';

/// Пакет вузької смуги звукового каналу з модуля (див. pi/sdrwatch/dsp/audio.py iq_packet).
class AudioIqPacket {
  AudioIqPacket._(this.mode, this.open, this.freqHz, this.rate, this.levelDb, this.squelchDb, this.iq);

  final String mode; // nfm | wfm | am
  final bool open; // шумодав модуля відкритий
  final double freqHz;
  final double rate;
  final double levelDb;
  final double squelchDb;

  /// Перемежовані I, Q (float).
  final Float32List iq;

  static const headerSize = 36;

  static AudioIqPacket? parse(Uint8List b) {
    if (b.length < headerSize || b[0] != 0x53 || b[1] != 0x44 || b[2] != 0x52 || b[3] != 0x41) return null;
    final d = ByteData.sublistView(b);
    final mode = const ['nfm', 'wfm', 'am'][d.getUint8(5).clamp(0, 2)];
    final flags = d.getUint16(6, Endian.little);
    final freq = d.getFloat64(8, Endian.little);
    final rate = d.getFloat32(16, Endian.little);
    final scale = d.getFloat32(20, Endian.little);
    final level = d.getFloat32(24, Endian.little);
    final sq = d.getFloat32(28, Endian.little);
    final n = d.getUint32(32, Endian.little);
    final m = math.min(n * 2, (b.length - headerSize) ~/ 2);
    final iq = Float32List(m);
    for (var i = 0; i < m; i++) {
      iq[i] = d.getInt16(headerSize + i * 2, Endian.little) * scale;
    }
    return AudioIqPacket._(mode, flags & 1 != 0, freq, rate, level, sq, iq);
  }
}

/// Потоковий КІХ-фільтр із проріджуванням (рахує лише потрібні виходи).
class _FirDecim {
  _FirDecim(this.taps, this.decim) : _hist = Float32List(taps.length);

  final Float32List taps;
  final int decim;
  final Float32List _hist;
  int _pos = 0;
  int _phase = 0;

  Float32List process(Float32List x) {
    final out = Float32List(x.length ~/ decim + 1);
    var k = 0;
    final n = taps.length;
    for (var i = 0; i < x.length; i++) {
      _hist[_pos] = x[i];
      _pos = (_pos + 1) % n;
      if (++_phase >= decim) {
        _phase = 0;
        var acc = 0.0;
        var j = _pos;
        for (var t = 0; t < n; t++) {
          acc += taps[t] * _hist[j];
          if (++j == n) j = 0;
        }
        out[k++] = acc;
      }
    }
    return Float32List.sublistView(out, 0, k);
  }
}

Float32List _lowpass(double cutoffNorm, int ntaps) {
  final t = Float32List(ntaps);
  var sum = 0.0;
  for (var i = 0; i < ntaps; i++) {
    final n = i - (ntaps - 1) / 2;
    final x = 2 * math.pi * cutoffNorm * n;
    final sinc = n == 0 ? 1.0 : math.sin(x) / x;
    final w = 0.54 - 0.46 * math.cos(2 * math.pi * i / (ntaps - 1));
    t[i] = 2 * cutoffNorm * sinc * w;
    sum += t[i];
  }
  for (var i = 0; i < ntaps; i++) {
    t[i] /= sum;
  }
  return t;
}

/// Демодуляція звуку НА ТЕЛЕФОНІ: ЧМ вузька / широка (з деакцентом 50 мкс) / АМ (з АРП).
/// Вихід — 24 кГц, 16 біт, моно.
class PhoneAudioDemod {
  static const outRate = 24000;

  String _mode = '';
  double _rate = 0;
  _FirDecim? _f;
  double _pi = 1, _pq = 0;
  double _deemph = 0;
  double? _agc;
  double _dc = 0;

  /// Гучність (множник), 0.2..4.
  double volume = 1.0;

  void _setup(String mode, double rate) {
    _mode = mode;
    _rate = rate;
    final decim = (rate / outRate).round().clamp(1, 20);
    final cutoff = mode == 'wfm' ? 15e3 : 4e3;
    _f = _FirDecim(_lowpass(cutoff / rate, mode == 'wfm' ? 63 : 31), decim);
    _deemph = 0;
    _agc = null;
    _dc = 0;
  }

  /// Пакет → PCM int16 LE (24 кГц). Якщо шумодав закритий — тиша (порожньо).
  Int16List process(AudioIqPacket p, {bool squelchOpen = true}) {
    if (p.mode != _mode || p.rate != _rate) _setup(p.mode, p.rate);
    final iq = p.iq;
    final n = iq.length ~/ 2;
    final a = Float32List(n);
    if (p.mode == 'am') {
      var mean = 0.0;
      for (var k = 0; k < n; k++) {
        final i = iq[2 * k], q = iq[2 * k + 1];
        a[k] = math.sqrt(i * i + q * q);
        mean += a[k];
      }
      mean = mean / math.max(1, n) + 1e-12;
      _agc = _agc == null ? mean : 0.8 * _agc! + 0.2 * mean;
      final g = _agc!;
      for (var k = 0; k < n; k++) {
        a[k] = (a[k] - g) / (g * 1.2);
      }
    } else {
      // Частотний дискримінатор: arg(x[k]·conj(x[k−1]))
      var pi = _pi, pq = _pq;
      for (var k = 0; k < n; k++) {
        final i = iq[2 * k], q = iq[2 * k + 1];
        a[k] = math.atan2(q * pi - i * pq, i * pi + q * pq);
        pi = i;
        pq = q;
      }
      _pi = pi;
      _pq = pq;
    }
    var y = _f!.process(a);
    if (p.mode == 'wfm') {
      final alpha = 1.0 - math.exp(-1.0 / (outRate * 50e-6));
      final k = 0.8 / (2 * math.pi * 75e3 / p.rate);
      var d = _deemph;
      for (var i = 0; i < y.length; i++) {
        d += alpha * (y[i] - d);
        y[i] = d * k;
      }
      _deemph = d;
    } else if (p.mode == 'nfm') {
      for (var i = 0; i < y.length; i++) {
        y[i] = y[i] / math.pi * 2.5 * (p.rate / 48000);
      }
    }
    final out = Int16List(y.length);
    if (!squelchOpen) return Int16List(0);
    for (var i = 0; i < y.length; i++) {
      _dc += (y[i] - _dc) * 0.001; // прибрати постійну складову
      out[i] = ((y[i] - _dc) * 30000 * volume).clamp(-32767, 32767).toInt();
    }
    return out;
  }
}
