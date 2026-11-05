import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../live.dart';

/// «Пеленг»: пошук напрямку на джерело спрямованою антеною (як «полювання на лиса»).
///
/// Модуль стежить за частотою, телефон показує рівень сигналу великим індикатором і пищить тоном,
/// що вищає зі зростанням рівня. Повільно обертайте антену — напрямок там, де рівень/тон максимальні.
class DfScreen extends StatefulWidget {
  const DfScreen({super.key, required this.api, required this.freqHz});

  final ApiClient api;
  final double freqHz;

  @override
  State<DfScreen> createState() => _DfScreenState();
}

class _DfScreenState extends State<DfScreen> {
  double _bw = 8e6;
  bool _tone = true;
  double? _level, _noise, _peak;
  final List<(DateTime, double)> _hist = [];
  LiveConnection? _live;
  int _phase = 0;
  bool _pcm = false;

  @override
  void initState() {
    super.initState();
    widget.api.watch(freqHz: widget.freqHz).catchError((_) {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _live = context.read<LiveConnection>();
      _live!.spectrumTick.addListener(_onTick);
    });
    _initPcm();
  }

  Future<void> _initPcm() async {
    try {
      await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(2400);
      FlutterPcmSound.setFeedCallback(_feed);
      _pcm = true;
      _feed(0);
    } catch (_) {
      _pcm = false;
    }
  }

  /// Тон: висота 300…1800 Гц за рівнем над шумом, короткі «біпи» частіше при сильнішому сигналі.
  void _feed(int remaining) {
    if (!mounted || !_pcm) return;
    final snr = (_level != null && _noise != null) ? (_level! - _noise!).clamp(0.0, 50.0) : 0.0;
    final f = 300 + snr * 30;
    final out = Int16List(2400); // 100 мс
    if (_tone && snr > 3) {
      final duty = 0.35 + snr / 100;
      for (var i = 0; i < out.length; i++) {
        final on = (i / out.length) < duty;
        out[i] = on ? (math.sin(2 * math.pi * f * (_phase + i) / 24000) * 9000).toInt() : 0;
      }
    }
    _phase += out.length;
    FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.sublistView(out)));
  }

  void _onTick() {
    final l = _live;
    if (l == null || !mounted) return;
    final hz = widget.freqHz;
    // кадр, що містить частоту: спершу стеження (-1), потім будь-який діапазон
    for (final f
        in l.spectra.values.toList()..sort((a, b) => (a.range == -1 ? -1 : 1).compareTo(b.range == -1 ? -1 : 1))) {
      if (hz < f.fStart || hz > f.fStop) continue;
      final i0 = f.indexOf(hz - _bw / 2).clamp(0, f.bins.length - 1);
      final i1 = f.indexOf(hz + _bw / 2).clamp(0, f.bins.length - 1);
      var m = -200.0;
      for (var i = i0; i <= i1; i++) {
        if (f.bins[i] > m) m = f.bins[i];
      }
      final fl = List<double>.from(f.floor)..sort();
      setState(() {
        _level = m;
        _noise = fl[fl.length ~/ 2];
        if (_peak == null || m > _peak!) {
          _peak = m;
          HapticFeedback.lightImpact();
        }
        _hist.add((DateTime.now(), m));
        _hist.removeWhere((e) => DateTime.now().difference(e.$1).inSeconds > 30);
      });
      break;
    }
  }

  @override
  void dispose() {
    _live?.spectrumTick.removeListener(_onTick);
    _pcm = false;
    FlutterPcmSound.setFeedCallback(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snr = (_level != null && _noise != null) ? _level! - _noise! : null;
    final t = ((snr ?? 0) / 50).clamp(0.0, 1.0);
    final pk = (_peak != null && _noise != null) ? ((_peak! - _noise!) / 50).clamp(0.0, 1.0) : 0.0;
    return Scaffold(
      appBar: AppBar(title: Text('Пеленг · ${(widget.freqHz / 1e6).toStringAsFixed(3)} МГц')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Text(
              snr == null ? '—' : '${snr.toStringAsFixed(1)} дБ',
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: Color.lerp(Colors.lightBlueAccent, Colors.redAccent, t),
              ),
            ),
          ),
          Center(
            child: Text(
              'над шумом${_level == null ? '' : ' · рівень ${_level!.toStringAsFixed(1)} дБ'}',
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (_, c) => SizedBox(
              height: 36,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: c.maxWidth * t,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Colors.lightBlueAccent, Colors.yellowAccent, Colors.redAccent],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  Positioned(
                    left: c.maxWidth * pk - 2,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 4, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                _peak == null || _noise == null
                    ? 'Максимум: —'
                    : 'Максимум: ${(_peak! - _noise!).toStringAsFixed(1)} дБ',
                style: const TextStyle(color: Colors.white70),
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.restart_alt),
                label: const Text('Скинути'),
                onPressed: () => setState(() {
                  _peak = null;
                }),
              ),
            ],
          ),
          SizedBox(height: 120, child: CustomPaint(painter: _HistPainter(_hist, _noise))),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Звуковий тон (вищає зі зростанням сигналу)'),
            value: _tone,
            onChanged: (v) => setState(() => _tone = v),
          ),
          const Text('Смуга, в якій міряти рівень'),
          const SizedBox(height: 6),
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 25e3, label: Text('25 кГц')),
              ButtonSegment(value: 200e3, label: Text('200 кГц')),
              ButtonSegment(value: 2e6, label: Text('2 МГц')),
              ButtonSegment(value: 8e6, label: Text('8 МГц')),
            ],
            selected: {_bw},
            onSelectionChanged: (v) => setState(() {
              _bw = v.first;
              _peak = null;
            }),
          ),
          const SizedBox(height: 12),
          Text(
            'Підключіть до модуля спрямовану антену (панель, Яги, «хвильовий канал») і повільно обертайте її. '
            'Напрямок на джерело — там, де рівень і тон максимальні (біла риска — найкраще значення). '
            'Підходьте ближче — і повторюйте: так звужується зона пошуку.',
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _HistPainter extends CustomPainter {
  _HistPainter(this.hist, this.noise);

  final List<(DateTime, double)> hist;
  final double? noise;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF10141C),
    );
    if (hist.length < 2 || noise == null) return;
    final now = DateTime.now();
    final p = Path();
    for (var i = 0; i < hist.length; i++) {
      final x = size.width * (1 - now.difference(hist[i].$1).inMilliseconds / 30000);
      final y = size.height * (1 - ((hist[i].$2 - noise!) / 50).clamp(0.0, 1.0));
      i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
    }
    canvas.drawPath(
      p,
      Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _HistPainter old) => true;
}
