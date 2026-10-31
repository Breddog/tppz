import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'device_store.dart';

/// Точка доступу телефону, до якої модуль підключається сам, коли немає інтернету
/// або спільної мережі (див. pi/image/sdrwatch-netwatch.sh).
const kHotspotSsid = 'sdrdetect';
const kHotspotPassword = '12345678';

/// Приймає оголошення «я тут» від модулів (UDP 47801).
///
/// Модуль надсилає їх кожні 3 с у broadcast і напряму шлюзу — на точці доступу шлюз і є
/// телефоном. Так застосунок дізнається нову IP-адресу модуля без жодного пошуку.
class Announcements {
  Announcements._();

  static const port = 47801;
  static final _found = StreamController<Map<String, dynamic>>.broadcast();
  static RawDatagramSocket? _sock;

  /// Усі оголошення з доданим полем url (`http://ip:port`).
  static Stream<Map<String, dynamic>> get stream => _found.stream;

  /// store — у застосунку; null — у фоновому сервісі (тоді адреса пишеться прямо в налаштування).
  static Future<void> start({DeviceStore? store}) async {
    if (_sock != null) return;
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true, reusePort: true);
    } catch (_) {
      try {
        _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      } catch (_) {
        return; // порт зайнятий іншим ізолятом — він і оновлює адреси
      }
    }
    _sock!.broadcastEnabled = true;
    _sock!.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final dg = _sock?.receive();
      if (dg == null) return;
      try {
        final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (j['app'] != 'sdrwatch') return;
        final url = 'http://${dg.address.address}:${j['port']}';
        j['url'] = url;
        _found.add(j);
        final id = j['id'] as String;
        ApiClient.noteWorking(id, url);
        if (store != null) {
          store.rememberAddress(id, url);
        } else {
          DeviceStore.rememberAddressRaw(id, url);
        }
      } catch (_) {}
    });
  }

  /// Адреси broadcast усіх мереж телефону (у т.ч. його власної точки доступу).
  static Future<List<InternetAddress>> broadcastTargets() async {
    final out = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          final p = a.address.split('.');
          if (p.length == 4 && !a.isLoopback) out.add(InternetAddress('${p[0]}.${p[1]}.${p[2]}.255'));
        }
      }
    } catch (_) {}
    return out;
  }
}
