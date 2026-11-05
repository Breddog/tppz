import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../netbind.dart';
import 'update_section.dart' show kUpdateRepo;

/// База частотних сіток усіх відомих виробників (на модулі). Оновлюється з GitHub без перепрошивки:
/// телефон завантажує свіжий channels.json з останнього релізу модуля й передає його модулю.
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  Map<String, dynamic>? _db;
  String? _msg;
  bool _busy = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.get('/api/channels') as Map<String, dynamic>;
      if (mounted) setState(() => _db = r);
    } catch (e) {
      if (mounted) setState(() => _msg = e.toString());
    }
  }

  /// Найновіший channels.json серед релізів модуля (pi-N з найбільшим N).
  static Future<Map<String, dynamic>> fetchLatest() => NetBind.forInternet(() async {
    final r = await http
        .get(
          Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases?per_page=100'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('GitHub: HTTP ${r.statusCode}');
    String? url;
    var best = -1;
    for (final rel in (jsonDecode(r.body) as List).cast<Map<String, dynamic>>()) {
      final tag = rel['tag_name'] as String? ?? '';
      if (!tag.startsWith('pi-')) continue;
      final n = int.tryParse(tag.substring(3)) ?? -1;
      for (final a in (rel['assets'] as List).cast<Map<String, dynamic>>()) {
        if (a['name'] == 'channels.json' && n > best) {
          best = n;
          url = a['browser_download_url'] as String;
        }
      }
    }
    if (url == null) throw Exception('На GitHub ще немає бази сіток (з’явиться з наступним релізом модуля)');
    final f = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (f.statusCode != 200) throw Exception('Завантаження: HTTP ${f.statusCode}');
    return jsonDecode(utf8.decode(f.bodyBytes)) as Map<String, dynamic>;
  });

  Future<void> _update() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final db = await fetchLatest();
      final cur = (_db?['version'] as num?)?.toInt() ?? 0;
      final nv = (db['version'] as num?)?.toInt() ?? 0;
      if (nv <= cur) {
        _msg = 'У модуля вже найновіша база (версія $cur)';
      } else {
        final r = await widget.api.put('/api/channels', db) as Map<String, dynamic>;
        _msg = 'Оновлено до версії ${r['version']}: ${r['bands']} сіток, ${r['channels']} каналів';
        await _load();
      }
    } catch (e) {
      _msg = 'Не вдалося оновити: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = _db;
    final bands = ((db?['bands'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final links = ((db?['links'] as List?) ?? const []).cast<Map<String, dynamic>>();
    bool match(Map<String, dynamic> b) {
      if (_q.isEmpty) return true;
      final q = _q.toLowerCase();
      return '${b['code']} ${b['title']} ${(b['makers'] as List?)?.join(' ')} ${b['group']}'.toLowerCase().contains(
            q,
          ) ||
          (b['channels'] as List).any((c) => ((c['freq_hz'] as num) / 1e6).toStringAsFixed(0).contains(q));
    }

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final b in bands.where(match)) {
      groups.putIfAbsent((b['group'] as String?)?.isNotEmpty == true ? b['group'] as String : 'Інше', () => []).add(b);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('База частотних сіток')),
      body: db == null
          ? Center(child: _msg == null ? const CircularProgressIndicator() : Text(_msg!))
          : ListView(
              padding: const EdgeInsets.only(bottom: 30),
              children: [
                ListTile(
                  leading: const Icon(Icons.storage),
                  title: Text('Версія ${db['version']}${db['updated'] != null ? ' від ${db['updated']}' : ''}'),
                  subtitle: Text(
                    '${bands.length} сіток · ${bands.fold<int>(0, (s, b) => s + (b['channels'] as List).length)} каналів · '
                    '${links.length} діапазонів лінків керування',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_download),
                    label: const Text('Оновити з інтернету'),
                    onPressed: _busy ? null : _update,
                  ),
                ),
                if (_msg != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(_msg!)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Пошук: виробник, сітка або частота (напр. 5800)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _q = v.trim()),
                  ),
                ),
                for (final g in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Text(
                      g.key,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent),
                    ),
                  ),
                  for (final b in g.value)
                    ExpansionTile(
                      title: Text('${b['code']} — ${b['title']}${b['popular'] == true ? '  ★' : ''}'),
                      subtitle: Text(
                        [
                          if ((b['makers'] as List?)?.isNotEmpty == true) (b['makers'] as List).join(', '),
                          '${(b['channels'] as List).length} кан. · ${((b['bandwidth_hz'] as num) / 1e6).toStringAsFixed(0)} МГц',
                        ].join('\n'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((b['note'] as String?)?.isNotEmpty == true)
                          Text(b['note'] as String, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final c in (b['channels'] as List).cast<Map<String, dynamic>>())
                              Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text('${c['name']} ${((c['freq_hz'] as num) / 1e6).toStringAsFixed(0)}'),
                              ),
                          ],
                        ),
                      ],
                    ),
                ],
                if (_q.isEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Text(
                      'Лінки керування й телеметрії',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent),
                    ),
                  ),
                  for (final r in links)
                    ListTile(
                      dense: true,
                      title: Text(r['name'] as String),
                      subtitle: Text(
                        '${((r['start_hz'] as num) / 1e6).toStringAsFixed(0)}–${((r['stop_hz'] as num) / 1e6).toStringAsFixed(0)} МГц · ${r['kind']}',
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
