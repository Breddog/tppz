import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'device_store.dart';
import 'notifications.dart';

/// Фоновий моніторинг: опитує всі модулі й показує сповіщення про нові сигнали,
/// навіть коли застосунок згорнуто (Android — foreground service, iOS — background fetch).
class BackgroundMonitor {
  static const prefEnabled = 'bg_enabled';
  static const prefInterval = 'bg_interval_s';

  static Future<void> configure() async {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: Notifications.serviceChannel,
        initialNotificationTitle: 'SDR Watch — моніторинг',
        initialNotificationContent: 'Підключення до модулів…',
        foregroundServiceNotificationId: Notifications.serviceNotificationId,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart, onBackground: onIosBackground),
    );
    final p = await SharedPreferences.getInstance();
    if (p.getBool(prefEnabled) ?? true) await service.startService();
  }

  static Future<void> setEnabled(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefEnabled, on);
    final service = FlutterBackgroundService();
    if (on) {
      if (!await service.isRunning()) await service.startService();
    } else {
      service.invoke('stop');
    }
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await Notifications.init();
  await pollOnce();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await Notifications.init();
  var running = true;
  service.on('stop').listen((_) {
    running = false;
    service.stopSelf();
  });
  while (running) {
    final summary = await pollOnce();
    if (Platform.isAndroid) await Notifications.serviceStatus(summary);
    final p = await SharedPreferences.getInstance();
    await Future.delayed(Duration(seconds: p.getInt(BackgroundMonitor.prefInterval) ?? 15));
  }
}

final Map<String, int> _failures = {};

/// Один цикл опитування. Повертає короткий підсумок для постійного сповіщення.
Future<String> pollOnce() async {
  final devices = await DeviceStore.loadRaw();
  final p = await SharedPreferences.getInstance();
  var online = 0;
  var active = 0;
  for (final d in devices) {
    final api = ApiClient(d);
    final key = 'last_event_${d.id}';
    try {
      await api.resolve(timeout: const Duration(seconds: 4));
      online++;
      if ((_failures[d.id] ?? 0) >= 3 && d.notify) {
        await Notifications.alert(
          d.id.hashCode & 0x7fffffff,
          '${d.name}: знову на зв\'язку',
          'Модуль доступний',
          high: false,
        );
      }
      _failures[d.id] = 0;
      final last = p.getInt(key);
      if (last == null) {
        // Перший запуск — не засипати сповіщеннями про стару історію
        final latest = await api.events(limit: 1);
        await p.setInt(key, latest.isEmpty ? 0 : latest.first.id);
      } else {
        final evs = await api.events(sinceId: last, limit: 50);
        var maxId = last;
        for (final e in evs) {
          if (e.id > maxId) maxId = e.id;
          if (!d.notify || e.priority < d.minPriority) continue;
          if (!const {'new', 'reacquired', 'changed'}.contains(e.kind)) continue;
          final s = e.signal;
          final title = '${d.name}: ${e.label}${e.kind == 'reacquired' ? ' (знову)' : ''}';
          await Notifications.alert(
            (d.id.hashCode ^ e.id) & 0x7fffffff,
            title,
            s.hint,
            high: e.priority >= 2,
            payload: '${d.id}|${e.id}',
          );
        }
        await p.setInt(key, maxId);
      }
      final st = await api.status();
      active += (st['active_signals'] as int?) ?? 0;
    } catch (_) {
      final n = (_failures[d.id] ?? 0) + 1;
      _failures[d.id] = n;
      if (n == 3 && d.notify) {
        await Notifications.alert(
          d.id.hashCode & 0x7fffffff,
          '${d.name}: немає зв\'язку',
          'Модуль не відповідає вже ~1 хв. Перевірте живлення та мережу.',
        );
      }
    }
  }
  if (devices.isEmpty) return 'Модулі не додано';
  return 'Онлайн: $online/${devices.length} · активних сигналів: $active';
}
