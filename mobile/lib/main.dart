import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'announcements.dart';
import 'api.dart';
import 'app_update.dart';
import 'netbind.dart';
import 'background.dart';
import 'device_store.dart';
import 'notifications.dart';
import 'screens/home_screen.dart';

/// Стабільний id цього телефону + його ім'я (для режиму «тільки один користувач»).
Future<void> _initClientId() async {
  try {
    final p = await SharedPreferences.getInstance();
    var id = p.getString('client_id');
    if (id == null) {
      id =
          'phone-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(1 << 32).toRadixString(36)}';
      await p.setString('client_id', id);
    }
    ApiClient.clientId = id;
    ApiClient.clientName = p.getString('client_name') ?? '';
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifications.init(requestPermission: true);
  await _initClientId();
  await NetBind.wifi(); // Wi-Fi без інтернету (модуль/точка доступу) — запити до модуля йдуть через Wi-Fi
  final store = DeviceStore();
  await store.load();
  await Announcements.start(store: store);
  try {
    await BackgroundMonitor.configure();
  } catch (_) {
    // Фоновий сервіс недоступний (напр. на емуляторі без служб) — застосунок працює і без нього
  }
  runApp(ChangeNotifierProvider.value(value: store, child: const SdrWatchApp()));
  // Раз на добу — чи є новіша збірка застосунку (через інтернет телефона, модуль не потрібен)
  AppUpdate.dailyCheck().then((r) {
    if (r != null) {
      Notifications.alert(
        777,
        'Доступне оновлення SDR Watch',
        'Збірка ${r.number}. Налаштування (шестерня) → Оновлення застосунку.',
        high: false,
      );
    }
  });
}

class SdrWatchApp extends StatelessWidget {
  const SdrWatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00BCD4),
      brightness: Brightness.dark,
      surface: const Color(0xFF0E1116),
    );
    return MaterialApp(
      title: 'SDR Watch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
        cardTheme: const CardThemeData(color: Color(0xFF161A22), elevation: 0),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0B0D12)),
      ),
      home: const HomeScreen(),
    );
  }
}
