import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api.dart';

/// Репозиторій з релізами pi-N (ПЗ модуля) і hackrf-N (прошивка HackRF).
const kUpdateRepo = 'Breddog/tppz';

class _Release {
  _Release(this.tag, this.url, this.shaUrl);

  final String tag;
  final String url;
  final String? shaUrl;

  int get number => int.tryParse(tag.split('-').last) ?? 0;
}

/// Розділ «Оновлення» на вкладці «Керування»: ПЗ модуля і прошивка HackRF, у т.ч. віддалено.
class UpdateSection extends StatefulWidget {
  const UpdateSection({super.key, required this.api});

  final ApiClient api;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  static const _assets = {'pi': 'sdrwatch-pi.tar.gz', 'hackrf': 'hackrf_one_usb-sdrwatch.bin'};

  Map<String, dynamic>? _info;
  Map<String, _Release> _latest = {};
  bool _checking = false;
  String? _progress;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    try {
      final j = await widget.api.get('/api/update') as Map<String, dynamic>;
      if (mounted) setState(() => _info = j);
    } catch (_) {}
  }

  /// Останні релізи з GitHub — через інтернет телефону, а якщо його немає — через модуль.
  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final out = <String, _Release>{};
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases?per_page=30'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      for (final rel in (jsonDecode(r.body) as List).cast<Map<String, dynamic>>()) {
        final tag = rel['tag_name'] as String;
        final assets = {
          for (final a in (rel['assets'] as List).cast<Map<String, dynamic>>())
            a['name'] as String: a['browser_download_url'] as String,
        };
        for (final e in _assets.entries) {
          if (!out.containsKey(e.key) && tag.startsWith('${e.key}-') && assets.containsKey(e.value)) {
            out[e.key] = _Release(tag, assets[e.value]!, assets['${e.value}.sha256']);
          }
        }
      }
    } catch (_) {
      try {
        final j = await widget.api.get('/api/update/available') as Map<String, dynamic>;
        j.forEach((k, v) {
          final m = v as Map<String, dynamic>;
          out[k] = _Release(m['tag'] as String, m['url'] as String, m['sha256_url'] as String?);
        });
      } catch (e) {
        _error = 'Немає доступу до GitHub ні з телефону, ні з модуля';
      }
    }
    if (mounted) {
      setState(() {
        _latest = out;
        _checking = false;
      });
    }
  }

  Future<void> _install(String kind) async {
    final rel = _latest[kind];
    if (rel == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(kind == 'pi' ? 'Оновити ПЗ модуля?' : 'Прошити HackRF?'),
        content: Text(
          kind == 'pi'
              ? 'Буде встановлено ${rel.tag}. Сканування зупиниться приблизно на хвилину, налаштування й історія '
                    'збережуться.'
              : 'Буде записано прошивку ${rel.tag} (режим «лише приймання»). Сканування зупиниться на ~1 хв.\n\n'
                    'Не вимикайте живлення модуля під час запису. Якщо щось піде не так, HackRF можна відновити '
                    'через кнопку DFU (інструкція в hackrf/README.md).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Встановити')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _error = null;
      _progress = 'Завантаження ${rel.tag} на телефон…';
    });
    try {
      // 1) Телефон завантажує файл і передає модулю — працює, навіть коли в модуля немає інтернету
      final file = await http.get(Uri.parse(rel.url)).timeout(const Duration(minutes: 2));
      final shaFile = rel.shaUrl == null
          ? null
          : await http.get(Uri.parse(rel.shaUrl!)).timeout(const Duration(seconds: 30));
      if (file.statusCode != 200 || shaFile == null || shaFile.statusCode != 200) {
        throw Exception('файл недоступний');
      }
      final sha = shaFile.body.trim().split(RegExp(r'\s+')).first;
      setState(() => _progress = 'Передача на модуль (${(file.bodyBytes.length / 1024).round()} КБ)…');
      await widget.api.upload('/api/update/upload', {'kind': kind, 'sha256': sha, 'tag': rel.tag}, file.bodyBytes);
    } on ApiException catch (e) {
      setState(() {
        _progress = null;
        _error = e.message;
      });
      return;
    } catch (_) {
      // 2) У телефона немає інтернету — нехай модуль завантажить сам
      try {
        setState(() => _progress = 'Модуль завантажує оновлення сам…');
        await widget.api.post('/api/update/fetch?kind=$kind');
      } catch (e) {
        setState(() {
          _progress = null;
          _error = 'Не вдалося отримати оновлення: $e';
        });
        return;
      }
    }
    setState(() => _progress = 'Встановлення на модулі…');
    _watch();
  }

  /// Стежити за статусом; під час оновлення ПЗ модуль перезапускається — помилки зв'язку очікувані.
  void _watch() {
    _poll?.cancel();
    final started = DateTime.now();
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      try {
        final j = await widget.api.get('/api/update') as Map<String, dynamic>;
        final st = (j['status'] as Map?)?.cast<String, dynamic>() ?? {};
        if (!mounted) return;
        setState(() {
          _info = j;
          _progress = st['state'] == 'ok' || st['state'] == 'error' ? null : (st['message'] as String? ?? _progress);
        });
        if (st['state'] == 'ok' || st['state'] == 'error') t.cancel();
      } catch (_) {
        if (mounted) setState(() => _progress = 'Модуль перезапускається…');
      }
      if (DateTime.now().difference(started).inMinutes > 15) {
        t.cancel();
        if (mounted) setState(() => _progress = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final st = (i?['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    final build = i?['build'] as String?;
    final fw = i?['hackrf_firmware'] as String?;
    final busy = _progress != null || st['state'] == 'running' || st['state'] == 'queued';
    final piRel = _latest['pi'];
    final hfRel = _latest['hackrf'];
    final piNewer = piRel != null && (build == null || piRel.number > (int.tryParse(build.split('-').last) ?? 0));
    // На HackRF ще стокова прошивка — пропонуємо редакцію SDR Watch («лише приймання»)
    final hfNewer = hfRel != null && (fw == null || !fw.contains('sdrwatch'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.memory),
          title: const Text('ПЗ модуля'),
          subtitle: Text('${i?['sdrwatch_version'] ?? '…'}${build != null ? ' · $build' : ''}'),
          trailing: piRel == null
              ? null
              : FilledButton.tonal(
                  onPressed: busy ? null : () => _install('pi'),
                  child: Text(piNewer ? 'Оновити до ${piRel.tag}' : 'Перевстановити'),
                ),
        ),
        ListTile(
          leading: const Icon(Icons.settings_input_antenna),
          title: const Text('Прошивка HackRF'),
          subtitle: Text(
            fw == null
                ? 'невідомо (HackRF не підключено або інший SDR)'
                : '$fw${i?['rx_only_firmware'] == true ? ' · лише приймання' : ' · стокова'}',
          ),
          trailing: hfRel == null
              ? null
              : FilledButton.tonal(
                  onPressed: busy ? null : () => _install('hackrf'),
                  child: Text(hfNewer ? 'Прошити ${hfRel.tag}' : 'Перепрошити (${hfRel.tag})'),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            icon: _checking
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.system_update),
            label: const Text('Перевірити оновлення'),
            onPressed: _checking || busy ? null : _check,
          ),
        ),
        if (_progress != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(child: Text(_progress!)),
              ],
            ),
          ),
        if (_progress == null && (st['state'] == 'ok' || st['state'] == 'error'))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(
              st['message'] as String? ?? '',
              style: TextStyle(color: st['state'] == 'ok' ? Colors.greenAccent : Colors.redAccent),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ),
        if ((st['log'] as String?)?.isNotEmpty ?? false)
          ExpansionTile(
            title: const Text('Журнал останнього оновлення', style: TextStyle(fontSize: 13)),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  st['log'] as String,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
