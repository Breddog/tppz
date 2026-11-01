import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'netbind.dart';

/// Номер збірки APK (задається в CI: --dart-define=APP_BUILD=N).
const appBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'dev');

String _short(Object e) {
  if (e is TimeoutException) return 'немає відповіді (тайм-аут)';
  if (e is SocketException) return 'немає з\'єднання (${e.osError?.message ?? e.message})';
  final s = e.toString();
  return s.length > 80 ? s.substring(0, 80) : s;
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Керує інший користувач (режим «тільки один»). HTTP 423.
class ControlLockedException extends ApiException {
  ControlLockedException(super.message);
}

/// Клієнт API одного модуля. Пробує всі адреси модуля (LAN, VPN, домен) і запам'ятовує робочу.
class ApiClient {
  ApiClient(this.device);

  final Device device;
  String? _base;
  static final Map<String, String> _workingBase = {};

  /// Стабільний ідентифікатор цього телефону (для режиму «тільки один користувач»).
  static String clientId = 'phone';
  static String clientName = '';

  String get base => _base ?? _workingBase[device.id] ?? device.urls.first;

  /// Модуль сам повідомив свою адресу (оголошення UDP) — пробувати її першою.
  static void noteWorking(String deviceId, String url) => _workingBase[deviceId] = url;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${device.token}',
    'Content-Type': 'application/json',
    'X-Client-Id': clientId,
  };

  /// Знайти адресу, на якій модуль відповідає.
  Future<String> resolve({Duration timeout = const Duration(seconds: 5)}) async {
    _base = null;
    final errors = <String>[];
    final candidates = [
      if (_workingBase[device.id] != null) _workingBase[device.id]!,
      ...device.urls.where((u) => u != _workingBase[device.id]),
    ];
    for (final u in candidates) {
      try {
        final r = await http.get(Uri.parse('$u/api/ping')).timeout(timeout);
        if (r.statusCode == 200) {
          _base = u;
          _workingBase[device.id] = u;
          return u;
        }
        errors.add('$u → HTTP ${r.statusCode}');
      } catch (e) {
        errors.add('$u → ${_short(e)}');
      }
    }
    // Можливо, телефон шле запити через мобільний інтернет — прив'язатися до Wi-Fi й спробувати ще раз
    if (!NetBind.bound && await NetBind.wifi()) return resolve(timeout: timeout);
    throw ApiException('Модуль недоступний:\n${errors.join('\n')}');
  }

  Uri uri(String path, [Map<String, dynamic>? q]) {
    final u = Uri.parse('$base$path');
    return u.replace(queryParameters: {...u.queryParameters, if (q != null) ...q.map((k, v) => MapEntry(k, '$v'))});
  }

  /// Адреса з токеном у параметрі — для Image.network і WebSocket.
  String authUrl(String path) => uri(path, {'token': device.token}).toString();

  String wsUrl(String path) {
    final u = Uri.parse(authUrl(path));
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws').toString();
  }

  Future<dynamic> _send(
    Future<http.Response> Function() fn, {
    bool retry = true,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final r = await fn().timeout(timeout);
      if (r.statusCode == 401) throw ApiException('Невірний токен доступу');
      if (r.statusCode >= 400) {
        String msg = 'Помилка ${r.statusCode}';
        try {
          msg = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['detail']?.toString() ?? msg;
        } catch (_) {}
        if (r.statusCode == 423) throw ControlLockedException(msg); // керує інший користувач
        throw ApiException(msg);
      }
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on SocketException {
      if (retry) {
        await resolve();
        return _send(fn, retry: false, timeout: timeout);
      }
      throw ApiException('Немає зв\'язку з модулем');
    } on TimeoutException {
      if (retry) {
        await resolve();
        return _send(fn, retry: false, timeout: timeout);
      }
      throw ApiException('Модуль не відповідає');
    }
  }

  Future<dynamic> get(String path, [Map<String, dynamic>? q]) => _send(() => http.get(uri(path, q), headers: _headers));

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      _send(() => http.post(uri(path), headers: _headers, body: jsonEncode(body ?? {})));

  /// Надіслати файл (тіло запиту — самі байти), напр. оновлення прошивки.
  Future<dynamic> upload(String path, Map<String, dynamic> q, List<int> bytes) => _send(
    () => http.post(uri(path, q), headers: {..._headers, 'Content-Type': 'application/octet-stream'}, body: bytes),
    timeout: const Duration(minutes: 3),
  );

  Future<dynamic> put(String path, Map<String, dynamic> body) =>
      _send(() => http.put(uri(path), headers: _headers, body: jsonEncode(body)));

  // ---- зручні методи ----------------------------------------------------------------
  Future<Map<String, dynamic>> status() async => (await get('/api/status')) as Map<String, dynamic>;

  Future<List<Signal>> signals() async =>
      ((await get('/api/signals'))['signals'] as List).map((e) => Signal(e as Map<String, dynamic>)).toList();

  Future<List<EventItem>> events({
    int sinceId = 0,
    int? beforeId,
    int limit = 50,
    int minPriority = 0,
    String? classCode,
  }) async {
    final q = <String, dynamic>{'since_id': sinceId, 'limit': limit, 'min_priority': minPriority};
    if (beforeId != null) q['before_id'] = beforeId;
    if (classCode != null) q['class_code'] = classCode;
    return ((await get('/api/events', q))['events'] as List).map((e) => EventItem(e as Map<String, dynamic>)).toList();
  }

  Future<void> watch({double? freqHz, String? trackId}) =>
      post('/api/control/watch', {'freq_hz': ?freqHz, 'track_id': ?trackId});

  Future<void> scan() => post('/api/control/scan');
  Future<void> pause() => post('/api/control/pause');
  Future<void> record(bool on) => post('/api/control/record', {'on': on});
  Future<void> videoOpts(Map<String, dynamic> o) => post('/api/control/video', o);
  Future<void> gain(Map<String, dynamic> g) => post('/api/control/gain', g);
}
