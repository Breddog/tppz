import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'netbind.dart';
import 'screens/update_section.dart' show kUpdateRepo;

/// Оновлення САМОГО застосунку з GitHub — без підключеного модуля, лише інтернет телефона.
class AppRelease {
  AppRelease(this.number, this.url, this.size);

  final int number;
  final String url;
  final int size;
}

class AppUpdate {
  static const _ch = MethodChannel('sdrwatch/net');
  static const _prefLastCheck = 'app_update_last_check';

  static int get currentBuild => int.tryParse(appBuild) ?? 0;

  /// Найновіша збірка застосунку на GitHub (apk-N).
  static Future<AppRelease?> latest() => NetBind.forInternet(() async {
    final r = await http
        .get(
          Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases?per_page=40'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('GitHub: HTTP ${r.statusCode}');
    AppRelease? best;
    for (final rel in (jsonDecode(r.body) as List).cast<Map<String, dynamic>>()) {
      final tag = rel['tag_name'] as String? ?? '';
      if (!tag.startsWith('apk-')) continue;
      final n = int.tryParse(tag.substring(4)) ?? 0;
      for (final a in (rel['assets'] as List).cast<Map<String, dynamic>>()) {
        if (a['name'] == 'SDR-Watch-universal.apk' && (best == null || n > best.number)) {
          best = AppRelease(n, a['browser_download_url'] as String, (a['size'] as num?)?.toInt() ?? 0);
        }
      }
    }
    return best;
  });

  /// Раз на добу: чи є новіша збірка (для сповіщення при запуску).
  static Future<AppRelease?> dailyCheck() async {
    try {
      final p = await SharedPreferences.getInstance();
      final last = p.getInt(_prefLastCheck) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < 24 * 3600 * 1000) return null;
      await p.setInt(_prefLastCheck, now);
      final r = await latest();
      return (r != null && r.number > currentBuild) ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Завантажити й відкрити встановлення. onProgress(0..1).
  static Future<void> downloadAndInstall(AppRelease r, void Function(double) onProgress) async {
    if (!Platform.isAndroid) throw Exception('Оновлення з застосунку — лише Android');
    final dir = await _ch.invokeMethod<String>('cacheDir');
    final file = File('$dir/SDR-Watch-${r.number}.apk');
    await NetBind.forInternet(() async {
      final client = http.Client();
      try {
        final resp = await client.send(http.Request('GET', Uri.parse(r.url)));
        if (resp.statusCode != 200) throw Exception('Завантаження: HTTP ${resp.statusCode}');
        final total = resp.contentLength ?? r.size;
        final sink = file.openWrite();
        var got = 0;
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
        await sink.close();
      } finally {
        client.close();
      }
    });
    final can = await _ch.invokeMethod<bool>('canInstall') ?? true;
    if (!can) {
      await _ch.invokeMethod('allowInstall');
      throw Exception('Дозвольте «Встановлення невідомих застосунків» для SDR Watch і натисніть ще раз');
    }
    await _ch.invokeMethod('installApk', {'path': file.path});
  }
}
