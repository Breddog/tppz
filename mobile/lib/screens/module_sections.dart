import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';

/// Стан модуля: температура ЦП, навантаження, живлення, пам'ять, флешка (+ графік за годину).
class HealthCard extends StatelessWidget {
  const HealthCard({super.key, required this.live, required this.api});

  final LiveConnection live;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final h = live.health;
    if (h == null) {
      return const ListTile(
        leading: Icon(Icons.memory),
        title: Text('Стан модуля'),
        subtitle: Text('Немає даних (модуль старої версії або ще не надіслав)'),
      );
    }
    final temp = (h['cpu_temp_c'] as num?)?.toDouble();
    final cpu = (h['cpu_pct'] as num?)?.toDouble();
    final warns = ((h['warnings'] as List?) ?? const []).cast<String>();
    final thr = ((h['throttled_text'] as List?) ?? const []).cast<String>();
    final disk = (h['disk'] as Map?)?.cast<String, dynamic>() ?? const {};
    Color tc = Colors.greenAccent;
    if (temp != null && temp >= 70) tc = Colors.orangeAccent;
    if (temp != null && temp >= 80) tc = Colors.redAccent;
    Widget tile(IconData i, String label, String value, [Color? c]) => SizedBox(
      width: 150,
      child: Row(
        children: [
          Icon(i, size: 18, color: c ?? Colors.white60),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                Text(
                  value,
                  style: TextStyle(fontWeight: FontWeight.bold, color: c),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final up = (h['uptime_s'] as num?)?.toInt();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: InkWell(
        onTap: () => _history(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Стан модуля', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  const Text('графік →', style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                runSpacing: 10,
                children: [
                  tile(Icons.thermostat, 'Температура ЦП', temp == null ? '—' : '${temp.toStringAsFixed(1)} °C', tc),
                  tile(Icons.speed, 'Навантаження ЦП', cpu == null ? '—' : '${cpu.round()} %'),
                  tile(Icons.memory, 'Частота ЦП', h['cpu_mhz'] == null ? '—' : '${h['cpu_mhz']} МГц'),
                  tile(
                    Icons.storage,
                    'Пам\'ять вільна',
                    h['mem_free_mb'] == null ? '—' : '${h['mem_free_mb']} / ${h['mem_total_mb']} МБ',
                  ),
                  tile(
                    Icons.sd_card,
                    'Флешка вільна',
                    disk['free_mb'] == null ? '—' : '${((disk['free_mb'] as num) / 1024).toStringAsFixed(1)} ГБ',
                  ),
                  tile(
                    Icons.power,
                    'Живлення',
                    h['undervoltage'] == true ? 'ПРОСІДАЄ' : (h['throttled'] == null ? '—' : 'норма'),
                    h['undervoltage'] == true ? Colors.redAccent : null,
                  ),
                  tile(Icons.timer_outlined, 'Працює', up == null ? '—' : '${up ~/ 3600} год ${(up % 3600) ~/ 60} хв'),
                ],
              ),
              for (final w in warns)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('⚠ $w', style: const TextStyle(color: Colors.orangeAccent)),
                ),
              if (thr.isNotEmpty && warns.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(thr.join(' · '), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _history(BuildContext context) async {
    try {
      final r = await api.get('/api/health') as Map<String, dynamic>;
      final hist = ((r['history'] as List?) ?? const []).cast<Map<String, dynamic>>();
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Стан модуля за годину'),
          content: SizedBox(width: 360, height: 220, child: CustomPaint(painter: _HealthChart(hist))),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрити'))],
        ),
      );
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

class _HealthChart extends CustomPainter {
  _HealthChart(this.hist);

  final List<Map<String, dynamic>> hist;

  @override
  void paint(Canvas canvas, Size size) {
    if (hist.length < 2) return;
    const top = 16.0, bottom = 18.0;
    final h = size.height - top - bottom;
    void series(String key, double lo, double hi, Color c) {
      final p = Path();
      var started = false;
      for (var i = 0; i < hist.length; i++) {
        final v = (hist[i][key] as num?)?.toDouble();
        if (v == null) continue;
        final x = i / (hist.length - 1) * size.width;
        final y = top + h * (1 - ((v - lo) / (hi - lo)).clamp(0.0, 1.0));
        if (!started) {
          p.moveTo(x, y);
          started = true;
        } else {
          p.lineTo(x, y);
        }
      }
      canvas.drawPath(
        p,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    final grid = Paint()..color = Colors.white12;
    for (var k = 0; k <= 4; k++) {
      final y = top + h * k / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    series('cpu_pct', 0, 100, Colors.lightBlueAccent);
    series('cpu_temp_c', 30, 90, Colors.orangeAccent);
    final tp = TextPainter(
      text: const TextSpan(
        children: [
          TextSpan(
            text: '■ температура 30–90 °C   ',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
          ),
          TextSpan(
            text: '■ навантаження 0–100 %',
            style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    tp.paint(canvas, Offset.zero);
    final n = hist.length;
    final mins = n * 5 ~/ 60;
    final tp2 = TextPainter(
      text: TextSpan(
        text: '−$mins хв … зараз',
        style: const TextStyle(color: Colors.white38, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(0, size.height - 14));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Профіль антени модуля: назва, тип, робочі діапазони з підсиленням, втрати кабелю.
class AntennaSection extends StatelessWidget {
  const AntennaSection({super.key, required this.antenna, required this.onSave});

  final Map<String, dynamic> antenna;
  final Future<void> Function(Map<String, dynamic>) onSave;

  static const kinds = {
    'omni': 'Всеспрямована (штир, «клевер»)',
    'directional': 'Спрямована',
    'panel': 'Панель / патч',
    'yagi': 'Яги / хвильовий канал',
    'helix': 'Спіральна',
  };

  /// Готові профілі поширених антен.
  static final presets = <String, Map<String, dynamic>>{
    'HackRF ANT500 (штатна телескопічна)': {
      'name': 'HackRF ANT500',
      'kind': 'omni',
      'cable_loss_db': 0.0,
      'bands': [
        {'start_mhz': 75, 'stop_mhz': 1000, 'gain_dbi': 0},
      ],
    },
    '5.8 ГГц «клевер» RHCP': {
      'name': '5.8 ГГц клевер',
      'kind': 'omni',
      'cable_loss_db': 0.5,
      'bands': [
        {'start_mhz': 5600, 'stop_mhz': 6000, 'gain_dbi': 2},
      ],
    },
    '5.8 ГГц патч 8–9 дБі': {
      'name': '5.8 ГГц патч',
      'kind': 'panel',
      'cable_loss_db': 0.5,
      'bands': [
        {'start_mhz': 5600, 'stop_mhz': 6000, 'gain_dbi': 8.5},
      ],
    },
    '1.2–1.3 ГГц штир': {
      'name': '1.2 ГГц штир',
      'kind': 'omni',
      'cable_loss_db': 0.3,
      'bands': [
        {'start_mhz': 1050, 'stop_mhz': 1400, 'gain_dbi': 2},
      ],
    },
    'Дводіапазонна 2.4 / 5.8 ГГц': {
      'name': '2.4/5.8 ГГц',
      'kind': 'omni',
      'cable_loss_db': 0.5,
      'bands': [
        {'start_mhz': 2400, 'stop_mhz': 2500, 'gain_dbi': 2},
        {'start_mhz': 5150, 'stop_mhz': 5950, 'gain_dbi': 3},
      ],
    },
    'Широкосмугова логоперіодична 0.7–6 ГГц': {
      'name': 'LPDA 0.7–6 ГГц',
      'kind': 'directional',
      'cable_loss_db': 1.0,
      'bands': [
        {'start_mhz': 700, 'stop_mhz': 6000, 'gain_dbi': 5},
      ],
    },
  };

  @override
  Widget build(BuildContext context) {
    final bands = ((antenna['bands'] as List?) ?? const []).cast<Map>();
    return ListTile(
      leading: const Icon(Icons.settings_input_antenna),
      title: Text(antenna['name'] as String? ?? 'Антена'),
      subtitle: Text(
        '${kinds[antenna['kind']] ?? antenna['kind'] ?? ''}'
        '${bands.isEmpty ? ' · діапазони не вказані' : ' · ${bands.map((b) => '${b['start_mhz']}–${b['stop_mhz']} МГц ${b['gain_dbi']} дБі').join(', ')}'}'
        '${(antenna['cable_loss_db'] as num? ?? 0) > 0 ? ' · кабель −${antenna['cable_loss_db']} дБ' : ''}',
      ),
      trailing: const Icon(Icons.edit),
      onTap: () async {
        final r = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (_) => _AntennaDialog(initial: antenna),
        );
        if (r != null) await onSave(r);
      },
    );
  }
}

class _AntennaDialog extends StatefulWidget {
  const _AntennaDialog({required this.initial});

  final Map<String, dynamic> initial;

  @override
  State<_AntennaDialog> createState() => _AntennaDialogState();
}

class _AntennaDialogState extends State<_AntennaDialog> {
  late final _name = TextEditingController(text: widget.initial['name'] as String? ?? '');
  late String _kind = widget.initial['kind'] as String? ?? 'omni';
  late final _loss = TextEditingController(text: '${widget.initial['cable_loss_db'] ?? 0}');
  late final _notes = TextEditingController(text: widget.initial['notes'] as String? ?? '');
  late List<List<TextEditingController>> _bands = [
    for (final b in ((widget.initial['bands'] as List?) ?? const []).cast<Map>())
      [
        TextEditingController(text: '${b['start_mhz']}'),
        TextEditingController(text: '${b['stop_mhz']}'),
        TextEditingController(text: '${b['gain_dbi']}'),
      ],
  ];

  void _preset(Map<String, dynamic> p) {
    setState(() {
      _name.text = p['name'] as String;
      _kind = p['kind'] as String;
      _loss.text = '${p['cable_loss_db']}';
      _bands = [
        for (final b in (p['bands'] as List).cast<Map>())
          [
            TextEditingController(text: '${b['start_mhz']}'),
            TextEditingController(text: '${b['stop_mhz']}'),
            TextEditingController(text: '${b['gain_dbi']}'),
          ],
      ];
    });
  }

  double _num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.')) ?? 0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Антена модуля'),
      content: SizedBox(
        width: math.min(420, MediaQuery.of(context).size.width),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Готові профілі', style: TextStyle(color: Colors.white54, fontSize: 12)),
              Wrap(
                spacing: 6,
                children: [
                  for (final e in AntennaSection.presets.entries)
                    ActionChip(
                      label: Text(e.key, style: const TextStyle(fontSize: 12)),
                      onPressed: () => _preset(e.value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Назва'),
              ),
              DropdownButton<String>(
                value: AntennaSection.kinds.containsKey(_kind) ? _kind : 'omni',
                isExpanded: true,
                items: [
                  for (final e in AntennaSection.kinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _kind = v ?? 'omni'),
              ),
              TextField(
                controller: _loss,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Втрати в кабелі та роз\'ємах, дБ'),
              ),
              const SizedBox(height: 10),
              const Text('Робочі діапазони', style: TextStyle(fontWeight: FontWeight.bold)),
              for (var i = 0; i < _bands.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _bands[i][0],
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'від, МГц'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _bands[i][1],
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'до, МГц'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _bands[i][2],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'дБі'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _bands.removeAt(i)),
                    ),
                  ],
                ),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Додати діапазон'),
                onPressed: () => setState(
                  () => _bands.add([
                    TextEditingController(text: '5650'),
                    TextEditingController(text: '5950'),
                    TextEditingController(text: '2'),
                  ]),
                ),
              ),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Примітки (необов\'язково)'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Підсилення враховується в оцінці відстані й калібруванні. Поза вказаними діапазонами модуль '
                'вважає прийом гіршим на ~10 дБ і показує це в підказках.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'name': _name.text.trim().isEmpty ? 'Антена' : _name.text.trim(),
            'kind': _kind,
            'cable_loss_db': _num(_loss),
            'notes': _notes.text,
            'bands': [
              for (final b in _bands) {'start_mhz': _num(b[0]), 'stop_mhz': _num(b[1]), 'gain_dbi': _num(b[2])},
            ],
          }),
          child: const Text('Зберегти'),
        ),
      ],
    );
  }
}
