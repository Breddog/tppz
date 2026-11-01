import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../device_store.dart';
import '../live.dart';
import '../models.dart';
import 'add_device_screen.dart';
import 'module_sections.dart';
import 'network_section.dart';
import 'transmit_screen.dart';
import 'update_section.dart';

/// Дистанційне керування модулем.
class ControlTab extends StatefulWidget {
  const ControlTab({super.key, required this.api, required this.device});

  final ApiClient api;
  final Device device;

  @override
  State<ControlTab> createState() => _ControlTabState();
}

class _ControlTabState extends State<ControlTab> {
  Map<String, dynamic>? cfg;
  String? err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await widget.api.get('/api/config') as Map<String, dynamic>;
      if (mounted) setState(() => cfg = c);
    } catch (e) {
      if (mounted) setState(() => err = e.toString());
    }
  }

  Future<void> _patch(Map<String, dynamic> p) async {
    try {
      final c = await widget.api.put('/api/config', p) as Map<String, dynamic>;
      if (mounted) setState(() => cfg = c);
    } catch (e) {
      _toast(e.toString());
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _call(Future<dynamic> Function() f, [String? ok]) async {
    try {
      await f();
      if (ok != null) _toast(ok);
    } on ControlLockedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          action: SnackBarAction(label: 'Перехопити', onPressed: _claimControl),
        ),
      );
    } catch (e) {
      _toast(e.toString());
    }
  }

  Future<void> _claimControl() async {
    try {
      await widget.api.post(
        '/api/control/claim?name=${Uri.encodeComponent(ApiClient.clientName.isEmpty ? "Телефон" : ApiClient.clientName)}',
      );
      _toast('Керування перехоплено');
    } catch (e) {
      _toast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final c = cfg;
    if (c == null) {
      return Center(
        child: err == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(err!),
                  TextButton(onPressed: _load, child: const Text('Повторити')),
                ],
              ),
      );
    }
    final dsp = c['dsp'] as Map<String, dynamic>;
    final dist = c['distance'] as Map<String, dynamic>;
    final st = c['storage'] as Map<String, dynamic>;
    final nt = c['notify'] as Map<String, dynamic>;
    final ranges = (c['ranges'] as List).cast<Map<String, dynamic>>();
    final fb = c['full_band'] as Map<String, dynamic>;
    final full = ((l.status['ranges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((r) => r['full'] == true)
        .firstOrNull;
    final mode = l.status['mode'] as String? ?? 'scan';
    final stats = l.status['stats'] as Map<String, dynamic>?;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          HealthCard(live: l, api: widget.api),
          _h('Режим роботи'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'scan', icon: Icon(Icons.radar), label: Text('Сканування')),
                ButtonSegment(value: 'watch', icon: Icon(Icons.gps_fixed), label: Text('Стеження')),
                ButtonSegment(value: 'paused', icon: Icon(Icons.pause), label: Text('Пауза')),
              ],
              selected: {mode},
              onSelectionChanged: (s) async {
                if (s.first == 'watch') {
                  _toast('Оберіть сигнал або канал на вкладці «Відео»');
                  return;
                }
                await _call(() async {
                  final r = await widget.api.post(s.first == 'scan' ? '/api/control/scan' : '/api/control/pause');
                  l.status = r as Map<String, dynamic>;
                  l.watch = null;
                  setState(() {});
                });
              },
            ),
          ),
          if (stats != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Повний прохід: ${stats['sweep_s']} с · проходів: ${stats['sweeps']} · '
                'помилок SDR: ${stats['errors']}${l.status['cpu_temp_c'] != null ? ' · CPU ${l.status['cpu_temp_c']}°C' : ''}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),

          _h('Діапазони сканування'),
          for (var i = 0; i < ranges.length; i++)
            SwitchListTile(
              dense: true,
              title: Text(ranges[i]['name'] as String),
              subtitle: Text(
                '${fmtFreq((ranges[i]['start_hz'] as num).toDouble())} – ${fmtFreq((ranges[i]['stop_hz'] as num).toDouble())}',
              ),
              value: ranges[i]['enabled'] as bool,
              onChanged: (v) => _call(() async {
                await widget.api.post('/api/ranges/toggle', {'index': i, 'enabled': v});
                await _load();
              }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Додати діапазон'),
              onPressed: () => _addRange(ranges),
            ),
          ),
          SwitchListTile(
            title: const Text('Повний діапазон SDR'),
            subtitle: Text(
              full == null
                  ? 'Виявлення на всій ширині приймача (між проходами пріоритетних діапазонів)'
                  : '${fmtFreq((full['start_hz'] as num).toDouble())} – ${fmtFreq((full['stop_hz'] as num).toDouble())}'
                        ' · повний прохід ${full['pass_s'] ?? '…'} с',
            ),
            value: fb['enabled'] as bool,
            onChanged: (v) => _patch({
              'full_band': {'enabled': v},
            }),
          ),
          if (fb['enabled'] == true)
            _slider(
              'Сегментів повного діапазону за цикл',
              (fb['segments_per_cycle'] as num).toDouble(),
              10,
              200,
              19,
              '',
              (v) => _patch({
                'full_band': {'segments_per_cycle': v.round()},
              }),
              help: 'Більше — швидше оглядається весь ефір, але рідше оновлюються FPV-діапазони',
            ),

          _h('Виявлення сигналів'),
          Builder(
            builder: (_) {
              final echo = (l.status['echo_filter'] as Map?)?.cast<String, dynamic>() ?? const {};
              return Column(
                children: [
                  SwitchListTile(
                    title: const Text('Ехо-фільтр сталих шумів'),
                    subtitle: Text(
                      echo['learning'] == true
                          ? 'Вивчає сталий фон… (${echo['learn_left']})'
                          : 'Вивчити постійні завади (спури, свої передавачі) й не реагувати на них',
                    ),
                    value: (echo['enabled'] as bool?) ?? (dsp['echo_filter'] as bool? ?? false),
                    onChanged: (v) => _call(() => widget.api.post('/api/control/echo_filter', {'on': v})),
                  ),
                  if (echo['enabled'] == true)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Перевчити фон зараз'),
                        onPressed: () => _call(
                          () => widget.api.post('/api/control/echo_filter', {'on': true, 'relearn': true}),
                          'Вивчаю сталий фон…',
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          _slider(
            'Поріг над шумом',
            (dsp['threshold_db'] as num).toDouble(),
            4,
            20,
            16,
            'дБ',
            (v) => _patch({
              'dsp': {'threshold_db': v},
            }),
            help: 'Менше — чутливіше, але більше хибних спрацювань',
          ),
          _slider(
            'Підтвердження (проходів)',
            (dsp['confirm_hits'] as num).toDouble(),
            1,
            6,
            5,
            '',
            (v) => _patch({
              'dsp': {'confirm_hits': v.round()},
            }),
            help: 'Скільки разів поспіль сигнал має з\'явитися, щоб не плутати із шумом',
          ),

          _h('Оцінка відстані'),
          ListTile(
            title: const Text('Місцевість'),
            trailing: DropdownButton<double>(
              value: _nearest((dist['path_loss_exponent'] as num).toDouble(), const [2.0, 2.2, 2.7, 3.3]),
              items: const [
                DropdownMenuItem(value: 2.0, child: Text('Відкрите поле')),
                DropdownMenuItem(value: 2.2, child: Text('Поле / лісосмуги')),
                DropdownMenuItem(value: 2.7, child: Text('Передмістя')),
                DropdownMenuItem(value: 3.3, child: Text('Місто')),
              ],
              onChanged: (v) => _patch({
                'distance': {'path_loss_exponent': v},
              }),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.straighten),
            title: const Text('Калібрування відстані'),
            subtitle: Text('Поправка RSSI: ${(dist['rx_cal_db'] as num).toStringAsFixed(1)} дБ'),
            onTap: _calibrate,
          ),

          _h('Антена'),
          AntennaSection(
            antenna: (c['antenna'] as Map?)?.cast<String, dynamic>() ?? const {'name': 'Штатна (невідома)'},
            onSave: (a) => _patch({'antenna': a}),
          ),

          _h('Кільцевий запис на флешці'),
          _slider(
            'Виділено місця',
            _quotaPos((st['quota_mb'] as num).toInt()),
            0,
            8,
            8,
            '',
            (v) => _patch({
              'storage': {'quota_mb': _quotaVals[v.round()]},
            }),
            fmt: (v) => fmtBytes(_quotaVals[v.round()] * 1024 * 1024),
          ),
          SwitchListTile(
            title: const Text('Записувати відео'),
            subtitle: const Text('Короткий кліп при виявленні відео + запис у режимі стеження'),
            value: st['record_video'] as bool,
            onChanged: (v) => _patch({
              'storage': {'record_video': v},
            }),
          ),
          SwitchListTile(
            title: const Text('Архів водоспаду'),
            value: st['save_waterfall'] as bool,
            onChanged: (v) => _patch({
              'storage': {'save_waterfall': v},
            }),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
            title: const Text('Очистити історію на модулі'),
            onTap: () async {
              if (await _confirm('Видалити всі події та записи з флешки модуля?')) {
                await _call(() => widget.api.post('/api/storage/clear'), 'Історію очищено');
              }
            },
          ),

          ExpansionTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Сповіщення з модуля (ntfy / Telegram)'),
            subtitle: Text(
              nt['enabled'] != true
                  ? 'вимкнено'
                  : [
                      if ((nt['ntfy_url'] as String? ?? '').isNotEmpty) 'ntfy',
                      if ((nt['telegram_chat_id'] as String? ?? '').isNotEmpty) 'Telegram',
                    ].join(', ').ifEmpty('не налаштовано'),
            ),
            children: [
              SwitchListTile(
                title: const Text('Сповіщення з модуля'),
                subtitle: const Text('ntfy / Telegram / вебхук — працюють навіть без фонового режиму на телефоні'),
                value: nt['enabled'] as bool,
                onChanged: (v) => _patch({
                  'notify': {'enabled': v},
                }),
              ),
              _textTile(
                'ntfy URL (https://ntfy.sh/ваш-секретний-топік)',
                nt['ntfy_url'] as String,
                (v) => _patch({
                  'notify': {'ntfy_url': v},
                }),
              ),
              _textTile(
                'Telegram bot token',
                nt['telegram_token'] as String,
                (v) => _patch({
                  'notify': {'telegram_token': v},
                }),
              ),
              _textTile(
                'Telegram chat id',
                nt['telegram_chat_id'] as String,
                (v) => _patch({
                  'notify': {'telegram_chat_id': v},
                }),
              ),
            ],
          ),

          _h('Тест приймачів'),
          ListTile(
            leading: const Icon(Icons.cell_tower, color: Colors.redAccent),
            title: const Text('Тестовий передавач'),
            subtitle: Text(
              (l.status['sdr'] as Map?)?['can_transmit'] == true
                  ? 'Передати тестовий сигнал/відео на заданій частоті — перевірити приймання'
                  : 'Потрібен HackRF (цей приймач не передає)',
            ),
            trailing: ((l.status['tx'] as Map?)?['active'] == true)
                ? const Chip(
                    label: Text('ПЕРЕДАЧА'),
                    backgroundColor: Color(0x33FF5252),
                    labelStyle: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                  )
                : const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TransmitScreen(api: widget.api))),
          ),

          _h('Оновлення'),
          UpdateSection(api: widget.api),

          _h('Користувачі'),
          UsersSection(api: widget.api, call: _call, onClaim: _claimControl),

          _h('Мережа'),
          NetworkSection(api: widget.api, call: _call),

          _h('Модуль'),
          _textTile('Назва модуля', c['name'] as String, (v) async {
            final store = context.read<DeviceStore>();
            await _patch({'name': v});
            widget.device.name = v;
            await store.update(widget.device);
          }),
          _textTile(
            'Координати (широта, довгота)',
            c['latitude'] == null ? '' : '${c['latitude']}, ${c['longitude']}',
            (v) {
              final p = v.split(RegExp(r'[,\s]+')).map(double.tryParse).toList();
              if (p.length == 2 && p[0] != null && p[1] != null) _patch({'latitude': p[0], 'longitude': p[1]});
            },
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Адреси та токен'),
            subtitle: Text(widget.device.urls.join('\n')),
            onTap: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => AddDeviceScreen(existing: widget.device))),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Перезапустити сервіс на модулі'),
            onTap: () async {
              if (await _confirm('Перезапустити сервіс? Зв\'язок зникне на кілька секунд.')) {
                await _call(() => widget.api.post('/api/control/restart'), 'Перезапуск…');
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Видалити модуль із застосунку'),
            onTap: () async {
              final store = context.read<DeviceStore>();
              final nav = Navigator.of(context);
              if (await _confirm('Видалити «${widget.device.name}» зі списку? Модуль продовжить працювати.')) {
                await store.remove(widget.device.id);
                nav.pop();
              }
            },
          ),
        ],
      ),
    );
  }

  static const _quotaVals = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
  double _quotaPos(int mb) {
    var best = 0;
    for (var i = 0; i < _quotaVals.length; i++) {
      if ((_quotaVals[i] - mb).abs() < (_quotaVals[best] - mb).abs()) best = i;
    }
    return best.toDouble();
  }

  double _nearest(double v, List<double> opts) => opts.reduce((a, b) => (a - v).abs() < (b - v).abs() ? a : b);

  Widget _h(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
    child: Text(
      t,
      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
    ),
  );

  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    int div,
    String unit,
    void Function(double) onEnd, {
    String? help,
    String Function(double)? fmt,
  }) {
    return _SliderTile(
      title: title,
      value: value,
      min: min,
      max: max,
      div: div,
      unit: unit,
      onEnd: onEnd,
      help: help,
      fmt: fmt,
    );
  }

  Widget _textTile(String label, String value, void Function(String) onSave) => ListTile(
    title: Text(label, style: const TextStyle(fontSize: 13, color: Colors.white60)),
    subtitle: Text(value.isEmpty ? '— не задано —' : value, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.edit, size: 18),
    onTap: () async {
      final ctl = TextEditingController(text: value == '***' ? '' : value);
      final r = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(label),
          content: TextField(controller: ctl, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
            FilledButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: const Text('Зберегти')),
          ],
        ),
      );
      if (r != null) onSave(r);
    },
  );

  Future<bool> _confirm(String q) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          content: Text(q),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Ні')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Так')),
          ],
        ),
      ) ??
      false;

  Future<void> _addRange(List<Map<String, dynamic>> ranges) async {
    final name = TextEditingController(), a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Новий діапазон'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Назва'),
            ),
            TextField(
              controller: a,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Від, МГц'),
            ),
            TextField(
              controller: b,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'До, МГц'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Додати')),
        ],
      ),
    );
    final f0 = double.tryParse(a.text), f1 = double.tryParse(b.text);
    if (ok == true && f0 != null && f1 != null && f1 > f0) {
      await _patch({
        'ranges': [
          ...ranges,
          {
            'name': name.text.isEmpty ? '$f0–$f1 МГц' : name.text,
            'start_hz': f0 * 1e6,
            'stop_hz': f1 * 1e6,
            'enabled': true,
          },
        ],
      });
    }
  }

  Future<void> _calibrate() async {
    final f = TextEditingController(text: '5800'),
        d = TextEditingController(text: '10'),
        p = TextEditingController(text: '14');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Калібрування відстані'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Увімкніть свій передавач відомої потужності (напр. VTX 25 мВт = 14 дБм) '
              'на відомій відстані від антени модуля.',
              style: TextStyle(fontSize: 13),
            ),
            TextField(
              controller: f,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Частота, МГц'),
            ),
            TextField(
              controller: d,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Відстань, м'),
            ),
            TextField(
              controller: p,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Потужність (EIRP), дБм'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Виміряти')),
        ],
      ),
    );
    if (ok != true) return;
    await _call(() async {
      final r = await widget.api.post('/api/calibrate', {
        'freq_hz': double.parse(f.text) * 1e6,
        'distance_m': double.parse(d.text),
        'eirp_dbm': double.parse(p.text),
      });
      _toast('Нова поправка: ${(r as Map)['rx_cal_db']} дБ');
      await _load();
    });
  }
}

class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.div,
    required this.unit,
    required this.onEnd,
    this.help,
    this.fmt,
  });

  final String title;
  final double value, min, max;
  final int div;
  final String unit;
  final void Function(double) onEnd;
  final String? help;
  final String Function(double)? fmt;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  late double v = widget.value;

  @override
  void didUpdateWidget(covariant _SliderTile old) {
    super.didUpdateWidget(old);
    v = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final txt = widget.fmt?.call(v) ?? '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)} ${widget.unit}';
    return ListTile(
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          Text(txt),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Slider(
            value: v.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.div,
            onChanged: (x) => setState(() => v = x),
            onChangeEnd: widget.onEnd,
          ),
          if (widget.help != null) Text(widget.help!, style: const TextStyle(fontSize: 11, color: Colors.white38)),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
