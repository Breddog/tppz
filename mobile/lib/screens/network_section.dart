import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';

typedef CallFn = Future<void> Function(Future<dynamic> Function() f, [String? ok]);

/// Режим користувачів: багатокористувацький або «тільки один».
class UsersSection extends StatefulWidget {
  const UsersSection({super.key, required this.api, required this.call, required this.onClaim});

  final ApiClient api;
  final CallFn call;
  final VoidCallback onClaim;

  @override
  State<UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends State<UsersSection> {
  Map<String, dynamic>? _h;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.get('/api/control/holder') as Map<String, dynamic>;
      if (mounted) setState(() => _h = j);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    final multi = h?['multi_user'] as bool? ?? true;
    final who = h?['name'] as String? ?? '';
    final viewers = h?['viewers'] as int?;
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Багатокористувацький режим'),
          subtitle: Text(
            multi
                ? 'Кілька телефонів можуть керувати й дивитися одночасно'
                      '${viewers != null ? ' · глядачів: $viewers' : ''}'
                : 'Тільки один користувач керує, решта — лише перегляд'
                      '${who.isNotEmpty ? ' · керує: $who' : ''}',
          ),
          value: multi,
          onChanged: (v) async {
            await widget.call(() => widget.api.post('/api/control/multi_user?on=$v'), 'Режим змінено');
            _load();
          },
        ),
        if (!multi)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.pan_tool_alt),
              label: const Text('Перехопити керування'),
              onPressed: () {
                widget.onClaim();
                Future.delayed(const Duration(milliseconds: 600), _load);
              },
            ),
          ),
      ],
    );
  }
}

/// Мережа модуля: інтерфейси/IP, поточний Wi-Fi, додавання Wi-Fi.
class NetworkSection extends StatefulWidget {
  const NetworkSection({super.key, required this.api, required this.call});

  final ApiClient api;
  final CallFn call;

  @override
  State<NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<NetworkSection> {
  Map<String, dynamic>? _net;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.get('/api/network') as Map<String, dynamic>;
      if (mounted) setState(() => _net = j);
    } catch (_) {}
  }

  Future<void> _addWifi() async {
    final ssidCtl = TextEditingController();
    final pskCtl = TextEditingController();
    List<Map<String, dynamic>> near = [];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Додати Wi-Fi'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ssidCtl,
                  decoration: const InputDecoration(labelText: 'Назва мережі (SSID)'),
                ),
                TextField(
                  controller: pskCtl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль (порожньо — відкрита)'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.wifi_find),
                  label: const Text('Показати мережі поблизу'),
                  onPressed: () async {
                    try {
                      final j = await widget.api.get('/api/network/scan') as Map<String, dynamic>;
                      setD(() => near = (j['networks'] as List).cast<Map<String, dynamic>>());
                    } catch (_) {}
                  },
                ),
                for (final n in near.take(12))
                  ListTile(
                    dense: true,
                    title: Text(n['ssid'] as String),
                    trailing: Text('${n['signal']}%'),
                    onTap: () => setD(() => ssidCtl.text = n['ssid'] as String),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Скасувати')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Підключитися')),
          ],
        ),
      ),
    );
    if (ok == true && ssidCtl.text.trim().isNotEmpty) {
      await widget.call(
        () => widget.api.post('/api/network/wifi', {'ssid': ssidCtl.text.trim(), 'password': pskCtl.text}),
        'Wi-Fi збережено',
      );
      Future.delayed(const Duration(seconds: 2), _load);
    }
  }

  @override
  Widget build(BuildContext context) {
    final net = _net;
    final ifaces = (net?['interfaces'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final wifi = (net?['wifi'] as Map?)?['connected_ssid'] as Map<String, dynamic>?;
    final saved = (net?['saved_wifi'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final i in ifaces)
          ListTile(
            dense: true,
            leading: Icon(i['type'] == 'wifi' ? Icons.wifi : Icons.lan),
            title: Text('${i['device']} · ${(i['ips'] as List?)?.join(', ') ?? '—'}'),
            subtitle: Text(
              '${i['type']}${(i['connection'] ?? '').toString().isNotEmpty ? ' · ${i['connection']}' : ''}',
            ),
          ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.wifi_tethering),
          title: Text(wifi != null ? 'Wi-Fi: ${wifi['ssid']}' : 'Wi-Fi не підключено'),
          subtitle: const Text('Резервна точка доступу телефону: sdrdetect / 12345678'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Додати Wi-Fi'),
                  onPressed: _addWifi,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
        ),
        if (saved.isNotEmpty)
          ExpansionTile(
            title: Text('Збережені мережі (${saved.length})', style: const TextStyle(fontSize: 14)),
            initiallyExpanded: _expanded,
            onExpansionChanged: (v) => _expanded = v,
            children: [
              for (final w in saved)
                ListTile(
                  dense: true,
                  title: Text(w['name'] as String),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      await widget.call(
                        () => widget.api.post('/api/network/forget?name=${Uri.encodeComponent(w['name'] as String)}'),
                        'Забуто',
                      );
                      Future.delayed(const Duration(seconds: 1), _load);
                    },
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
