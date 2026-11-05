import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../models.dart';

/// Частотна лінійка як на шкалі радіоприймача: тягніть пальцем — частота «пливе» під червоною
/// рискою. Під шкалою — живий спектр навколо частоти (видно, де є сигнали).
class FrequencyRuler extends StatefulWidget {
  const FrequencyRuler({
    super.key,
    required this.freqHz,
    required this.stepHz,
    required this.onChanged,
    this.spanHz = 1.0e6,
    this.spectrum,
  });

  final double freqHz;
  final double stepHz;
  final double spanHz;
  final SpectrumFrame? spectrum;
  final ValueChanged<double> onChanged;

  @override
  State<FrequencyRuler> createState() => _FrequencyRulerState();
}

class _FrequencyRulerState extends State<FrequencyRuler> with SingleTickerProviderStateMixin {
  late final AnimationController _fling = AnimationController.unbounded(vsync: this);
  double _acc = 0;
  double _width = 1;

  double get _hzPerPx => widget.spanHz / _width;

  @override
  void initState() {
    super.initState();
    _fling.addListener(() {
      _move(-(_fling.value - _lastFling));
      _lastFling = _fling.value;
    });
  }

  double _lastFling = 0;

  @override
  void dispose() {
    _fling.dispose();
    super.dispose();
  }

  void _move(double dx) {
    _acc += dx * _hzPerPx;
    final steps = (_acc / widget.stepHz).truncate();
    if (steps != 0) {
      _acc -= steps * widget.stepHz;
      HapticFeedback.selectionClick();
      widget.onChanged(_snap(widget.freqHz + steps * widget.stepHz));
    }
  }

  double _snap(double hz) => (hz / widget.stepHz).round() * widget.stepHz;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        _width = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _fling.stop(),
          onHorizontalDragUpdate: (d) => _move(-d.delta.dx),
          onHorizontalDragEnd: (d) {
            _lastFling = 0;
            _fling.animateWith(FrictionSimulation(0.02, 0, d.velocity.pixelsPerSecond.dx.clamp(-4000, 4000)));
          },
          onTapUp: (d) {
            // дотик — перейти на цю точку шкали
            final hz = widget.freqHz + (d.localPosition.dx - _width / 2) * _hzPerPx;
            HapticFeedback.selectionClick();
            widget.onChanged(_snap(hz));
          },
          child: CustomPaint(
            painter: _RulerPainter(widget.freqHz, widget.spanHz, widget.stepHz, widget.spectrum),
            child: const SizedBox(height: 110, width: double.infinity),
          ),
        );
      },
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.f, this.span, this.step, this.spec);

  final double f, span, step;
  final SpectrumFrame? spec;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      Paint()..color = const Color(0xFF10141C),
    );
    final lo = f - span / 2;
    double x(double hz) => (hz - lo) / span * w;

    // Спектр навколо частоти
    final s = spec;
    if (s != null && s.bins.isNotEmpty) {
      final dLo = (s.floor.isEmpty ? -110.0 : s.floor[s.floor.length ~/ 2]) - 5;
      final top = topDb(s);
      final path = Path()..moveTo(0, h);
      for (var px = 0; px <= w; px += 2) {
        final hz = lo + px / w * span;
        final i = s.indexOf(hz);
        if (i < 0 || i >= s.bins.length) continue;
        final v = ((s.bins[i] - dLo) / (top - dLo)).clamp(0.0, 1.0);
        path.lineTo(px.toDouble(), h - 6 - v * (h * 0.55));
      }
      path
        ..lineTo(w, h)
        ..close();
      canvas.drawPath(path, Paint()..color = const Color(0x5500E5FF));
    }

    // Поділки
    final major = _niceStep(span / 5);
    final minor = major / 5;
    final tick = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    final tickMajor = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5;
    for (var t = (lo / minor).ceil() * minor; t <= lo + span; t += minor) {
      final isMajor = ((t / major).round() * major - t).abs() < minor / 10;
      canvas.drawLine(Offset(x(t), 0), Offset(x(t), isMajor ? 22 : 11), isMajor ? tickMajor : tick);
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(
            text: _label(t, major),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x(t) - tp.width / 2, 25));
      }
    }
    // Центральна риска
    canvas.drawLine(
      Offset(w / 2, 0),
      Offset(w / 2, h),
      Paint()
        ..color = Colors.redAccent
        ..strokeWidth = 2,
    );
    // Ширина кроку (смуга каналу)
    final cw = math.max(2.0, step / span * w);
    canvas.drawRect(
      Rect.fromCenter(center: Offset(w / 2, h / 2 + 10), width: cw, height: h - 20),
      Paint()..color = const Color(0x22FF5252),
    );
  }

  static double topDb(SpectrumFrame s) {
    var m = -200.0;
    for (final v in s.bins) {
      if (v > m) m = v;
    }
    final fl = s.floor.isEmpty ? -110.0 : s.floor[s.floor.length ~/ 2];
    return math.max(m + 3, fl + 25);
  }

  static double _niceStep(double raw) {
    final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final k in [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (k * p >= raw) return k * p;
    }
    return 10 * p;
  }

  static String _label(double hz, double major) {
    final mhz = hz / 1e6;
    final dec = major >= 1e6 ? 0 : (major >= 1e5 ? 1 : (major >= 1e4 ? 2 : 3));
    return mhz.toStringAsFixed(dec);
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.f != f || old.span != span || old.step != step || old.spec != spec;
}

/// Колесо налаштування: крутіть пальцем — кожні [degPerStep] градусів = один крок частоти.
class TuningKnob extends StatefulWidget {
  const TuningKnob({super.key, required this.onSteps, this.size = 150, this.degPerStep = 12});

  final void Function(int steps) onSteps;
  final double size;
  final double degPerStep;

  @override
  State<TuningKnob> createState() => _TuningKnobState();
}

class _TuningKnobState extends State<TuningKnob> {
  double _angle = 0;
  double _acc = 0;
  double? _last;

  double _angleOf(Offset p) {
    final c = Offset(widget.size / 2, widget.size / 2);
    return math.atan2(p.dy - c.dy, p.dx - c.dx);
  }

  void _update(Offset p) {
    final a = _angleOf(p);
    if (_last != null) {
      var d = a - _last!;
      if (d > math.pi) d -= 2 * math.pi;
      if (d < -math.pi) d += 2 * math.pi;
      setState(() => _angle += d);
      _acc += d * 180 / math.pi;
      final steps = (_acc / widget.degPerStep).truncate();
      if (steps != 0) {
        _acc -= steps * widget.degPerStep;
        HapticFeedback.selectionClick();
        widget.onSteps(steps);
      }
    }
    _last = a;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => _last = _angleOf(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _last = null,
      child: CustomPaint(size: Size.square(widget.size), painter: _KnobPainter(_angle)),
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter(this.angle);

  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(colors: [Color(0xFF3A4252), Color(0xFF1A1F29)])
            .createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // рифлення
    final rib = Paint()
      ..color = Colors.white24
      ..strokeWidth = 2;
    for (var k = 0; k < 36; k++) {
      final a = angle + k * math.pi / 18;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * (r - 10),
        c + Offset(math.cos(a), math.sin(a)) * (r - 3),
        rib,
      );
    }
    // мітка-«пальчик»
    final a = angle - math.pi / 2;
    canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (r * 0.62), r * 0.11, Paint()..color = Colors.cyanAccent);
    canvas.drawCircle(c, r * 0.18, Paint()..color = const Color(0xFF12161E));
  }

  @override
  bool shouldRepaint(covariant _KnobPainter old) => old.angle != angle;
}
