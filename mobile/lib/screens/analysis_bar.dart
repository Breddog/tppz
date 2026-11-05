import 'package:flutter/material.dart';

import '../analysis/frame_analysis.dart';
import 'findings_screen.dart';

/// Рядок під відео: «Аналіз кадру» (знімок + розпізнавання + голос), «Знахідки» і стан аналізу.
class AnalysisBar extends StatelessWidget {
  const AnalysisBar({super.key, required this.freqHz, required this.source, this.enabled = true});

  final double Function() freqHz;
  final String source;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final a = AutoAnalyzer.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([a, FindingsStore.instance]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        child: Row(
          children: [
            FilledButton.tonalIcon(
              icon: a.capturing || a.busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.center_focus_strong),
              label: const Text('Аналіз кадру'),
              onPressed: !enabled || a.capturing ? null : () => a.manual(freqHz(), source: source),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                a.status ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(
                'Знахідки${FindingsStore.instance.items.isEmpty ? '' : ' (${FindingsStore.instance.items.length})'}',
              ),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FindingsScreen())),
            ),
          ],
        ),
      ),
    );
  }
}
