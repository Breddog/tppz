import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Список доданих модулів (зберігається на телефоні).
class DeviceStore extends ChangeNotifier {
  static const _key = 'devices_v1';
  final List<Device> devices = [];

  static Future<List<Device>> loadRaw() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final s = p.getString(_key);
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> load() async {
    devices
      ..clear()
      ..addAll(await loadRaw());
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
    notifyListeners();
  }

  Future<void> addOrUpdate(Device d) async {
    final i = devices.indexWhere((x) => x.id == d.id);
    if (i >= 0) {
      devices[i] = d;
    } else {
      devices.add(d);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    devices.removeWhere((d) => d.id == id);
    await _save();
  }

  Future<void> update(Device d) => addOrUpdate(d);

  static const _maxUrls = 6;

  static final _privateIp = RegExp(r'://(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)');

  /// Нова адреса — першою. Якщо адрес забагато, відкидаються найстаріші локальні (192.168…, 10…),
  /// а введені вручну Tailscale / домени лишаються.
  static List<String> _withUrl(List<String> urls, String url) {
    final out = [url, ...urls.where((u) => u != url)];
    while (out.length > _maxUrls) {
      final i = out.lastIndexWhere((u) => _privateIp.hasMatch(u));
      if (i <= 0) break;
      out.removeAt(i);
    }
    return out;
  }

  /// Запам'ятати адресу, з якої модуль оголосив себе (напр. на точці доступу телефону).
  Future<void> rememberAddress(String id, String url) async {
    final d = byId(id);
    if (d == null || (d.urls.isNotEmpty && d.urls.first == url)) return;
    d.urls = _withUrl(d.urls, url);
    await _save();
  }

  /// Те саме для фонового сервісу (окремий ізолят без екземпляра DeviceStore).
  static Future<void> rememberAddressRaw(String id, String url) async {
    final list = await loadRaw();
    final i = list.indexWhere((d) => d.id == id);
    if (i < 0 || (list[i].urls.isNotEmpty && list[i].urls.first == url)) return;
    list[i].urls = _withUrl(list[i].urls, url);
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.map((d) => d.toJson()).toList()));
  }

  Device? byId(String id) {
    for (final d in devices) {
      if (d.id == id) return d;
    }
    return null;
  }
}
