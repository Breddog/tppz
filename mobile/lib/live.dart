import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'models.dart';

/// Живе з'єднання з модулем: спектр, водоспад, сигнали, події, стан стеження.
class LiveConnection extends ChangeNotifier {
  LiveConnection(this.api);

  final ApiClient api;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _retry;
  bool _disposed = false;
  int _backoff = 1;

  bool connected = false;
  String? error;
  Map<String, dynamic> status = {};
  List<Signal> signals = [];
  final Map<int, SpectrumFrame> spectra = {};
  final Map<int, List<Float32List>> waterfall = {};
  final Map<int, Float32List> peakHold = {};
  int? selectedRange;
  Map<String, dynamic>? watch;
  Map<String, dynamic>? audio; // стан режиму звуку (частота, рівень, шумодав)
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  static const waterfallRows = 220;

  Future<void> connect() async {
    if (_disposed) return;
    try {
      await api.resolve();
      _ch = WebSocketChannel.connect(Uri.parse(api.wsUrl('/ws/live')));
      await _ch!.ready;
      connected = true;
      error = null;
      _backoff = 1;
      if (selectedRange != null) _ch!.sink.add(jsonEncode({'range': selectedRange}));
      notifyListeners();
      _sub = _ch!.stream.listen(_onMsg, onDone: _onClosed, onError: (_) => _onClosed());
    } catch (e) {
      error = e.toString();
      _onClosed();
    }
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
    _ch?.sink.add(jsonEncode({'range': r}));
    notifyListeners();
  }

  void clearPeaks() {
    peakHold.clear();
    notifyListeners();
  }

  @visibleForTesting
  void ingest(String data) => _onMsg(data);

  void _onMsg(dynamic data) {
    if (data is! String) return;
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['type']) {
      case 'hello':
        status = m['status'] as Map<String, dynamic>;
        audio = (status['audio'] as Map?)?.cast<String, dynamic>();
        signals = (m['signals'] as List).map((e) => Signal(e as Map<String, dynamic>)).toList();
        break;
      case 'spectrum':
        final f = SpectrumFrame.fromJson(m);
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
        selectedRange ??= f.range >= 0 ? f.range : null;
        break;
      case 'signals':
        signals = (m['signals'] as List).map((e) => Signal(e as Map<String, dynamic>)).toList();
        break;
      case 'watch':
        watch = m;
        break;
      case 'audio':
        audio = m;
        break;
      case 'event':
        _events.add(m);
        break;
      default:
        return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _events.close();
    super.dispose();
  }
}
