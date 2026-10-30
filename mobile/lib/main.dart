import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'background.dart';
import 'device_store.dart';
import 'notifications.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifications.init(requestPermission: true);
  final store = DeviceStore();
  await store.load();
  try {
    await BackgroundMonitor.configure();
  } catch (_) {
    // Фоновий сервіс недоступний (напр. на емуляторі без служб) — застосунок працює і без нього
  }
  runApp(ChangeNotifierProvider.value(value: store, child: const SdrWatchApp()));
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
