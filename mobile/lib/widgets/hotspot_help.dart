import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../announcements.dart';

/// Підказка: як підключити модуль через точку доступу телефону, коли немає інтернету
/// або спільної Wi-Fi мережі.
class HotspotHelp extends StatelessWidget {
  const HotspotHelp({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.wifi_tethering),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Немає інтернету чи спільної мережі?', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Увімкніть на цьому телефоні точку доступу з такими даними:'),
            const SizedBox(height: 8),
            _Field(label: 'Назва мережі', value: kHotspotSsid),
            _Field(label: 'Пароль', value: kHotspotPassword),
            const SizedBox(height: 8),
            Text(
              'Модуль сам підключиться до неї приблизно за 1 хвилину і з\'явиться в застосунку'
              '${compact ? '' : ' (у списку «Знайти в локальній мережі» або на головному екрані)'}. '
              'Мобільний інтернет для цього не потрібен.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (Platform.isIOS)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'На iPhone назва точки доступу — це ім\'я телефону: Параметри → Загальні → Про пристрій → Назва '
                  '→ «sdrdetect». Пароль: Параметри → Режим модема.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            if (Platform.isAndroid) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('Відкрити налаштування точки доступу'),
                onPressed: () => AppSettings.openAppSettings(type: AppSettingsType.hotspot),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(color: Colors.white60)),
        ),
        SelectableText(
          value,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.bold),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Копіювати',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Скопійовано: $value')));
          },
        ),
      ],
    ),
  );
}
