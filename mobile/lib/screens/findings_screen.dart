import 'dart:io';

import 'package:flutter/material.dart';

import '../analysis/frame_analysis.dart';

/// «Знахідки»: знімки знайденого відео з розпізнаним текстом екрана, мітками та описом ШІ.
class FindingsScreen extends StatefulWidget {
  const FindingsScreen({super.key});

  @override
  State<FindingsScreen> createState() => _FindingsScreenState();
}

class _FindingsScreenState extends State<FindingsScreen> {
  final store = FindingsStore.instance;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  String _time(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Знахідки'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Очистити все',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Видалити всі знахідки?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Ні')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Видалити')),
                  ],
                ),
              );
              if (ok == true) await store.clear();
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) => store.items.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Тут з\'являтимуться знімки відео, знайденого автосканом:\n'
                    'найкращий кадр, текст з екрана (OSD), що на кадрі та опис ШІ.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 30),
                itemCount: store.items.length,
                itemBuilder: (_, i) {
                  final f = store.items[i];
                  return Card(
                    margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    child: InkWell(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FindingDetail(f: f))),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 128,
                              height: 96,
                              child: Image.file(File(f.imagePath), fit: BoxFit.fill, gaplessPlayback: true),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${(f.freqHz / 1e6).toStringAsFixed(0)} МГц'
                                    '${f.standard != null ? ' · ${f.standard}' : ''}',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    '${_time(f.time)}${f.source.isNotEmpty ? ' · ${f.source}' : ''}',
                                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                                  ),
                                  if (f.labels.isNotEmpty)
                                    Text(f.labels.join(', '), style: const TextStyle(fontSize: 12.5)),
                                  if (f.ocrText.isNotEmpty)
                                    Text(
                                      'Екран: ${f.ocrText.replaceAll('\n', ' · ')}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, color: Colors.cyanAccent),
                                    ),
                                  if (f.aiText != null)
                                    Text(
                                      f.aiText!,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class FindingDetail extends StatefulWidget {
  const FindingDetail({super.key, required this.f});

  final Finding f;

  @override
  State<FindingDetail> createState() => _FindingDetailState();
}

class _FindingDetailState extends State<FindingDetail> {
  bool _ai = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    return Scaffold(
      appBar: AppBar(
        title: Text('${(f.freqHz / 1e6).toStringAsFixed(0)} МГц'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await FindingsStore.instance.remove(f);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.file(File(f.imagePath), fit: BoxFit.fill),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.volume_up),
                label: const Text('Озвучити'),
                onPressed: () => Speaker.say(f.spoken()),
              ),
              OutlinedButton.icon(
                icon: _ai
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(f.aiText == null ? 'Опис ШІ' : 'Оновити опис ШІ'),
                onPressed: _ai
                    ? null
                    : () async {
                        if (AnalysisSettings.apiKey.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Введіть ключ API: Налаштування → Аналіз кадрів')),
                          );
                          return;
                        }
                        setState(() => _ai = true);
                        await AutoAnalyzer.describeWithAi(f);
                        if (mounted) setState(() => _ai = false);
                        if (f.aiText != null) Speaker.say(f.aiText!);
                      },
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (f.labels.isNotEmpty) _Section('На кадрі', f.labels.join(', ')),
          if (f.ocrText.isNotEmpty) _Section('Текст на екрані (OSD)', f.ocrText),
          if (f.aiText != null) _Section('Опис ШІ', f.aiText!),
          if (f.aiError != null) _Section('ШІ', f.aiError!, color: Colors.orangeAccent),
          if (f.labels.isEmpty && f.ocrText.isEmpty && f.aiText == null)
            const Text(
              'Нічого не розпізнано на телефоні. Спробуйте «Опис ШІ» (потрібен інтернет).',
              style: TextStyle(color: Colors.white54),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.text, {this.color});

  final String title, text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent),
        ),
        const SizedBox(height: 4),
        SelectableText(text, style: TextStyle(color: color)),
      ],
    ),
  );
}
