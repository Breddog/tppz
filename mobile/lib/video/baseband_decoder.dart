import 'dart:math' as math;
import 'dart:typed_data';

/// Декодер аналогового FPV-відео НА ТЕЛЕФОНІ.
///
/// Модуль надсилає «сирий» відеосигнал — вихід ЧМ-дискримінатора, проріджений до ~3–7 Мвідл/с
/// (пакет `SDRB`, див. pi/sdrwatch/dsp/baseband.py). Тут робиться все інше:
///   * пошук рядкових і кадрових синхроімпульсів, «маховик» рядків (пропуски добудовуються);
///   * полярність (авто з підказки модуля / вручну), рівні чорного й синхро, авто-контраст;
///   * PAL / NTSC за періодом рядків;
///   * НАКОПИЧЕННЯ кадрів для слабких сигналів (шум усереднюється, картинка лишається);
///   * дескремблювання інверсії рядків і циклічного зсуву рядків;
///   * коли синхронізації немає — справжній «сніг» з ефіру (ніколи не чорний екран).
class BasebandPacket {
  BasebandPacket._(this.bits, this.flags, this.freqHz, this.fs, this.lo, this.hi, this.samples);

  /// Кольорова складова (CHRM): комплексна огинаюча на піднесучій, у тих самих одиницях, що й samples.
  Float32List? chromaRe, chromaIm;
  double chromaFs = 0, fsc = 0, chromaDelayS = 0;

  final int bits;
  final int flags;
  final double freqHz;
  final double fs;
  final double lo, hi;

  /// Відліки 0..1 (0 — нижній, 1 — верхній край девіації цього пакета).
  final Float32List samples;

  bool get piSeesVideo => flags & 1 != 0;
  bool get piInverted => flags & 2 != 0;
  bool get hasChroma => chromaRe != null;

  static const headerSize = 32;

  static BasebandPacket? parse(Uint8List b) {
    if (b.length < headerSize || b[0] != 0x53 || b[1] != 0x44 || b[2] != 0x52 || b[3] != 0x42) return null;
    final d = ByteData.sublistView(b);
    final bits = d.getUint8(5);
    final flags = d.getUint16(6, Endian.little);
    final freq = d.getFloat64(8, Endian.little);
    final fs = d.getFloat32(16, Endian.little);
    final lo = d.getFloat32(20, Endian.little);
    final hi = d.getFloat32(24, Endian.little);
    final n = d.getUint32(28, Endian.little);
    final out = Float32List(n);
    if (bits == 4) {
      const k = 1 / 15;
      for (var i = 0, j = headerSize; i < n && j < b.length; j++) {
        out[i++] = (b[j] >> 4) * k;
        if (i < n) out[i++] = (b[j] & 15) * k;
      }
    } else {
      const k = 1 / 255;
      final m = math.min(n, b.length - headerSize);
      for (var i = 0; i < m; i++) {
        out[i] = b[headerSize + i] * k;
      }
    }
    final p = BasebandPacket._(bits, flags, freq, fs, lo, hi, out);
    final off = headerSize + (bits == 4 ? (n + 1) >> 1 : n);
    if (flags & 4 != 0 && b.length >= off + 24 && b[off] == 0x43 && b[off + 1] == 0x48) {
      final cfs = d.getFloat32(off + 4, Endian.little);
      final fsc = d.getFloat32(off + 8, Endian.little);
      final cs = d.getFloat32(off + 12, Endian.little);
      final delay = d.getFloat32(off + 16, Endian.little);
      final nc = math.min(d.getUint32(off + 20, Endian.little), (b.length - off - 24) ~/ 2);
      final k = cs / math.max(hi - lo, 1.0); // Гц → частки розмаху яскравості
      final re = Float32List(nc), im = Float32List(nc);
      final raw = Int8List.sublistView(b, off + 24, off + 24 + 2 * nc);
      for (var i = 0; i < nc; i++) {
        re[i] = raw[2 * i] * k;
        im[i] = raw[2 * i + 1] * k;
      }
      p
        ..chromaRe = re
        ..chromaIm = im
        ..chromaFs = cfs
        ..fsc = fsc
        ..chromaDelayS = delay;
    }
    return p;
  }
}

class DecodedFrame {
  DecodedFrame(this.width, this.height, this.rgba, this.stats);

  final int width, height;
  final Uint8List rgba;
  final VideoStats stats;
}

class VideoStats {
  bool locked = false;
  String? standard;
  bool inverted = false;
  double syncScore = 0;
  double snrDb = 0;
  String? scrambled;
  double deviationMhz = 0;
  double afcOffsetKhz = 0;

  /// Якість кольору 0..1+ (відносна амплітуда сплеску); 0 — кадр без кольору.
  double colorQuality = 0;
}

enum Polarity { auto, normal, inverted }

class BasebandDecoder {
  Polarity polarity = Polarity.auto;
  bool autoContrast = true;
  bool descramble = true;

  /// 1 — без накопичення; 2..16 — усереднення стількох кадрів (для слабких сигналів).
  int accumulate = 1;

  /// Підсилення контрасту для слабкої картинки (1..3).
  double gain = 1.0;

  /// Колір PAL/NTSC (якщо модуль надсилає кольорову складову).
  bool color = true;
  double saturation = 1.0;

  Float32List? _acc;
  int _accW = 0, _accH = 0;
  double _lastFreq = 0;

  static const _activeStartS = 10.5e-6;
  static const _activeLenS = 52e-6;

  void resetAccumulation() => _acc = null;

  DecodedFrame decode(BasebandPacket p) {
    final fs = p.fs;
    final stats = VideoStats()
      ..deviationMhz = (p.hi - p.lo) / 1e6
      ..afcOffsetKhz = (p.hi + p.lo) / 2 / 1e3;
    if ((p.freqHz - _lastFreq).abs() > 1e5) {
      _acc = null; // інша частота — накопичене вже не про те
      _lastFreq = p.freqHz;
    }
    final inv = switch (polarity) {
      Polarity.auto => p.piInverted,
      Polarity.normal => false,
      Polarity.inverted => true,
    };
    stats.inverted = inv;
    final v = p.samples;
    if (inv) {
      for (var i = 0; i < v.length; i++) {
        v[i] = 1 - v[i];
      }
    }

    final sync = _findSync(v, fs);
    stats.syncScore = sync.score;
    Float32List img;
    int w, h;
    if (sync.score >= 0.35 && sync.period > 0) {
      stats.locked = true;
      final lineS = sync.period / fs;
      final pal = (lineS - 64e-6).abs() < (lineS - 63.556e-6).abs();
      stats.standard = pal ? 'PAL' : 'NTSC';
      final visible = pal ? 288 : 240;
      final vbi = pal ? 16 : 13;
      final fieldLines = pal ? 312 : 262;
      final lines = _flywheel(sync.starts, sync.period, v.length);
      // Початок поля: після групи широких (кадрових) імпульсів
      var first = 0;
      if (sync.broad.isNotEmpty) {
        // кінець першої групи широких імпульсів (далі — повне поле або «перемотування» по колу)
        var g = 0;
        while (g + 1 < sync.broad.length && sync.broad[g + 1] - sync.broad[g] <= sync.period * 2) {
          g++;
        }
        while (first < lines.length && lines[first] < sync.broad[g] + sync.period * 0.25) {
          first++;
        }
      }
      w = (_activeLenS * fs).round().clamp(64, 720);
      h = visible;
      img = Float32List(w * h);
      final usable = math.min(lines.length, fieldLines);
      if (usable < 32) {
        return _snow(v, fs, stats);
      }
      // Рівні: вершина синхро і задня площадка (за вибіркою рядків)
      final tips = <double>[], blanks = <double>[];
      final bpNoise = <double>[];
      for (var r = 0; r < lines.length; r += math.max(1, lines.length ~/ 40)) {
        final s = lines[r];
        final t = _at(v, s + 2.0e-6 * fs);
        if (t != null) tips.add(t);
        var sum = 0.0, sq = 0.0, cnt = 0;
        for (var x = 6.0e-6; x <= 9.4e-6; x += 0.6e-6) {
          final b = _at(v, s + x * fs);
          if (b != null) {
            sum += b;
            sq += b * b;
            cnt++;
          }
        }
        if (cnt > 2) {
          final m = sum / cnt;
          blanks.add(m);
          bpNoise.add(math.sqrt(math.max(0, sq / cnt - m * m)));
        }
      }
      final tip = _median(tips);
      final blank = _median(blanks);
      final syncH = math.max(blank - tip, 1e-4);
      stats.snrDb = 20 * math.log(syncH / (_median(bpNoise) + 1e-6)) / math.ln10;
      final scale = 0.3 / (syncH * 0.7) * gain;
      final x0 = _activeStartS * fs;
      final dx = (_activeLenS * fs) / w;
      for (var r = 0; r < h; r++) {
        // по колу всередині поля: якщо рядків після кадрового імпульсу не вистачає — беремо з початку
        final li = (first + vbi + r) % usable;
        final s = lines[li] + x0;
        final row = r * w;
        for (var x = 0; x < w; x++) {
          final pos = s + x * dx;
          final i = pos.toInt();
          if (i + 1 >= v.length) {
            img[row + x] = 0;
            continue;
          }
          final f = pos - i;
          final val = v[i] * (1 - f) + v[i + 1] * f;
          img[row + x] = (val - blank) * scale;
        }
      }
      if (descramble) stats.scrambled = _descramble(img, w, h);
      if (autoContrast) _stretch(img, onlyIfWeak: true);
      if (color && p.hasChroma && stats.scrambled == null) {
        final uv = _chroma(p, inv, pal, lines, first, vbi, usable, w, h, x0, dx, syncH, stats);
        if (uv != null) return _finish(img, w, h, stats, uv.$1, uv.$2);
      }
    } else {
      return _snow(v, fs, stats);
    }
    return _finish(img, w, h, stats);
  }

  // ---- колір ---------------------------------------------------------------------------
  /// (U, V) кожного пікселя в одиницях «1 = білий» або null, якщо сплеск слабкий / не той стандарт.
  (Float32List, Float32List)? _chroma(BasebandPacket p, bool inv, bool pal, List<double> lines, int first, int vbi,
      int usable, int w, int h, double x0, double dx, double syncH, VideoStats stats) {
    if ((p.fsc - (pal ? 4.43361875e6 : 3.579545e6)).abs() > 1e5) return null; // модуль ще не знає стандарт
    final cre = p.chromaRe!, cim = p.chromaIm!;
    final fs = p.fs, cfs = p.chromaFs, dl = p.chromaDelayS;
    final sgnInv = inv ? -1.0 : 1.0;
    double cpos(double lumaPos) => (lumaPos / fs + dl) * cfs;
    // сплеск кожного рядка (центр ~6.7 мкс після початку синхроімпульсу)
    final bre = Float64List(h), bim = Float64List(h), amps = <double>[];
    for (var r = 0; r < h; r++) {
      final li = (first + vbi + r) % usable;
      final c = cpos(lines[li] + 6.7e-6 * fs);
      final i = c.floor();
      if (i < 0 || i + 1 >= cre.length) continue;
      final f = c - i;
      bre[r] = (cre[i] * (1 - f) + cre[i + 1] * f) * sgnInv;
      bim[r] = (cim[i] * (1 - f) + cim[i + 1] * f) * sgnInv;
      amps.add(math.sqrt(bre[r] * bre[r] + bim[r] * bim[r]));
    }
    final amp = _median(amps);
    stats.colorQuality = (2 * amp / (0.5 * syncH)).clamp(0.0, 1.5);
    if (stats.colorQuality < 0.25 || amp <= 0) return null; // слабкий сплеск — чорно-білий, як у телевізорі
    final k = 0.15 / 0.7 / amp * saturation;
    final uu = Float32List(w * h), vv = Float32List(w * h);
    for (var r = 0; r < h; r++) {
      final rp = r > 0 ? r - 1 : 0;
      final a = math.atan2(bim[r], bre[r]);
      double uAxis, sgn = 1;
      if (pal) {
        // середня фаза двох сусідніх сплесків — вісь −U; сплески ±45° довкола неї, знак — V-перемикач
        final n0 = math.sqrt(bre[r] * bre[r] + bim[r] * bim[r]) + 1e-12;
        final n1 = math.sqrt(bre[rp] * bre[rp] + bim[rp] * bim[rp]) + 1e-12;
        final ax = math.atan2(bim[r] / n0 + bim[rp] / n1, bre[r] / n0 + bre[rp] / n1);
        var d = a - ax;
        d = math.atan2(math.sin(d), math.cos(d));
        sgn = d > 0 ? -1.0 : 1.0;
        uAxis = ax - math.pi;
      } else {
        uAxis = a - math.pi;
      }
      final cr = math.cos(-uAxis), ci = math.sin(-uAxis);
      final li = (first + vbi + r) % usable;
      final s = lines[li] + x0;
      final row = r * w;
      for (var x = 0; x < w; x++) {
        final c = cpos(s + x * dx);
        final i = c.floor();
        if (i < 0 || i + 1 >= cre.length) continue;
        final f = c - i;
        final zr = (cre[i] * (1 - f) + cre[i + 1] * f) * sgnInv;
        final zi = (cim[i] * (1 - f) + cim[i + 1] * f) * sgnInv;
        uu[row + x] = (zr * cr - zi * ci) * k;
        vv[row + x] = (zr * ci + zi * cr) * k * sgn;
      }
    }
    if (pal) {
      // лінія затримки PAL: середнє з попереднім рядком прибирає фазові спотворення (і «жалюзі»)
      for (var r = h - 1; r > 0; r--) {
        final a = r * w, b = a - w;
        for (var x = 0; x < w; x++) {
          uu[a + x] = (uu[a + x] + uu[b + x]) * 0.5;
          vv[a + x] = (vv[a + x] + vv[b + x]) * 0.5;
        }
      }
    }
    return (uu, vv);
  }

  // ---- сніг: растр прямо з сигналу без синхронізації -------------------------------------
  DecodedFrame _snow(Float32List v, double fs, VideoStats stats) {
    final line = (64e-6 * fs).round();
    final w = (_activeLenS * fs).round().clamp(64, 720);
    const h = 288;
    final img = Float32List(w * h);
    for (var r = 0; r < h; r++) {
      final s = r * line;
      for (var x = 0; x < w; x++) {
        final i = s + (x * line / w).floor();
        img[r * w + x] = i < v.length ? v[i] : 0;
      }
    }
    _stretch(img);
    if (gain != 1) {
      for (var i = 0; i < img.length; i++) {
        img[i] = 0.5 + (img[i] - 0.5) * gain;
      }
    }
    return _finish(img, w, h, stats);
  }

  DecodedFrame _finish(Float32List img, int w, int h, VideoStats stats, [Float32List? uu, Float32List? vv]) {
    // Накопичення (експоненційне середнє): шум падає ~√N, нерухома картинка проявляється
    if (accumulate > 1) {
      if (_acc == null || _accW != w || _accH != h) {
        _acc = Float32List.fromList(img);
        _accW = w;
        _accH = h;
      } else {
        final a = 1 / accumulate;
        final acc = _acc!;
        for (var i = 0; i < img.length; i++) {
          acc[i] += (img[i] - acc[i]) * a;
        }
        img = acc;
      }
    } else {
      _acc = null;
    }
    final rgba = Uint8List(w * h * 4);
    if (uu != null && vv != null) {
      for (var i = 0, j = 0; i < img.length; i++, j += 4) {
        final y = img[i];
        final ry = vv[i] / 0.877, by = uu[i] / 0.493;
        final gy = -0.509 * ry - 0.194 * by;
        rgba[j] = ((y + ry) * 255).clamp(0, 255).toInt();
        rgba[j + 1] = ((y + gy) * 255).clamp(0, 255).toInt();
        rgba[j + 2] = ((y + by) * 255).clamp(0, 255).toInt();
        rgba[j + 3] = 255;
      }
      return DecodedFrame(w, h, rgba, stats);
    }
    for (var i = 0, j = 0; i < img.length; i++, j += 4) {
      final g = (img[i] * 255).clamp(0, 255).toInt();
      rgba[j] = g;
      rgba[j + 1] = g;
      rgba[j + 2] = g;
      rgba[j + 3] = 255;
    }
    return DecodedFrame(w, h, rgba, stats);
  }

  // ---- синхронізація ---------------------------------------------------------------------
  _Sync _findSync(Float32List u, double fs) {
    final sub = <double>[];
    for (var i = 0; i < u.length; i += 16) {
      sub.add(u[i]);
    }
    sub.sort();
    if (sub.length < 100) return _Sync.none;
    final lo = sub[(sub.length * 0.01).floor()];
    final hi = sub[(sub.length * 0.99).floor()];
    final rng = math.max(hi - lo, 1e-6);
    final th = lo + 0.15 * rng;
    final starts = <double>[];
    final broad = <double>[];
    final minW = 3.0e-6 * fs, maxW = 6.5e-6 * fs, broadW = 18e-6 * fs;
    var inRun = false;
    var runStart = 0.0;
    for (var i = 1; i < u.length; i++) {
      final b = u[i] < th;
      if (b && !inRun) {
        inRun = true;
        final a = u[i - 1], c = u[i];
        final f = (a - c).abs() < 1e-9 ? 0.0 : ((a - th) / (a - c)).clamp(0.0, 1.0);
        runStart = (i - 1) + f;
      } else if (!b && inRun) {
        inRun = false;
        final wdt = i - runStart;
        if (wdt > minW && wdt < maxW) {
          starts.add(runStart);
        } else if (wdt > broadW) {
          broad.add(runStart);
        }
      }
    }
    if (starts.length < 8) return _Sync(0, starts, broad, 0);
    final good = <double>[];
    var total = 0;
    for (var i = 1; i < starts.length; i++) {
      final d = (starts[i] - starts[i - 1]) / fs;
      total++;
      if (d > 60e-6 && d < 68e-6) good.add(starts[i] - starts[i - 1]);
    }
    if (good.isEmpty) return _Sync(0, starts, broad, 0);
    final period = _median(good);
    // Окрім регулярності — синхроімпульсів має бути багато (а не кілька випадкових сплесків)
    final expected = u.length / period;
    final fill = (starts.length / expected).clamp(0.0, 1.0);
    final score = good.length / total * math.min(1.0, fill * 1.4);
    return _Sync(score, starts, broad, period);
  }

  List<double> _flywheel(List<double> starts, double period, int total) {
    if (starts.isEmpty || period <= 0) return const [];
    final tol = period * 0.03;
    final out = <double>[starts.first];
    var t = starts.first;
    var j = 0;
    while (t + period * 1.01 < total) {
      final pred = t + period;
      while (j < starts.length && starts[j] < pred - tol) {
        j++;
      }
      if (j < starts.length && (starts[j] - pred).abs() <= tol) {
        t = 0.7 * starts[j] + 0.3 * pred;
      } else {
        t = pred;
      }
      out.add(t);
    }
    return out;
  }

  // ---- дескремблювання -------------------------------------------------------------------
  String? _descramble(Float32List img, int w, int h) {
    // Рядки без середнього + їхні норми — рахуються один раз (зсув не змінює ні середнє, ні норму)
    final z = Float32List(w * h);
    final norm = Float64List(h);
    void prep(int r) {
      var m = 0.0;
      for (var x = 0; x < w; x++) {
        m += img[r * w + x];
      }
      m /= w;
      var n = 0.0;
      for (var x = 0; x < w; x++) {
        final d = img[r * w + x] - m;
        z[r * w + x] = d;
        n += d * d;
      }
      norm[r] = math.sqrt(n);
    }

    for (var r = 0; r < h; r++) {
      prep(r);
    }
    double corr(int a, int b, [int shift = 0]) {
      final den = norm[a] * norm[b];
      if (den < 1e-9) return 1.0;
      var s = 0.0;
      final ra = a * w, rb = b * w;
      for (var x = 0; x < w; x++) {
        var k = x + shift;
        if (k >= w) k -= w;
        s += z[ra + x] * z[rb + k];
      }
      return s / den;
    }

    final cs = <double>[];
    for (var r = 0; r + 1 < h; r += 8) {
      cs.add(corr(r, r + 1));
    }
    final med = _median(cs);
    if (med > 0.45) return null; // звичайне відео: сусідні рядки схожі
    final absMed = _median([for (final c in cs) c.abs()]);
    if (absMed > 0.7) {
      // інверсія окремих рядків
      for (var r = 1; r < h; r++) {
        if (corr(r - 1, r) < 0) {
          for (var x = 0; x < w; x++) {
            img[r * w + x] = 1 - img[r * w + x];
          }
          prep(r);
        }
      }
      return 'line_invert';
    }
    // циклічний зсув рядків: грубий пошук зсуву за 48 положеннями
    const steps = 48;
    var gainSum = 0.0;
    final tmp = Float32List(w);
    for (var r = 1; r < h; r++) {
      var best = 0, bestC = -2.0;
      for (var k = 0; k < steps; k++) {
        final sh = k * w ~/ steps;
        final c = corr(r - 1, r, sh);
        if (c > bestC) {
          bestC = c;
          best = sh;
        }
      }
      // уточнення з точністю до пікселя довкола грубого максимуму
      final c0 = best;
      for (var d = -(w ~/ steps); d <= w ~/ steps; d++) {
        final sh = (c0 + d + w) % w;
        final c = corr(r - 1, r, sh);
        if (c > bestC) {
          bestC = c;
          best = sh;
        }
      }
      gainSum += bestC;
      if (best != 0) {
        for (var x = 0; x < w; x++) {
          tmp[x] = img[r * w + (x + best) % w];
        }
        img.setRange(r * w, r * w + w, tmp);
        prep(r);
      }
    }
    return gainSum / h > 0.6 ? 'rotate' : 'unknown';
  }

  // ---- допоміжне -------------------------------------------------------------------------
  static double? _at(Float32List v, double pos) {
    final i = pos.toInt();
    if (i < 0 || i + 1 >= v.length) return null;
    final f = pos - i;
    return v[i] * (1 - f) + v[i + 1] * f;
  }

  static double _median(List<double> x) {
    if (x.isEmpty) return 0;
    final s = [...x]..sort();
    return s[s.length ~/ 2];
  }

  static void _stretch(Float32List img, {bool onlyIfWeak = false}) {
    final sub = <double>[];
    for (var i = 0; i < img.length; i += 13) {
      sub.add(img[i]);
    }
    sub.sort();
    final lo = sub[(sub.length * 0.02).floor()];
    final hi = sub[(sub.length * 0.98).floor()];
    final span = hi - lo;
    if (span < 1e-6) return;
    if (onlyIfWeak && (span > 0.47 || span < 0.03)) return;
    final k = (onlyIfWeak ? 0.9 : 1.0) / span;
    final b = onlyIfWeak ? 0.05 : 0.0;
    for (var i = 0; i < img.length; i++) {
      img[i] = (img[i] - lo) * k + b;
    }
  }
}

class _Sync {
  const _Sync(this.score, this.starts, this.broad, this.period);

  static const none = _Sync(0, [], [], 0);

  final double score;
  final List<double> starts;
  final List<double> broad;
  final double period;
}
