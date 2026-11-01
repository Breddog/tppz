import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Що саме повідомляти (телефон; ті самі фільтри можна передати модулю для Telegram/ntfy).
class NotifySettings {
  /// Класи сигналів, про які повідомляти.
  Set<String> classes = {...defaultClasses};

  /// Не повідомляти про сигнали слабші за цей рівень, дБм (null — без обмеження).
  double? minRssiDbm;

  bool sound = true;
  bool vibrate = true;

  /// Спливаюче повідомлення й звук, коли застосунок відкрито на екрані модуля.
  bool inApp = true;

  /// Не повторювати про ту саму частоту/клас частіше, ніж раз на N секунд.
  int cooldownS = 120;

  /// Тиха година: з/до (години 0–23). null — вимкнено. Під час тихої години — без звуку й вібрації.
  int? quietFrom, quietTo;

  /// Попередження про стан модуля (перегрів, просідання живлення, мало місця).
  bool moduleHealth = true;

  static const defaultClasses = {
    'analog_video',
    'analog_video_inverted',
    'analog_video_scrambled',
    'analog_video_weak',
    'digital_video',
    'control_link',
    'telemetry',
  };

  static const _key = 'notify_settings_v1';
  static final Map<String, DateTime> _lastSent = {};

  static Future<NotifySettings> load() async {
    final s = NotifySettings();
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final raw = p.getString(_key);
      if (raw == null) return s;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      s.classes = ((j['classes'] as List?) ?? defaultClasses.toList()).cast<String>().toSet();
      s.minRssiDbm = (j['min_rssi_dbm'] as num?)?.toDouble();
      s.sound = j['sound'] as bool? ?? true;
      s.vibrate = j['vibrate'] as bool? ?? true;
      s.inApp = j['in_app'] as bool? ?? true;
      s.cooldownS = (j['cooldown_s'] as num?)?.toInt() ?? 120;
      s.quietFrom = (j['quiet_from'] as num?)?.toInt();
      s.quietTo = (j['quiet_to'] as num?)?.toInt();
      s.moduleHealth = j['module_health'] as bool? ?? true;
    } catch (_) {}
    return s;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode({
        'classes': classes.toList(),
        'min_rssi_dbm': minRssiDbm,
        'sound': sound,
        'vibrate': vibrate,
        'in_app': inApp,
        'cooldown_s': cooldownS,
        'quiet_from': quietFrom,
        'quiet_to': quietTo,
        'module_health': moduleHealth,
      }),
    );
  }

  bool get isQuietNow {
    final f = quietFrom, t = quietTo;
    if (f == null || t == null || f == t) return false;
    final h = DateTime.now().hour;
    return f < t ? (h >= f && h < t) : (h >= f || h < t);
  }

  /// Чи повідомляти про сигнал (і запам'ятати час, щоб не повторювати).
  bool allows(String? classCode, double? rssiDbm, double freqHz) {
    if (classCode == null || !classes.contains(classCode)) return false;
    if (minRssiDbm != null && rssiDbm != null && rssiDbm < minRssiDbm!) return false;
    final key = '$classCode:${(freqHz / 5e6).round()}';
    final now = DateTime.now();
    final last = _lastSent[key];
    if (last != null && now.difference(last).inSeconds < cooldownS) return false;
    _lastSent[key] = now;
    return true;
  }

  /// Фільтри для модуля (Telegram / ntfy / webhook): PUT /api/config {"notify": ...}.
  Map<String, dynamic> toModuleConfig() => {
    'notify': {'classes': classes.toList(), 'min_rssi_dbm': minRssiDbm, 'cooldown_s': cooldownS.toDouble()},
  };
}
