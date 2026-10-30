import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../background.dart';
import '../device_store.dart';
import '../notifications.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool _bg = true;
  int _interval = 15;

  @override
  void initState() {
    super.initState();
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
}
