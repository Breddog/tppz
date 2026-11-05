import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../models.dart';

/// HackRF напряму через USB OTG (без Raspberry Pi) — див. android/.../HackRfDirect.java.
///
/// Java приймає I/Q з HackRF, робить ЧМ-детектор і виділяє яскравість та колір (як модуль) і віддає
/// пакети SDRB — їх декодує той самий DecoderWorker, що й відео з модуля.
class HackRfDirect {
  HackRfDirect._();

  static final instance = HackRfDirect._();

  static const _m = MethodChannel('sdrwatch/hackrf');
  static const _e = EventChannel('sdrwatch/hackrf/data');

  StreamSubscription? _sub;
  final _packets = StreamController<Uint8List>.broadcast();
  final _spectra = StreamController<SpectrumFrame>.broadcast();
  final _errors = StreamController<String>.broadcast();

  /// Пакети SDRB (відео).
  Stream<Uint8List> get packets => _packets.stream;

  /// Спектр поточного вікна (~20 МГц довкола частоти настройки).
  Stream<SpectrumFrame> get spectra => _spectra.stream;
  Stream<String> get errors => _errors.stream;

  bool opened = false;
  Map<String, dynamic> info = const {};
  double freqHz = 5800e6;

  Future<bool> available() async {
    try {
      return await _m.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<Map<String, dynamic>> open({double rate = 20e6}) async {
    _sub ??= _e.receiveBroadcastStream().listen(_onEvent, onError: (Object e) => _errors.add('$e'));
    final r = await _m.invokeMethod<Map>('open', {'rate': rate});
    info = (r ?? const {}).cast<String, dynamic>();
    opened = true;
    return info;
  }

  Future<void> close() async {
    opened = false;
    try {
      await _m.invokeMethod('close');
    } catch (_) {}
  }

  Future<void> tune(double hz) {
    freqHz = hz;
    return _m.invokeMethod('tune', {'hz': hz});
  }

  Future<void> gain(int lna, int vga, bool amp) => _m.invokeMethod('gain', {'lna': lna, 'vga': vga, 'amp': amp});

  Future<void> config({bool? color, double? fsc, double? targetFs, int? maxFps, bool? spectrumEveryField}) =>
      _m.invokeMethod('config', {
        'color': ?color,
        'fsc': ?fsc,
        'target_fs': ?targetFs,
        'max_fps': ?maxFps,
        'spectrum_every_field': ?spectrumEveryField,
      });

  Future<Map<String, dynamic>> stats() async =>
      ((await _m.invokeMethod<Map>('stats')) ?? const {}).cast<String, dynamic>();

  void _onEvent(dynamic e) {
    if (e is! Uint8List || e.isEmpty) return;
    switch (e[0]) {
      case 0x42: // 'B'
        _packets.add(Uint8List.sublistView(e, 1));
      case 0x53: // 'S'
        final f = parseSpectrum(e);
        if (f != null) _spectra.add(f);
      case 0x45: // 'E'
        opened = false;
        _errors.add(utf8.decode(e.sublist(1), allowMalformed: true));
    }
  }

  /// 'S' + центр f64 + частота відліків f32 + n u32 + дБ f32 × n. Показуємо робочі 80 % смуги.
  static SpectrumFrame? parseSpectrum(Uint8List e) {
    if (e.length < 17) return null;
    final d = ByteData.sublistView(e);
    final c = d.getFloat64(1, Endian.little);
    final fs = d.getFloat32(9, Endian.little);
    final n = d.getUint32(13, Endian.little);
    if (e.length < 17 + 4 * n || n < 16) return null;
    final crop = (n * 0.1).floor();
    final m = n - 2 * crop;
    final bins = Float32List(m);
    for (var i = 0; i < m; i++) {
      bins[i] = d.getFloat32(17 + 4 * (i + crop), Endian.little);
    }
    final sorted = Float32List.fromList(bins)..sort();
    final floor = Float32List(m)..fillRange(0, m, sorted[m ~/ 2]);
    final bin = fs / n;
    return SpectrumFrame(
      -1,
      'HackRF',
      c + (crop - n / 2) * bin,
      c + (n - crop - n / 2) * bin,
      bins,
      floor,
      6,
      DateTime.now().millisecondsSinceEpoch / 1000,
    );
  }

  /// Широкі сигнали (аналогове відео ≥ 2.5 МГц) у кадрі спектра: центри, Гц.
  static List<double> wideSignals(SpectrumFrame f, {double aboveDb = 6, double minBwHz = 2.5e6}) {
    final n = f.bins.length;
    if (n < 16) return const [];
    final bin = (f.fStop - f.fStart) / n;
    final k = math.max(1, (1e6 / bin).round()); // згладжування ~1 МГц
    final sm = Float32List(n);
    var acc = 0.0;
    for (var i = 0; i < n; i++) {
      acc += f.bins[i];
      if (i >= k) acc -= f.bins[i - k];
      sm[math.max(0, i - k ~/ 2)] = acc / math.min(i + 1, k);
    }
    final floor = f.floor[0];
    final out = <double>[];
    var start = -1;
    for (var i = 0; i <= n; i++) {
      final hot = i < n && sm[i] > floor + aboveDb;
      if (hot && start < 0) start = i;
      if (!hot && start >= 0) {
        if ((i - start) * bin >= minBwHz) out.add(f.fStart + (start + i) / 2 * bin);
        start = -1;
      }
    }
    return out;
  }

  /// Середній рівень над шумом у смузі ±halfBw довкола частоти (дБ) або null, якщо поза кадром.
  static double? levelAt(SpectrumFrame f, double hz, {double halfBw = 3e6}) {
    final n = f.bins.length;
    final bin = (f.fStop - f.fStart) / n;
    final a = ((hz - halfBw - f.fStart) / bin).floor(), b = ((hz + halfBw - f.fStart) / bin).ceil();
    if (b <= 0 || a >= n) return null;
    var s = 0.0, c = 0;
    for (var i = math.max(0, a); i < math.min(n, b); i++) {
      s += f.bins[i];
      c++;
    }
    return c == 0 ? null : s / c - f.floor[0];
  }
}

/// Частотні сітки (з assets/channels.json — та сама база, що на модулі).
class GridBand {
  GridBand(this.code, this.title, this.freqsMhz, this.popular, this.group);

  final String code, title, group;
  final List<double> freqsMhz;
  final bool popular;

  static Future<List<GridBand>> load() async {
    final j = jsonDecode(await rootBundle.loadString('assets/channels.json')) as Map<String, dynamic>;
    return [
      for (final b in (j['bands'] as List).cast<Map<String, dynamic>>())
        if ((b['kind'] ?? 'analog') == 'analog')
          GridBand(
            b['code'] as String,
            b['title'] as String? ?? b['code'] as String,
            [for (final f in (b['freqs_mhz'] as List)) (f as num).toDouble()],
            b['popular'] == true,
            b['group'] as String? ?? '',
          ),
    ];
  }
}
