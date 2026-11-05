// Візуальна перевірка екранів на реальних даних із симулятора модуля.
// Запуск: FIXTURES=/шлях/до/fx flutter test test/ui_golden_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sdrwatch/api.dart';
import 'package:sdrwatch/live.dart';
import 'package:sdrwatch/models.dart';
import 'package:sdrwatch/screens/device_screen.dart';
import 'package:sdrwatch/widgets/signal_widgets.dart';

final fx = Platform.environment['FIXTURES'];

Future<void> loadFonts() async {
  final base = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Bold.ttf', 'Roboto-Medium.ttf']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$base/$f').readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$base/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

LiveConnection fakeLive() {
  final dev = Device(id: 'x', name: 'Пост-1', urls: ['http://127.0.0.1:9'], token: 't');
  final l = LiveConnection(ApiClient(dev))..connected = true;
  for (final m in jsonDecode(File('$fx/live.json').readAsStringSync()) as List) {
    l.ingest(jsonEncode(m));
  }
  return l;
}

Widget wrap(Widget child, LiveConnection l) => ChangeNotifierProvider.value(
  value: l,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00BCD4), brightness: Brightness.dark),
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: const Color(0xFF0B0D12),
      cardTheme: const CardThemeData(color: Color(0xFF161A22), elevation: 0),
    ),
    home: Scaffold(body: SafeArea(child: child)),
  ),
);

void main() {
  if (fx == null) {
    test('UI goldens', () {}, skip: 'Задайте FIXTURES — теку з дампом живих даних модуля');
    return;
  }
  setUpAll(loadFonts);

  testWidgets('live tab', (t) async {
    await t.binding.setSurfaceSize(const Size(420, 860));
    final l = fakeLive();
    await t.runAsync(() async {
      await t.pumpWidget(wrap(LiveTab(onSignal: (_) {}), l));
      await Future.delayed(const Duration(milliseconds: 300));
    });
    await t.pump();
    await expectLater(find.byType(LiveTab), matchesGoldenFile('goldens/live.png'));
  });

  testWidgets('signals tab', (t) async {
    await t.binding.setSurfaceSize(const Size(420, 860));
    final l = fakeLive();
    await t.pumpWidget(wrap(SignalsTab(onSignal: (_) {}, onWatch: (_) {}), l));
    await t.pump();
    await expectLater(find.byType(SignalsTab), matchesGoldenFile('goldens/signals.png'));
  });

  testWidgets('hints', (t) async {
    await t.binding.setSurfaceSize(const Size(420, 400));
    final l = fakeLive();
    await t.pumpWidget(wrap(HintsPanel(signals: l.signals), l));
    await expectLater(find.byType(HintsPanel), matchesGoldenFile('goldens/hints.png'));
  });
}
