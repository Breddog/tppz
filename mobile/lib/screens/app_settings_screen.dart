import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../app_update.dart';
import '../background.dart';
import '../device_store.dart';
import '../notifications.dart';
import '../notify_settings.dart';
import 'analysis_settings.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool _bg = true;
  int _interval = 15;
  NotifySettings? _ns;
  AppRelease? _rel;
  String? _updMsg;
  double? _progress;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    NotifySettings.load().then((v) => setState(() => _ns = v));
    SharedPreferences.getInstance().then(
      (p) => setState(() {
        _bg = p.getBool(BackgroundMonitor.prefEnabled) ?? true;
        _interval = p.getInt(BackgroundMonitor.prefInterval) ?? 15;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Налаштування')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Фоновий моніторинг'),
            subtitle: const Text('Сповіщення про нові сигнали, навіть коли застосунок згорнуто'),
            value: _bg,
            onChanged: (v) async {
              setState(() => _bg = v);
              await BackgroundMonitor.setEnabled(v);
            },
          ),
          ListTile(
            title: const Text('Інтервал опитування модулів'),
            subtitle: Slider(
              value: _interval.toDouble(),
              min: 5,
              max: 120,
              divisions: 23,
              label: '$_interval с',
              onChanged: (v) => setState(() => _interval = v.round()),
              onChangeEnd: (v) async =>
                  (await SharedPreferences.getInstance()).setInt(BackgroundMonitor.prefInterval, v.round()),
            ),
            trailing: Text('$_interval с'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Перевірити сповіщення'),
            onTap: () async {
              await Notifications.init(requestPermission: true);
              await Notifications.alert(1, 'Тестове сповіщення', 'Так виглядатиме тривога про знайдений сигнал');
            },
          ),
          if (_ns != null) ..._notifySection(_ns!, store),
          const Divider(),
          ..._updateSection(),
          const Divider(),
          const AnalysisSettingsSection(),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Сповіщення по модулях', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final d in store.devices)
            ListTile(
              title: Text(d.name),
              subtitle: Text(
                const ['Усі сигнали', 'Середній і високий пріоритет', 'Лише відео й керування'][d.minPriority],
              ),
              trailing: Switch(
                value: d.notify,
                onChanged: (v) {
                  d.notify = v;
                  store.update(d);
                },
              ),
              onTap: () async {
                final v = await showDialog<int>(
                  context: context,
                  builder: (_) => SimpleDialog(
                    title: const Text('Про що сповіщати'),
                    children: [
                      for (var i = 0; i < 3; i++)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(context, i),
                          child: Text(
                            const ['Усі сигнали', 'Середній і високий пріоритет', 'Лише відео й керування'][i],
                          ),
                        ),
                    ],
                  ),
                );
                if (v != null) {
                  d.minPriority = v;
                  store.update(d);
                }
              },
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Порада: щоб Android не «присипляв» моніторинг, вимкніть для застосунку оптимізацію батареї. '
              'На iOS фонова робота обмежена системою — для гарантованих push-сповіщень налаштуйте на модулі '
              'ntfy або Telegram (Керування → Сповіщення).',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Що повідомляти -----------------------------------------------------------------------
  List<Widget> _notifySection(NotifySettings ns, DeviceStore store) {
    void save() {
      setState(() {});
      ns.save();
    }

    const names = {
      'analog_video': 'Аналогове відео',
      'analog_video_inverted': 'Інвертоване відео',
      'analog_video_scrambled': 'Кодоване відео',
      'analog_video_weak': 'Слабке аналогове відео',
      'digital_video': 'Цифрове відео (DJI тощо)',
      'control_link': 'Керування дроном (ELRS, Crossfire…)',
      'telemetry': 'Телеметрія',
      'wifi': 'Wi-Fi',
      'known_service': 'Стільниковий / відомі служби',
      'wideband_unknown': 'Невідомий широкосмуговий',
      'carrier': 'Несуча / вузький сигнал',
      'unknown': 'Невідомий',
    };
    return [
      const Divider(),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text('Що повідомляти', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(
          spacing: 6,
          children: [
            for (final e in names.entries)
              FilterChip(
                label: Text(e.value),
                selected: ns.classes.contains(e.key),
                onSelected: (v) {
                  v ? ns.classes.add(e.key) : ns.classes.remove(e.key);
                  save();
                },
              ),
          ],
        ),
      ),
      ListTile(
        title: Text(
          ns.minRssiDbm == null
              ? 'Мінімальний рівень сигналу: будь-який'
              : 'Лише сигнали сильніші за ${ns.minRssiDbm!.round()} дБм',
        ),
        subtitle: Slider(
          value: ns.minRssiDbm ?? -130,
          min: -130,
          max: -40,
          divisions: 18,
          onChanged: (v) {
            ns.minRssiDbm = v <= -130 ? null : v;
            save();
          },
        ),
      ),
      ListTile(
        title: Text(
          'Не повторювати ту саму частоту частіше ніж раз на ${ns.cooldownS ~/ 60} хв ${ns.cooldownS % 60} с',
        ),
        subtitle: Slider(
          value: ns.cooldownS.toDouble().clamp(10, 1800),
          min: 10,
          max: 1800,
          divisions: 179,
          onChanged: (v) {
            ns.cooldownS = v.round();
            save();
          },
        ),
      ),
      SwitchListTile(
        title: const Text('Звук'),
        value: ns.sound,
        onChanged: (v) {
          ns.sound = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('Вібрація'),
        value: ns.vibrate,
        onChanged: (v) {
          ns.vibrate = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('Сповіщати, коли застосунок відкрито'),
        subtitle: const Text('Спливаюче повідомлення на екрані модуля'),
        value: ns.inApp,
        onChanged: (v) {
          ns.inApp = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('Стан модуля'),
        subtitle: const Text('Перегрів ЦП, просідання живлення, мало місця на флешці'),
        value: ns.moduleHealth,
        onChanged: (v) {
          ns.moduleHealth = v;
          save();
        },
      ),
      ListTile(
        title: const Text('Тиха година (без звуку й вібрації)'),
        subtitle: Text(ns.quietFrom == null ? 'Вимкнено' : 'з ${ns.quietFrom}:00 до ${ns.quietTo}:00'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<int?>(
              value: ns.quietFrom,
              hint: const Text('з'),
              items: [
                const DropdownMenuItem(value: null, child: Text('—')),
                for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text('$h')),
              ],
              onChanged: (v) {
                ns.quietFrom = v;
                ns.quietTo ??= v == null ? null : (v + 8) % 24;
                if (v == null) ns.quietTo = null;
                save();
              },
            ),
            const Text(' – '),
            DropdownButton<int?>(
              value: ns.quietTo,
              hint: const Text('до'),
              items: [
                const DropdownMenuItem(value: null, child: Text('—')),
                for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text('$h')),
              ],
              onChanged: ns.quietFrom == null
                  ? null
                  : (v) {
                      ns.quietTo = v;
                      save();
                    },
            ),
          ],
        ),
      ),
      ListTile(
        leading: const Icon(Icons.send_to_mobile),
        title: const Text('Передати ці фільтри на модулі'),
        subtitle: const Text('Тоді Telegram / ntfy на модулі повідомлятимуть так само'),
        onTap: () async {
          var ok = 0;
          for (final d in store.devices) {
            try {
              await ApiClient(d).put('/api/config', ns.toModuleConfig());
              ok++;
            } catch (_) {}
          }
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Передано на $ok з ${store.devices.length} модулів')));
          }
        },
      ),
    ];
  }

  // ---- Оновлення застосунку (без модуля) -------------------------------------------------
  List<Widget> _updateSection() => [
    const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text('Оновлення застосунку', style: TextStyle(fontWeight: FontWeight.bold)),
    ),
    ListTile(
      leading: const Icon(Icons.system_update),
      title: Text('Встановлено: збірка $appBuild'),
      subtitle: Text(
        _rel == null
            ? (_updMsg ?? 'Перевіряє GitHub через інтернет телефона — модуль не потрібен')
            : (_rel!.number > AppUpdate.currentBuild
                  ? 'Доступна збірка ${_rel!.number} (${(_rel!.size / 1e6).toStringAsFixed(0)} МБ)'
                  : 'У вас найновіша збірка'),
      ),
      trailing: _checking
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onTap: _checkUpdate,
    ),
    if (_progress != null)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LinearProgressIndicator(value: _progress),
      ),
    if (_rel != null && _rel!.number > AppUpdate.currentBuild)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: FilledButton.icon(
          icon: const Icon(Icons.download),
          label: Text('Завантажити й встановити збірку ${_rel!.number}'),
          onPressed: _progress != null ? null : _install,
        ),
      ),
  ];

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _updMsg = null;
    });
    try {
      final r = await AppUpdate.latest();
      setState(() => _rel = r);
      if (r == null) _updMsg = 'На GitHub не знайдено збірок застосунку';
    } catch (e) {
      setState(() => _updMsg = 'Не вдалося перевірити: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    setState(() => _progress = 0);
    try {
      await AppUpdate.downloadAndInstall(_rel!, (p) {
        if (mounted) setState(() => _progress = p);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }
}
