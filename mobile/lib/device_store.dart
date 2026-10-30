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

  Device? byId(String id) {
    for (final d in devices) {
      if (d.id == id) return d;
    }
    return null;
  }
}
