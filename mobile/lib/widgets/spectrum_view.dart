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
  final fl = List<double>.from(f.floor)..sort();
  final noise = fl.isEmpty ? -110.0 : fl[fl.length ~/ 2];
  final peak = f.bins.fold<double>(-200, math.max);
  final lo = noise - 8;
  final hi = math.max(noise + 30, peak + 5);
  return (lo, hi);
}

class SpectrumPainter extends CustomPainter {
  SpectrumPainter({
    required this.frame,
    required this.peak,
    required this.signals,
    this.showPeak = true,
    this.highlightId,
  });

  final SpectrumFrame frame;
  final Float32List? peak;
  final List<Signal> signals;
  final bool showPeak;
  final String? highlightId;

  static const leftPad = 34.0;
  static const bottomPad = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final (lo, hi) = dbRange(frame);
    final w = size.width - leftPad;
    final h = size.height - bottomPad;
    final n = frame.bins.length;
    double x(int i) => leftPad + i / (n - 1) * w;
    double y(double db) => (h * (1 - (db - lo) / (hi - lo))).clamp(0.0, h);
    double fx(double hz) => leftPad + (hz - frame.fStart) / (frame.fStop - frame.fStart) * w;

    // Сітка та шкала
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 10);
    final step = ((hi - lo) / 5 / 5).ceil() * 5.0;
    for (var db = (lo / step).ceil() * step; db < hi; db += step) {
      canvas.drawLine(Offset(leftPad, y(db)), Offset(size.width, y(db)), grid);
      _text(canvas, db.toStringAsFixed(0), Offset(2, y(db) - 6), labelStyle);
    }
    for (var k = 0; k <= 4; k++) {
      final f = frame.fStart + (frame.fStop - frame.fStart) * k / 4;
      final px = leftPad + w * k / 4;
      canvas.drawLine(Offset(px, 0), Offset(px, h), grid);
      final t = (f / 1e6).toStringAsFixed(0);
      _text(canvas, t, Offset((px - 14).clamp(leftPad, size.width - 30), h + 3), labelStyle);
    }

    // Маркери знайдених сигналів (кольорові смуги по ширині сигналу)
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

    // Рівень шуму й поріг виявлення
    final floorPath = Path();
    final thrPath = Path();
    for (var i = 0; i < frame.floor.length; i++) {
      final px = leftPad + i / (frame.floor.length - 1) * w;
      if (i == 0) {
        floorPath.moveTo(px, y(frame.floor[i]));
        thrPath.moveTo(px, y(frame.floor[i] + frame.thresholdDb));
      } else {
        floorPath.lineTo(px, y(frame.floor[i]));
        thrPath.lineTo(px, y(frame.floor[i] + frame.thresholdDb));
      }
    }

    // Спектр із заливкою
    final line = Path()..moveTo(x(0), y(frame.bins[0]));
    for (var i = 1; i < n; i++) {
      line.lineTo(x(i), y(frame.bins[i]));
    }
    final fill = Path.from(line)
      ..lineTo(x(n - 1), h)
      ..lineTo(x(0), h)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, 0), Offset(0, h), [const Color(0xAA00E5FF), const Color(0x2200E5FF)]),
    );
    if (showPeak && peak != null && peak!.length == n) {
      final pp = Path()..moveTo(x(0), y(peak![0]));
      for (var i = 1; i < n; i++) {
        pp.lineTo(x(i), y(peak![i]));
      }
      canvas.drawPath(
        pp,
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
      floorPath,
      Paint()
        ..color = Colors.white38
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      thrPath,
      Paint()
        ..color = Colors.yellowAccent.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _text(Canvas c, String s, Offset o, TextStyle st) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter old) =>
      old.frame != frame || old.signals != signals || old.highlightId != highlightId || old.showPeak != showPeak;
}

/// Водоспад: кожен рядок — один прохід спектра, новіші зверху.
class WaterfallView extends StatefulWidget {
  const WaterfallView({super.key, required this.rows, required this.frame, required this.signals});

  final List<Float32List> rows;
  final SpectrumFrame frame;
  final List<Signal> signals;

  @override
  State<WaterfallView> createState() => _WaterfallViewState();
}

class _WaterfallViewState extends State<WaterfallView> {
  ui.Image? _img;
  int _building = 0;

  @override
  void didUpdateWidget(covariant WaterfallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rebuild();
  }

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  void _rebuild() {
    final rows = widget.rows;
    if (rows.isEmpty) return;
    final width = rows.first.length;
    final height = rows.length;
    final (lo, hi) = dbRange(widget.frame);
    final px = Uint32List(width * height);
    for (var r = 0; r < height; r++) {
      final row = rows[r];
      if (row.length != width) continue;
      for (var i = 0; i < width; i++) {
        final t = (row[i] - lo) / (hi - lo);
        px[r * width + i] = _palette[(t.clamp(0.0, 1.0) * 255).toInt()];
      }
    }
    final token = ++_building;
    ui.decodeImageFromPixels(px.buffer.asUint8List(), width, height, ui.PixelFormat.rgba8888, (img) {
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
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _WaterfallPainter(_img, widget.frame, widget.signals), child: const SizedBox.expand());
  }
}

class _WaterfallPainter extends CustomPainter {
  _WaterfallPainter(this.img, this.frame, this.signals);

  final ui.Image? img;
  final SpectrumFrame frame;
  final List<Signal> signals;

  @override
  void paint(Canvas canvas, Size size) {
    const left = SpectrumPainter.leftPad;
    final w = size.width - left;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF05071A));
    if (img != null) {
      canvas.drawImageRect(
        img!,
        Rect.fromLTWH(0, 0, img!.width.toDouble(), img!.height.toDouble()),
        Rect.fromLTWH(left, 0, w, size.height),
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    final tick = Paint()..strokeWidth = 2;
    for (final s in signals.where((s) => s.active)) {
      final x = left + (s.freqHz - frame.fStart) / (frame.fStop - frame.fStart) * w;
      if (x < left || x > size.width) continue;
      tick.color = classColor(s.cls?.code);
      canvas.drawLine(Offset(x, 0), Offset(x, 10), tick);
    }
    const st = TextStyle(color: Colors.white38, fontSize: 9);
    final tp = TextPainter(
      text: const TextSpan(text: 'зараз', style: st),
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
  bool shouldRepaint(covariant _WaterfallPainter old) => old.img != img || old.signals != signals;
}
