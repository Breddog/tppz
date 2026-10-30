import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../device_store.dart';
import '../models.dart';

/// Додавання модуля: QR-код, пошук у локальній мережі або вручну.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key, this.existing});

  final Device? existing;

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _name = TextEditingController();
  final _urls = TextEditingController();
  final _token = TextEditingController();
  String? _id;
  bool _busy = false;
  String? _msg;
  List<Map<String, dynamic>> _found = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _id = d.id;
      _name.text = d.name;
      _urls.text = d.urls.join('\n');
      _token.text = d.token;
    }
  }

  void _fill(Device d) {
    setState(() {
      _id = d.id;
      _name.text = d.name;
      _urls.text = d.urls.join('\n');
      _token.text = d.token;
    });
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _QrPage()));
    if (raw == null) return;
    final d = Device.fromQr(raw);
    if (d == null) {
      setState(() => _msg = 'Це не QR-код модуля SDR Watch');
      return;
    }
    _fill(d);
    await _save();
  }

  /// UDP-broadcast: модулі відповідають своїм ім'ям та портом (без токена).
  Future<void> _discover() async {
    setState(() {
      _searching = true;
      _found = [];
    });
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final sub = sock.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        try {
          final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (j['app'] != 'sdrwatch') return;
          j['url'] = 'http://${dg.address.address}:${j['port']}';
          if (!_found.any((f) => f['id'] == j['id'])) setState(() => _found.add(j));
        } catch (_) {}
      });
      for (var i = 0; i < 3; i++) {
        sock.send(utf8.encode('SDRWATCH_DISCOVER'), InternetAddress('255.255.255.255'), 47800);
        await Future.delayed(const Duration(milliseconds: 800));
      }
      await sub.cancel();
      sock.close();
    } catch (e) {
      _msg = 'Пошук недоступний: $e';
    }
    if (mounted) setState(() => _searching = false);
  }

  /// Перші 15 хв після ввімкнення модуль сам віддає токен у локальній мережі.
  Future<bool> _autoPair(String url) async {
    try {
      final r = await http.get(Uri.parse('$url/api/pair')).timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return false;
      final d = Device.fromQr(utf8.decode(r.bodyBytes));
      if (d == null) return false;
      final urls = [url, ...d.urls.where((u) => u != url)];
      _fill(Device(id: d.id, name: _name.text.trim().isEmpty ? d.name : _name.text.trim(), urls: urls, token: d.token));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _save() async {
    final urls = _urls.text
        .split(RegExp(r'[\s,]+'))
        .where((u) => u.isNotEmpty)
        .map((u) => u.startsWith('http') ? u : 'http://$u')
        .map((u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u)
        .toList();
    if (urls.isNotEmpty && _token.text.trim().isEmpty) {
      for (final u in urls) {
        if (await _autoPair(u)) break;
      }
    }
    if (urls.isEmpty || _token.text.trim().isEmpty) {
      setState(() => _msg = 'Вкажіть адресу і токен');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      // Перевірка: модуль відповідає і токен правильний
      String? id = _id;
      String name = _name.text.trim();
      for (final u in urls) {
        try {
          final r = await http.get(Uri.parse('$u/api/ping')).timeout(const Duration(seconds: 4));
          final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
          id ??= j['id'] as String;
          if (name.isEmpty) name = j['name'] as String;
          break;
        } catch (_) {}
      }
      if (id == null) throw ApiException('Модуль не відповідає за жодною з адрес');
      final d = Device(id: id, name: name.isEmpty ? 'SDR-модуль' : name, urls: urls, token: _token.text.trim());
      if (widget.existing != null) {
        d.notify = widget.existing!.notify;
        d.minPriority = widget.existing!.minPriority;
      }
      await ApiClient(d).status();
      if (!mounted) return;
      await context.read<DeviceStore>().addOrUpdate(d);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _msg = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Додати модуль' : 'Редагувати модуль')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.existing == null) ...[
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Padding(padding: EdgeInsets.all(12), child: Text('Сканувати QR-код модуля')),
              onPressed: _scanQr,
            ),
            const SizedBox(height: 6),
            const Text(
              'На Raspberry Pi виконайте: sdrwatch pair',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: _searching
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              label: const Text('Знайти в локальній мережі'),
              onPressed: _searching ? null : _discover,
            ),
            for (final f in _found)
              ListTile(
                leading: const Icon(Icons.router),
                title: Text(f['name'] as String),
                subtitle: Text(
                  f['pairing'] == true
                      ? '${f['url']} · натисніть, щоб додати'
                      : '${f['url']} · вікно сполучення закрите: перезавантажте модуль або введіть токен',
                ),
                trailing: f['pairing'] == true ? const Icon(Icons.add_circle, color: Colors.greenAccent) : null,
                onTap: () async {
                  setState(() {
                    _id = f['id'] as String;
                    _name.text = f['name'] as String;
                    _urls.text = f['url'] as String;
                  });
                  if (f['pairing'] == true && await _autoPair(f['url'] as String)) await _save();
                },
              ),
            const Divider(height: 32),
            const Text('Вручну', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Назва (напр. «Пост-1, дах»)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urls,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Адреси модуля',
              helperText:
                  'Кожна з нового рядка: локальна (192.168.1.50:8080), Tailscale/VPN, домен.\n'
                  'Застосунок сам обере доступну.',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _token,
            decoration: const InputDecoration(labelText: 'Токен доступу'),
          ),
          const SizedBox(height: 16),
          if (_msg != null) Text(_msg!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Перевірити і зберегти'),
          ),
        ],
      ),
    );
  }
}

class _QrPage extends StatefulWidget {
  const _QrPage();

  @override
  State<_QrPage> createState() => _QrPageState();
}

class _QrPageState extends State<_QrPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Наведіть камеру на QR-код')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final v = capture.barcodes.firstOrNull?.rawValue;
          if (v != null) {
            _done = true;
            Navigator.pop(context, v);
          }
        },
      ),
    );
  }
}
