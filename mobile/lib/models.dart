import 'dart:convert';

import 'package:flutter/material.dart';

/// Модуль Raspberry Pi + SDR, доданий у застосунок (як камера спостереження).
class Device {
  Device({
    required this.id,
    required this.name,
    required this.urls,
    required this.token,
    this.notify = true,
    this.minPriority = 1,
  });

  final String id;
  String name;
  List<String> urls; // локальна адреса, Tailscale / VPN, домен — пробуються по черзі
  String token;
  bool notify;
  int minPriority;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'urls': urls,
    'token': token,
    'notify': notify,
    'minPriority': minPriority,
  };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as String,
    name: j['name'] as String,
    urls: (j['urls'] as List).cast<String>(),
    token: j['token'] as String,
    notify: j['notify'] as bool? ?? true,
    minPriority: j['minPriority'] as int? ?? 1,
  );

  /// QR-код з модуля: {"app":"sdrwatch","n":..,"id":..,"u":[..],"t":..}
  static Device? fromQr(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['app'] != 'sdrwatch') return null;
      return Device(
        id: j['id'] as String,
        name: j['n'] as String? ?? 'SDR-модуль',
        urls: (j['u'] as List).cast<String>(),
        token: j['t'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

class SignalClass {
  SignalClass(this.code, this.label, this.subtype, this.confidence, this.priority, this.canShowVideo, this.hints);

  final String code;
  final String label;
  final String subtype;
  final double confidence;
  final int priority;
  final bool canShowVideo;
  final List<String> hints;

  factory SignalClass.fromJson(Map<String, dynamic> j) => SignalClass(
    j['code'] as String,
    j['label'] as String,
    j['subtype'] as String? ?? '',
    (j['confidence'] as num?)?.toDouble() ?? 0,
    j['priority'] as int? ?? 0,
    j['can_show_video'] as bool? ?? false,
    ((j['hints'] as List?) ?? const []).cast<String>(),
  );
}

class Signal {
  Signal(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  double get freqHz => (raw['freq_hz'] as num).toDouble();
  double get bandwidthHz => (raw['bandwidth_hz'] as num).toDouble();
  String get state => raw['state'] as String? ?? '';
  bool get active => state == 'confirmed';
  double get rssi => (raw['rssi_dbm'] as num?)?.toDouble() ?? -200;
  double get snr => (raw['snr_db'] as num?)?.toDouble() ?? 0;
  bool get hopping => raw['hopping'] as bool? ?? false;
  String get hint => raw['hint'] as String? ?? '';
  String get range => raw['range'] as String? ?? '';
  int? get thumbnailId => raw['thumbnail_id'] as int?;
  int? get eventId => raw['event_id'] as int?;
  double get firstSeen => (raw['first_seen'] as num?)?.toDouble() ?? 0;
  double get lastSeen => (raw['last_seen'] as num?)?.toDouble() ?? 0;

  SignalClass? get cls => raw['class'] == null ? null : SignalClass.fromJson(raw['class'] as Map<String, dynamic>);
  Map<String, dynamic>? get channel => raw['channel'] as Map<String, dynamic>?;
  Map<String, dynamic>? get distance => raw['distance'] as Map<String, dynamic>?;
  Map<String, dynamic>? get video => raw['video'] as Map<String, dynamic>?;
  Map<String, dynamic>? get iq => raw['iq'] as Map<String, dynamic>?;

  String get channelName => channel == null ? '' : channel!['name'] as String;
  String get distanceText => distance == null ? '' : distance!['text'] as String;
}

class SpectrumFrame {
  SpectrumFrame(this.range, this.name, this.fStart, this.fStop, this.bins, this.floor, this.thresholdDb, this.ts);

  final int range;
  final String name;
  final double fStart;
  final double fStop;
  final List<double> bins;
  final List<double> floor;
  final double thresholdDb;
  final double ts;

  factory SpectrumFrame.fromJson(Map<String, dynamic> j) => SpectrumFrame(
    j['range'] as int,
    j['name'] as String,
    (j['f_start'] as num).toDouble(),
    (j['f_stop'] as num).toDouble(),
    (j['bins'] as List).map((e) => (e as num).toDouble()).toList(),
    (j['floor'] as List).map((e) => (e as num).toDouble()).toList(),
    (j['threshold_db'] as num?)?.toDouble() ?? 8,
    (j['ts'] as num).toDouble(),
  );
}

class EventItem {
  EventItem(this.raw);

  final Map<String, dynamic> raw;

  int get id => raw['id'] as int;
  double get ts => (raw['ts'] as num).toDouble();
  String get kind => raw['kind'] as String;
  double get freqHz => (raw['freq_hz'] as num?)?.toDouble() ?? 0;
  String get label => raw['label'] as String? ?? 'Сигнал';
  String? get classCode => raw['class_code'] as String?;
  int get priority => raw['priority'] as int? ?? 0;
  Signal get signal => Signal(raw['data'] as Map<String, dynamic>);
  List<Map<String, dynamic>> get media => ((raw['media'] as List?) ?? const []).cast<Map<String, dynamic>>();
}

// ---- Форматування й кольори ---------------------------------------------------

String fmtFreq(double hz) {
  if (hz >= 1e9) return '${(hz / 1e6).toStringAsFixed(1)} МГц';
  if (hz >= 1e6) return '${(hz / 1e6).toStringAsFixed(2)} МГц';
  return '${(hz / 1e3).toStringAsFixed(0)} кГц';
}

String fmtBw(double hz) => hz >= 1e6 ? '${(hz / 1e6).toStringAsFixed(1)} МГц' : '${(hz / 1e3).toStringAsFixed(0)} кГц';

String fmtTime(double ts) {
  final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String fmtAgo(double ts) {
  final s = DateTime.now().millisecondsSinceEpoch / 1000 - ts;
  if (s < 60) return '${s.round()} с тому';
  if (s < 3600) return '${(s / 60).round()} хв тому';
  if (s < 86400) return '${(s / 3600).round()} год тому';
  return '${(s / 86400).round()} дн тому';
}

String fmtBytes(num b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} ГБ';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} МБ';
  return '${(b / 1024).toStringAsFixed(0)} КБ';
}

Color classColor(String? code) {
  switch (code) {
    case 'analog_video':
      return const Color(0xFFFF5252);
    case 'analog_video_inverted':
      return const Color(0xFFFF7043);
    case 'analog_video_scrambled':
      return const Color(0xFFFFA726);
    case 'analog_video_weak':
      return const Color(0xFFFFCA28);
    case 'digital_video':
      return const Color(0xFF42A5F5);
    case 'control_link':
      return const Color(0xFFAB47BC);
    case 'telemetry':
      return const Color(0xFF26C6DA);
    case 'wifi':
      return const Color(0xFF78909C);
    default:
      return const Color(0xFF9E9E9E);
  }
}

IconData classIcon(String? code) {
  switch (code) {
    case 'analog_video':
    case 'analog_video_inverted':
    case 'analog_video_weak':
      return Icons.videocam;
    case 'analog_video_scrambled':
      return Icons.lock_outline;
    case 'digital_video':
      return Icons.hd;
    case 'control_link':
      return Icons.gamepad;
    case 'telemetry':
      return Icons.settings_input_antenna;
    case 'wifi':
      return Icons.wifi;
    default:
      return Icons.graphic_eq;
  }
}

const Map<String, String> kClassNames = {
  'analog_video': 'Аналогове відео',
  'analog_video_inverted': 'Інвертоване відео',
  'analog_video_scrambled': 'Кодоване відео',
  'analog_video_weak': 'Слабке аналогове',
  'digital_video': 'Цифрове відео',
  'control_link': 'Керування',
  'telemetry': 'Телеметрія',
  'wifi': 'Wi-Fi',
  'wideband_unknown': 'Широкосмуговий',
  'carrier': 'Несуча',
  'known_service': 'Відома служба',
  'unknown': 'Невідомий',
};
