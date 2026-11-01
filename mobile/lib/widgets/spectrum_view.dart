import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models.dart';

/// Палітра водоспаду (темно-синій → блакитний → жовтий → червоний), 256 кольорів RGBA.
final Uint32List _palette = () {
  const stops = [
    [0.00, 0x05, 0x07, 0x1a],
    [0.20, 0x10, 0x2a, 0x7a],
    [0.40, 0x00, 0x8f, 0xc8],
    [0.60, 0x3d, 0xd6, 0x8c],
    [0.78, 0xf5, 0xe1, 0x3b],
    [0.90, 0xff, 0x7b, 0x1c],
    [1.00, 0xff, 0x1d, 0x48],
  ];
  final out = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    final t = i / 255;
    var k = 0;
    while (k < stops.length - 2 && t > (stops[k + 1][0] as double)) {
      k++;
    }
    final a = stops[k], b = stops[k + 1];
    final f = ((t - (a[0] as double)) / ((b[0] as double) - (a[0] as double))).clamp(0.0, 1.0);
    int ch(int j) => ((a[j] as int) + ((b[j] as int) - (a[j] as int)) * f).round();
    // RGBA у порядку байтів little-endian: A B G R
    out[i] = (0xff << 24) | (ch(3) << 16) | (ch(2) << 8) | ch(1);
  }
  return out;
}();

Color paletteColor(double t) {
  final v = _palette[(t.clamp(0.0, 1.0) * 255).round()];
  return Color.fromARGB(255, v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff);
}

/// Діапазон шкали дБ: від шуму до найсильнішого піку.
(double, double) dbRange(SpectrumFrame f) {
  final fl = Float32List.fromList(f.floor)..sort();
  final noise = fl.isEmpty ? -110.0 : fl[fl.length ~/ 2];
  var peak = -200.0;
  for (final v in f.bins) {
    if (v > peak) peak = v;
  }
  final lo = noise - 8;
  final hi = math.max(noise + 30, peak + 5);
  return (lo, hi);
}

String fmtMhz(double hz, double span) {
  final mhz = hz / 1e6;
  final dec = span < 2e6 ? 3 : (span < 20e6 ? 2 : (span < 200e6 ? 1 : 0));
  return mhz.toStringAsFixed(dec);
}

/// Спектр. [lo]/[hi] — видима ділянка (масштаб), за замовчуванням — увесь кадр.
/// Якщо є [zoom]-кадр, що покриває ділянку, малюється він (вища деталізація).
class SpectrumPainter extends CustomPainter {
  SpectrumPainter({
    required this.frame,
    required this.peak,
    required this.signals,
    this.showPeak = true,
    this.highlightId,
    this.lo,
    this.hi,
    this.zoom,
    this.marker,
    this.repaint,
  }) : super(repaint: repaint);

  final SpectrumFrame frame;
  final Float32List? peak;
  final List<Signal> signals;
  final bool showPeak;
  final String? highlightId;
  final double? lo, hi;
  final SpectrumFrame? zoom;
  final double? marker;
  final Listenable? repaint;

  static const leftPad = 34.0;
  static const bottomPad = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final vLo = lo ?? frame.fStart, vHi = hi ?? frame.fStop;
    final z = zoom;
    // Збільшений кадр — лише свіжий (≤3 с від огляду) і такий, що покриває видиму ділянку
    final useZoom =
        z != null &&
        (frame.ts - z.ts).abs() < 3 &&
        z.fStart <= vLo + (vHi - vLo) * 0.02 &&
        z.fStop >= vHi - (vHi - vLo) * 0.02;
    final f = useZoom ? z : frame;
    final (dLo, dHi) = dbRange(frame);
    final w = size.width - leftPad;
    final h = size.height - bottomPad;
    double y(double db) => (h * (1 - (db - dLo) / (dHi - dLo))).clamp(0.0, h);
    double fx(double hz) => leftPad + (hz - vLo) / (vHi - vLo) * w;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    // Сітка та шкала
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 10);
    final step = ((dHi - dLo) / 5 / 5).ceil() * 5.0;
    for (var db = (dLo / step).ceil() * step; db < dHi; db += step) {
      canvas.drawLine(Offset(leftPad, y(db)), Offset(size.width, y(db)), grid);
      _text(canvas, db.toStringAsFixed(0), Offset(2, y(db) - 6), labelStyle);
    }
    for (var k = 0; k <= 4; k++) {
      final hz = vLo + (vHi - vLo) * k / 4;
      final px = leftPad + w * k / 4;
      canvas.drawLine(Offset(px, 0), Offset(px, h), grid);
      _text(canvas, fmtMhz(hz, vHi - vLo), Offset((px - 16).clamp(leftPad, size.width - 44), h + 3), labelStyle);
    }

    // Маркери знайдених сигналів
    for (final s in signals) {
      final c = s.cls;
      final a = fx(s.freqHz - s.bandwidthHz / 2), b = fx(s.freqHz + s.bandwidthHz / 2);
      if (b < leftPad || a > size.width) continue;
      final col = classColor(c?.code);
      final hl = s.id == highlightId;
      canvas.drawRect(
        Rect.fromLTRB(a.clamp(leftPad, size.width), 0, b.clamp(leftPad, size.width), h),
        Paint()..color = col.withValues(alpha: hl ? 0.28 : (s.active ? 0.14 : 0.05)),
      );
      final label = s.channelName.isNotEmpty ? s.channelName : (c == null ? '?' : (kClassNames[c.code] ?? ''));
      _text(
        canvas,
        label,
        Offset(((a + b) / 2 - 12).clamp(leftPad, size.width - 40), 2),
        TextStyle(color: col, fontSize: 10, fontWeight: FontWeight.bold),
      );
    }

    // Лінії по пікселях: для кожного стовпця — максимум бінів (швидко навіть для 2048+ точок)
    final cols = w.floor().clamp(2, 4000);
    Path series(Float32List data, {bool fill = false, double add = 0, bool mean = false}) {
      final p = Path();
      final n = data.length;
      var started = false;
      for (var c = 0; c < cols; c++) {
        final hz0 = vLo + (vHi - vLo) * c / cols, hz1 = vLo + (vHi - vLo) * (c + 1) / cols;
        var i0 = ((hz0 - f.fStart) / (f.fStop - f.fStart) * (n - 1)).floor();
        var i1 = ((hz1 - f.fStart) / (f.fStop - f.fStart) * (n - 1)).ceil();
        if (i1 < 0 || i0 > n - 1) continue;
        i0 = i0.clamp(0, n - 1);
        i1 = i1.clamp(i0, n - 1);
        var v = mean ? 0.0 : -999.0;
        for (var i = i0; i <= i1; i++) {
          if (mean) {
            v += data[i];
          } else if (data[i] > v) {
            v = data[i];
          }
        }
        if (mean) v /= (i1 - i0 + 1);
        final px = leftPad + c * w / cols, py = y(v + add);
        if (!started) {
          p.moveTo(px, py);
          started = true;
        } else {
          p.lineTo(px, py);
        }
      }
      if (fill) {
        p
          ..lineTo(leftPad + w, h)
          ..lineTo(leftPad, h)
          ..close();
      }
      return p;
    }

    final line = series(f.bins);
    final fillPath = series(f.bins, fill: true);
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h), [const Color(0xAA00E5FF), const Color(0x2200E5FF)]),
    );
    if (showPeak && peak != null && peak!.length == frame.bins.length && !useZoom) {
      canvas.drawPath(
        series(peak!),
        Paint()
          ..color = Colors.orangeAccent.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.drawPath(
      series(f.floor, mean: true),
      Paint()
        ..color = Colors.white38
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      series(f.floor, mean: true, add: f.thresholdDb),
      Paint()
        ..color = Colors.yellowAccent.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    if (marker != null && marker! >= vLo && marker! <= vHi) {
      final mx = fx(marker!);
      canvas.drawLine(
        Offset(mx, 0),
        Offset(mx, h),
        Paint()
          ..color = Colors.redAccent
          ..strokeWidth = 1.5,
      );
      final i = f.indexOf(marker!).clamp(0, f.bins.length - 1);
      _text(
        canvas,
        '${fmtMhz(marker!, 1e5)} МГц  ${f.bins[i].toStringAsFixed(0)} дБ',
        Offset((mx + 4).clamp(leftPad, size.width - 150), 14),
        const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
      );
    }
    if (useZoom) {
      _text(
        canvas,
        'деталізація ×${((frame.fStop - frame.fStart) / (z.fStop - z.fStart)).toStringAsFixed(0)}',
        Offset(leftPad + 4, h - 14),
        const TextStyle(color: Colors.white38, fontSize: 10),
      );
    }
    canvas.restore();
  }

  void _text(Canvas c, String s, Offset o, TextStyle st) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter old) => true;
}

/// Водоспад: кожен рядок — один прохід спектра, новіші зверху.
/// Зображення оновлюється ПОРЯДКОВО (новий рядок фарбується, решта лише зсувається),
/// а не перемальовується цілком на кожен кадр.
class WaterfallView extends StatefulWidget {
  const WaterfallView({
    super.key,
    required this.rows,
    required this.frame,
    required this.signals,
    this.lo,
    this.hi,
    this.rowOffset = 0,
    this.visibleRows = 220,
    this.repaint,
  });

  final List<Float32List> rows;
  final SpectrumFrame frame;
  final List<Signal> signals;
  final double? lo, hi;

  /// Прокрутка назад у часі: скільки найновіших рядків пропустити.
  final int rowOffset;
  final int visibleRows;
  final Listenable? repaint;

  @override
  State<WaterfallView> createState() => _WaterfallViewState();
}

class _WaterfallViewState extends State<WaterfallView> {
  ui.Image? _img;
  Uint32List? _px;
  int _w = 0, _h = 0;
  Float32List? _lastTop;
  double _lo = 0, _hi = 1;
  int _building = 0;

  @override
  void initState() {
    super.initState();
    widget.repaint?.addListener(_update);
    _update();
  }

  @override
  void didUpdateWidget(covariant WaterfallView old) {
    super.didUpdateWidget(old);
    if (old.repaint != widget.repaint) {
      old.repaint?.removeListener(_update);
      widget.repaint?.addListener(_update);
    }
    if (old.rowOffset != widget.rowOffset || old.visibleRows != widget.visibleRows || old.rows != widget.rows) {
      _px = null; // повне перемальовування
    }
    _update();
  }

  @override
  void dispose() {
    widget.repaint?.removeListener(_update);
    _img?.dispose();
    super.dispose();
  }

  void _paintRow(Float32List row, int r) {
    final px = _px!;
    final k = 255 / (_hi - _lo);
    final base = r * _w;
    for (var i = 0; i < _w; i++) {
      final t = (row[i] - _lo) * k;
      px[base + i] = _palette[t < 0 ? 0 : (t > 255 ? 255 : t.toInt())];
    }
  }

  void _update() {
    final rows = widget.rows;
    if (rows.isEmpty || !mounted) return;
    final width = rows.first.length;
    final int start = widget.rowOffset.clamp(0, math.max(0, rows.length - 1)).toInt();
    final height = math.min(widget.visibleRows, rows.length - start);
    if (height <= 0) return;
    final (lo, hi) = dbRange(widget.frame);
    // Шкала змінилась помітно — перефарбувати все; інакше лише новий рядок
    final rescale = (lo - _lo).abs() > 4 || (hi - _hi).abs() > 4;
    if (_px == null || _w != width || _h != height || rescale || widget.rowOffset > 0) {
      _w = width;
      _h = height;
      _lo = lo;
      _hi = hi;
      _px = Uint32List(width * height);
      for (var r = 0; r < height; r++) {
        if (rows[start + r].length == width) _paintRow(rows[start + r], r);
      }
    } else if (!identical(rows.first, _lastTop)) {
      // новий рядок: зсунути все на рядок униз і пофарбувати верхній
      final px = _px!;
      px.setRange(width, width * height, px, 0);
      _paintRow(rows.first, 0);
    } else {
      return;
    }
    _lastTop = rows.first;
    final token = ++_building;
    ui.decodeImageFromPixels(Uint8List.sublistView(_px!), width, height, ui.PixelFormat.rgba8888, (img) {
      if (!mounted || token != _building) {
        img.dispose();
        return;
      }
      setState(() {
        _img?.dispose();
        _img = img;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WaterfallPainter(_img, widget.frame, widget.signals, widget.lo, widget.hi, widget.rowOffset),
      child: const SizedBox.expand(),
    );
  }
}

class _WaterfallPainter extends CustomPainter {
  _WaterfallPainter(this.img, this.frame, this.signals, this.lo, this.hi, this.rowOffset);

  final ui.Image? img;
  final SpectrumFrame frame;
  final List<Signal> signals;
  final double? lo, hi;
  final int rowOffset;

  @override
  void paint(Canvas canvas, Size size) {
    const left = SpectrumPainter.leftPad;
    final w = size.width - left;
    final vLo = lo ?? frame.fStart, vHi = hi ?? frame.fStop;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF05071A));
    if (img != null) {
      // Видима ділянка — відповідні стовпці зображення
      final span = frame.fStop - frame.fStart;
      final sx0 = ((vLo - frame.fStart) / span * img!.width).clamp(0.0, img!.width.toDouble());
      final sx1 = ((vHi - frame.fStart) / span * img!.width).clamp(0.0, img!.width.toDouble());
      if (sx1 > sx0) {
        final dx0 = left + (frame.fStart + sx0 / img!.width * span - vLo) / (vHi - vLo) * w;
        final dx1 = left + (frame.fStart + sx1 / img!.width * span - vLo) / (vHi - vLo) * w;
        canvas.drawImageRect(
          img!,
          Rect.fromLTRB(sx0, 0, sx1, img!.height.toDouble()),
          Rect.fromLTRB(dx0, 0, dx1, size.height),
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    }
    final tick = Paint()..strokeWidth = 2;
    for (final s in signals.where((s) => s.active)) {
      final x = left + (s.freqHz - vLo) / (vHi - vLo) * w;
      if (x < left || x > size.width) continue;
      tick.color = classColor(s.cls?.code);
      canvas.drawLine(Offset(x, 0), Offset(x, 10), tick);
    }
    const st = TextStyle(color: Colors.white38, fontSize: 9);
    final tp = TextPainter(
      text: TextSpan(text: rowOffset > 0 ? '−$rowOffset рядків (потягніть угору — до «зараз»)' : 'зараз', style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(2, 2));
    final tp2 = TextPainter(
      text: const TextSpan(text: 'раніше', style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(2, size.height - 12));
  }

  @override
  bool shouldRepaint(covariant _WaterfallPainter old) => true;
}
