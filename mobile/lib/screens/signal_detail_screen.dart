import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/signal_widgets.dart';

/// Деталі сигналу: класифікація, канал за сіткою, приблизна відстань, історія RSSI.
class SignalDetailScreen extends StatefulWidget {
  const SignalDetailScreen({super.key, required this.api, required this.signal, this.onWatch});

  final ApiClient api;
  final Signal signal;
  final VoidCallback? onWatch;

  @override
  State<SignalDetailScreen> createState() => _SignalDetailScreenState();
}

class _SignalDetailScreenState extends State<SignalDetailScreen> {
  late Signal s = widget.signal;
  List<List<double>> history = [];
  Timer? _t;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.get('/api/signals/${widget.signal.id}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        s = Signal(j);
        history = ((j['rssi_history'] as List?) ?? const [])
            .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
            .toList();
      });
    } on ApiException {
      if (mounted) setState(() => _gone = true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = s.cls;
    final d = s.distance;
    return Scaffold(
      appBar: AppBar(title: Text(fmtFreq(s.freqHz))),
      floatingActionButton: (c?.canShowVideo ?? false) && widget.onWatch != null
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Дивитися відео'),
              backgroundColor: Colors.redAccent,
              onPressed: () {
                Navigator.pop(context);
                widget.onWatch!();
              },
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (_gone)
            const Card(
              color: Color(0x33FF5252),
              child: Padding(padding: EdgeInsets.all(10), child: Text('Сигнал більше не відстежується')),
            ),
          Row(
            children: [
              ClassBadge(code: c?.code, text: c?.label ?? 'Аналізується…'),
              const Spacer(),
              if (c != null)
                Text('впевненість ${(c.confidence * 100).round()}%', style: const TextStyle(color: Colors.white54)),
            ],
          ),
          if (c != null && c.subtype.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(c.subtype, style: const TextStyle(fontSize: 16)),
            ),
          for (final h in c?.hints ?? const <String>[])
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 14, color: Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(h, style: const TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (d != null) _DistanceCard(d: d),
          const SizedBox(height: 8),
          _Section('Параметри', [
            _kv('Частота', fmtFreq(s.freqHz)),
            _kv(s.hopping ? 'Діапазон стрибків' : 'Ширина смуги', fmtBw(s.bandwidthHz)),
            if (s.hopping) _kv('Ширина одного стрибка', fmtBw((s.raw['hop_bandwidth_hz'] as num? ?? 0).toDouble())),
            _kv('RSSI', '${s.rssi.toStringAsFixed(1)} дБм'),
            _kv('Сигнал/шум', '${s.snr.toStringAsFixed(1)} дБ'),
            _kv('Присутність в ефірі', '${((s.raw['presence'] as num? ?? 0) * 100).round()}%'),
            _kv('Вперше', fmtTime(s.firstSeen)),
            _kv('Востаннє', fmtAgo(s.lastSeen)),
            _kv('Діапазон', s.range),
          ]),
          if (s.channel != null)
            _Section('Відома сітка каналів', [
              _kv('Канал', '${s.channel!['name']} (${s.channel!['band_title']})'),
              _kv('Номінал', fmtFreq((s.channel!['freq_hz'] as num).toDouble())),
              _kv('Відхилення', '${((s.channel!['offset_hz'] as num) / 1e3).toStringAsFixed(0)} кГц'),
            ]),
          if (s.video != null)
            _Section('Аналогове відео', [
              _kv('Стандарт', '${s.video!['standard']}'),
              _kv('Полярність', s.video!['inverted'] == true ? 'інвертована (виправлено)' : 'звичайна'),
              _kv('Скремблювання', s.video!['scrambled'] == null ? 'немає' : '${s.video!['scrambled']}'),
              _kv('Якість синхронізації', '${((s.video!['sync_score'] as num) * 100).round()}%'),
              _kv('SNR відео', '${s.video!['snr_db']} дБ'),
              _kv('Зсув несучої (AFC)', '${((s.video!['afc_offset_hz'] as num) / 1e3).toStringAsFixed(0)} кГц'),
            ]),
          if (s.iq != null)
            _Section('Ознаки сигналу', [
              _kv('Варіація огинаючої', '${s.iq!['envelope_cv']} (0 — FM/LoRa, ~0.5 — OFDM)'),
              _kv('Шпаруватість', '${((s.iq!['duty'] as num) * 100).round()}%'),
              _kv('Пік/середнє', '${s.iq!['papr_db']} дБ'),
            ]),
          if (s.thumbnailId != null)
            _Section('Останній кадр', [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.network(
                    widget.api.authUrl('/api/media/${s.thumbnailId}'),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(child: Text('Кадр перезаписано')),
                  ),
                ),
              ),
            ]),
          if (history.length > 2)
            _Section('Рівень сигналу (RSSI) у часі', [
              SizedBox(
                height: 120,
                child: CustomPaint(painter: _RssiPainter(history), child: const SizedBox.expand()),
              ),
            ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 160,
          child: Text(k, style: const TextStyle(color: Colors.white54)),
        ),
        Expanded(child: Text(v)),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 10),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    ),
  );
}

/// Шкала відстані: мінімальна / ймовірна / максимальна (логарифмічна), тренд.
class _DistanceCard extends StatelessWidget {
  const _DistanceCard({required this.d});

  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final minM = (d['min_m'] as num).toDouble();
    final likely = (d['likely_m'] as num).toDouble();
    final maxM = (d['max_m'] as num).toDouble();
    double pos(double m) => (math.log(m.clamp(10, 50000)) - math.log(10)) / (math.log(50000) - math.log(10));
    final trend = d['trend'] as String;
    String f(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} км' : '${m.round()} м';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.social_distance, size: 20),
                const SizedBox(width: 8),
                const Text('Приблизна відстань', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (trend != 'steady')
                  Row(
                    children: [
                      Icon(
                        trend == 'approaching' ? Icons.call_received : Icons.call_made,
                        color: trend == 'approaching' ? Colors.redAccent : Colors.greenAccent,
                        size: 18,
                      ),
                      Text(
                        trend == 'approaching' ? ' наближається' : ' віддаляється',
                        style: TextStyle(color: trend == 'approaching' ? Colors.redAccent : Colors.greenAccent),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('≈ ${f(likely)}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            Text(
              'від ${f(minM)} (слабкий передавач) до ${f(maxM)} (потужний)',
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (_, c) {
                final w = c.maxWidth;
                return SizedBox(
                  height: 34,
                  child: Stack(
                    children: [
                      Positioned(
                        top: 10,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 8,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            gradient: const LinearGradient(
                              colors: [Colors.redAccent, Colors.orangeAccent, Colors.green],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        left: pos(minM) * w,
                        width: math.max(4, (pos(maxM) - pos(minM)) * w),
                        child: Container(
                          height: 16,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        left: (pos(likely) * w - 2).clamp(0, w - 4),
                        child: Container(width: 4, height: 24, color: Colors.white),
                      ),
                      const Positioned(
                        bottom: -2,
                        left: 0,
                        child: Text('10 м', style: TextStyle(fontSize: 9, color: Colors.white38)),
                      ),
                      const Positioned(
                        bottom: -2,
                        right: 0,
                        child: Text('50 км', style: TextStyle(fontSize: 9, color: Colors.white38)),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            const Text(
              'Оцінка за RSSI, частотою і типовою потужністю передавача цього класу. Відбиття, '
              'перешкоди й антени можуть змінити результат у кілька разів. Точність підвищує калібрування '
              '(Керування → Калібрування відстані).',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _RssiPainter extends CustomPainter {
  _RssiPainter(this.pts);

  final List<List<double>> pts;

  @override
  void paint(Canvas canvas, Size size) {
    final t0 = pts.first[0], t1 = pts.last[0];
    final vals = pts.map((p) => p[1]);
    final lo = vals.reduce(math.min) - 3, hi = vals.reduce(math.max) + 3;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = (pts[i][0] - t0) / math.max(1e-3, t1 - t0) * size.width;
      final y = size.height * (1 - (pts[i][1] - lo) / (hi - lo));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '${hi.toStringAsFixed(0)} дБм',
        style: const TextStyle(color: Colors.white38, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset.zero);
    final tp2 = TextPainter(
      text: TextSpan(
        text: '${lo.toStringAsFixed(0)} дБм',
        style: const TextStyle(color: Colors.white38, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(0, size.height - 12));
  }

  @override
  bool shouldRepaint(covariant _RssiPainter old) => old.pts != pts;
}
