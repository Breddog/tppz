import 'package:flutter/material.dart';

import '../analysis/frame_analysis.dart';
import 'findings_screen.dart';

/// Налаштування «Аналіз кадрів» (розділ у Налаштуваннях застосунку).
class AnalysisSettingsSection extends StatefulWidget {
  const AnalysisSettingsSection({super.key});

  @override
  State<AnalysisSettingsSection> createState() => _AnalysisSettingsSectionState();
}

class _AnalysisSettingsSectionState extends State<AnalysisSettingsSection> {
  late final _key = TextEditingController(text: AnalysisSettings.apiKey);
  bool _show = false;

  void _set(void Function() f) {
    setState(f);
    AnalysisSettings.save();
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.image_search),
      title: const Text('Аналіз кадрів', style: TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(
        AnalysisSettings.auto
            ? 'Знайдене відео: знімок, розпізнавання${AnalysisSettings.ai ? ', опис ШІ' : ''}${AnalysisSettings.speak ? ', голос' : ''}'
            : 'Вимкнено',
        style: const TextStyle(fontSize: 12),
      ),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Автоматично для знайденого відео'),
          subtitle: const Text('Під час автоскану: знімок найкращого кадру й розпізнавання'),
          value: AnalysisSettings.auto,
          onChanged: (v) => _set(() => AnalysisSettings.auto = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Озвучувати'),
          subtitle: const Text('Голосом телефона (українська — якщо встановлено голос у синтезі мовлення)'),
          value: AnalysisSettings.speak,
          onChanged: (v) => _set(() => AnalysisSettings.speak = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Текст на екрані (OSD)'),
          subtitle: const Text('Без інтернету: напруга, висота, координати, позивний'),
          value: AnalysisSettings.ocr,
          onChanged: (v) => _set(() => AnalysisSettings.ocr = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Що на кадрі'),
          subtitle: const Text('Без інтернету: будівлі, дороги, техніка, люди, ліс, вода'),
          value: AnalysisSettings.labels,
          onChanged: (v) => _set(() => AnalysisSettings.labels = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Детальний опис ШІ (Claude)'),
          subtitle: const Text('Потрібен інтернет і ключ API Anthropic; кадр надсилається на сервер'),
          value: AnalysisSettings.ai,
          onChanged: (v) => _set(() => AnalysisSettings.ai = v),
        ),
        if (AnalysisSettings.ai) ...[
          TextField(
            controller: _key,
            obscureText: !_show,
            decoration: InputDecoration(
              labelText: 'Ключ API (console.anthropic.com)',
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
            onChanged: (v) {
              AnalysisSettings.apiKey = v.trim();
              AnalysisSettings.save();
            },
          ),
          DropdownButtonFormField<String>(
            initialValue: AnalysisSettings.model,
            decoration: const InputDecoration(labelText: 'Модель', isDense: true),
            items: [
              for (final e in AnalysisSettings.models.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => _set(() => AnalysisSettings.model = v ?? AnalysisSettings.model),
          ),
          const SizedBox(height: 6),
        ],
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Повторно ту саму частоту — не частіше'),
          trailing: DropdownButton<int>(
            value: AnalysisSettings.repeatMin,
            items: [
              for (final m in const [1, 3, 5, 10, 30]) DropdownMenuItem(value: m, child: Text('$m хв')),
            ],
            onChanged: (v) => _set(() => AnalysisSettings.repeatMin = v ?? AnalysisSettings.repeatMin),
          ),
        ),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.record_voice_over),
              label: const Text('Перевірити голос'),
              onPressed: () =>
                  Speaker.say('Відео п\'ять тисяч вісімсот шістдесят п\'ять мегагерц. На кадрі: поле, дорога.'),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Знахідки'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FindingsScreen())),
            ),
          ],
        ),
      ],
    );
  }
}
