import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'models.dart';
import 'widgets/spectrum_view.dart' show SpectrumPrefs;

/// Видима ділянка спектра/водоспаду (масштаб і прокрутка), Гц.
class ViewWindow {
  const ViewWindow(this.lo, this.hi);

  final double lo, hi;

  double get span => hi - lo;
}

/// Живе з'єднання з модулем: спектр, водоспад, сигнали, події, стан стеження, стан модуля.
///
/// Два канали оновлень:
///   * сам об'єкт (notifyListeners) — стан, сигнали, стеження, звук: не частіше 8 разів/с;
///   * [spectrumTick] — лише спектр/водоспад: на нього підписані тільки графіки,
///     тож кадр спектра НЕ перебудовує весь екран (відео, кнопки тощо).
class LiveConnection extends ChangeNotifier {
  LiveConnection(this.api);

  final ApiClient api;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _retry;
  Timer? _notifyTimer;
  bool _dirty = false;
  bool _disposed = false;
  int _backoff = 1;

  bool connected = false;
  String? error;
  Map<String, dynamic> status = {};
  Map<String, dynamic>? health;
  List<Signal> signals = [];
  final Map<int, SpectrumFrame> spectra = {};
  final Map<int, SpectrumFrame> zoomSpectra = {};
  final Map<int, List<Float32List>> waterfall = {};
  final Map<int, Float32List> peakHold = {};
  final Map<int, ViewWindow> views = {};
  int? selectedRange;

  /// «Ефір» під час стеження показує спектр стеження (true) чи вибраний діапазон (false).
  bool followWatch = true;
  Map<String, dynamic>? watch;
  Map<String, dynamic>? audio; // стан режиму звуку (частота, рівень, шумодав)
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Лічильник нових кадрів спектра — для графіків.
  final ValueNotifier<int> spectrumTick = ValueNotifier(0);

  /// Скільки рядків водоспаду пам'ятати (прокрутка назад у часі).
  static const waterfallRows = 600;

  String _rangeName(int r) => switch (r) {
    -1 => 'Стеження',
    -2 => 'Звук',
    -3 => 'Автоскан',
    _ =>
      (((status['ranges'] as List?) ?? const []).cast<Map<String, dynamic>>().firstWhere(
                (e) => e['index'] == r,
                orElse: () => const {},
              )['name']
              as String?) ??
          '',
  };

  Future<void> connect() async {
    if (_disposed) return;
    try {
      await api.resolve();
      _ch = WebSocketChannel.connect(Uri.parse('${api.wsUrl('/ws/live')}&binary=1'));
      await _ch!.ready;
      connected = true;
      error = null;
      _backoff = 1;
      _sendOpts();
      notifyListeners();
      _sub = _ch!.stream.listen(_onMsg, onDone: _onClosed, onError: (_) => _onClosed());
      _syncTime();
    } catch (e) {
      error = e.toString();
      _onClosed();
    }
  }

  /// У Pi немає годинника з батарейкою — даємо йому час телефона.
  Future<void> _syncTime() async {
    try {
      await api.post('/api/time', {'ts': DateTime.now().millisecondsSinceEpoch / 1000});
    } catch (_) {}
  }

  void _sendOpts() {
    final r = selectedRange;
    final v = r == null ? null : views[r];
    final f = r == null ? null : spectra[r];
    final zoomed = v != null && f != null && v.span < (f.fStop - f.fStart) * 0.85;
    _ch?.sink.add(
      jsonEncode({
        'range': r,
        'fps': 15,
        'zoom': zoomed ? {'range': r, 'lo': v.lo, 'hi': v.hi} : null,
      }),
    );
  }

  void _onClosed() {
    connected = false;
    _sub?.cancel();
    _sub = null;
    if (_disposed) return;
    notifyListeners();
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), connect);
    _backoff = (_backoff * 2).clamp(1, 20);
  }

  void selectRange(int? r) {
    selectedRange = r;
    _sendOpts();
    notifyListeners();
  }

  /// Масштаб/прокрутка (з графіка). null — увесь діапазон.
  void setView(int range, ViewWindow? v) {
    if (v == null) {
      views.remove(range);
    } else {
      views[range] = v;
    }
    _sendOpts();
    spectrumTick.value++;
  }

  /// Показати частоту в «Ефірі»: вибрати діапазон, що її містить, і збільшити ±span/2 навколо.
  void focusFreq(double hz, {double span = 20e6}) {
    final ranges = ((status['ranges'] as List?) ?? const []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? best;
    for (final r in ranges) {
      final a = (r['start_hz'] as num).toDouble(), b = (r['stop_hz'] as num).toDouble();
      if (a <= hz && hz <= b && (best == null || (b - a) < ((best['stop_hz'] as num) - (best['start_hz'] as num)))) {
        best = r;
      }
    }
    if (best == null) return;
    final idx = best['index'] as int;
    selectedRange = idx;
    followWatch = false;
    views[idx] = ViewWindow(hz - span / 2, hz + span / 2);
    _sendOpts();
    notifyListeners();
    spectrumTick.value++;
  }

  /// Оновити стан після відповіді API (напр. зміна підсилення).
  void updateStatus(Map<String, dynamic> patch) {
    status = {...status, ...patch};
    _changed();
  }

  void clearPeaks() {
    peakHold.clear();
    spectrumTick.value++;
  }

  @visibleForTesting
  void ingest(String data) => _onMsg(data);

  /// Не частіше 8 разів/с: усі зміни за 125 мс — одне оновлення екрана.
  void _changed() {
    if (_notifyTimer?.isActive ?? false) {
      _dirty = true;
      return;
    }
    notifyListeners();
    _notifyTimer = Timer(const Duration(milliseconds: 125), () {
      if (_dirty && !_disposed) {
        _dirty = false;
        notifyListeners();
      }
    });
  }

  void _onSpectrum(SpectrumFrame f) {
    if (f.zoom) {
      zoomSpectra[f.range] = f;
      spectrumTick.value++;
      return;
    }
    final first = !spectra.containsKey(f.range);
    final prev = spectra[f.range];
    // Кадр з іншої ділянки (стеження перейшло на інший канал, автоскан) — не склеювати водоспад
    if (prev != null) {
      final tol = (prev.fStop - prev.fStart) * 0.005;
      if ((prev.fStart - f.fStart).abs() > tol || (prev.fStop - f.fStop).abs() > tol) {
        waterfall.remove(f.range);
        peakHold.remove(f.range);
        zoomSpectra.remove(f.range);
      }
    }
    // Згладжування лінії (як «averaging» у SDR++): лише для того самого вікна частот
    final a = SpectrumPrefs.smoothing;
    final p0 = spectra[f.range];
    if (a > 0 && p0 != null && p0.bins.length == f.bins.length && p0.fStart == f.fStart && p0.fStop == f.fStop) {
      for (var i = 0; i < f.bins.length; i++) {
        f.bins[i] = p0.bins[i] * a + f.bins[i] * (1 - a);
      }
    }
    spectra[f.range] = f;
    final row = Float32List.fromList(f.bins);
    final wf = waterfall.putIfAbsent(f.range, () => []);
    if (wf.isNotEmpty && wf.first.length != row.length) wf.clear();
    wf.insert(0, row);
    if (wf.length > waterfallRows) wf.removeLast();
    final ph = peakHold[f.range];
    if (ph == null || ph.length != row.length) {
      peakHold[f.range] = Float32List.fromList(row);
    } else {
      for (var i = 0; i < row.length; i++) {
        ph[i] = row[i] > ph[i] ? row[i] : ph[i] - 0.15;
      }
    }
    spectrumTick.value++;
    if (selectedRange == null && f.range >= 0) {
      selectedRange = f.range;
      _sendOpts();
      _changed();
    } else if (first) {
      _changed();
    }
  }

  void _onMsg(dynamic data) {
    if (data is List<int>) {
      final f = SpectrumFrame.fromBytes(data is Uint8List ? data : Uint8List.fromList(data), _rangeName);
      if (f != null) _onSpectrum(f);
      return;
    }
    if (data is! String) return;
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['type']) {
      case 'hello':
        status = m['status'] as Map<String, dynamic>;
        health = (m['health'] as Map?)?.cast<String, dynamic>();
        audio = (status['audio'] as Map?)?.cast<String, dynamic>();
        signals = (m['signals'] as List).map((e) => Signal(e as Map<String, dynamic>)).toList();
        break;
      case 'spectrum':
        _onSpectrum(SpectrumFrame.fromJson(m));
        return;
      case 'signals':
        signals = (m['signals'] as List).map((e) => Signal(e as Map<String, dynamic>)).toList();
        break;
      case 'watch':
        watch = m;
        break;
      case 'audio':
        audio = m;
        break;
      case 'health':
        health = m;
        break;
      case 'event':
        _events.add(m);
        break;
      default:
        return;
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _notifyTimer?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _events.close();
    spectrumTick.dispose();
    super.dispose();
  }
}
