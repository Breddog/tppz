import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../live.dart';
import '../video/baseband_decoder.dart';
import 'audio_panel.dart';

/// Вкладка «Відео» — ГОЛОВНИЙ екран: живе відео в реальному часі.
///
/// Модуль шле «сирий» відеосигнал (після ЧМ-детектора), а ТЕЛЕФОН сам синхронізує рядки/кадри,
/// виправляє полярність, дескремблює, накопичує слабкі сигнали й малює. Без сигналу — справжній сніг.
/// Старий модуль (без /ws/baseband) — автоматично показуємо готові кадри з модуля (JPEG).
class VideoTab extends StatefulWidget {
  const VideoTab({
    super.key,
    required this.api,
    required this.active,
    this.watchRequest,
    this.listenRequest,
    this.onShowInEfir,
  });

  final ApiClient api;
  final bool active;

  /// Запит «показати відео на цій частоті» ззовні (Ефір, список сигналів), Гц.
  final ValueNotifier<double?>? watchRequest;

  /// Запит «слухати цю частоту» ззовні, Гц — перемикає на «Звук».
  final ValueNotifier<double?>? listenRequest;

  /// Показати частоту на спектрі («Ефір»).
  final void Function(double hz)? onShowInEfir;

  @override
  State<VideoTab> createState() => _VideoTabState();
}

class _VideoTabState extends State<VideoTab> {
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  String _src =
      'baseband'; // 'baseband' — Ч/Б, декодує телефон | 'color' — колір (модуль, MJPEG) | 'jpeg' — старий модуль
  double _sat = 1.0; // насиченість кольору
  DateTime? _wsSince;
  DateTime? _lastPacket;
  Timer? _fallbackTimer;

  // Декодування на телефоні
  final _dec = BasebandDecoder();
  final _img = ValueNotifier<ui.Image?>(null);
  final _jpeg = ValueNotifier<Uint8List?>(null);
  VideoStats? _stats;
  bool _busy = false;
  String _quality = 'normal';
  int _frames = 0, _dropped = 0, _bytes = 0;
  double _fps = 0, _kbps = 0;
  DateTime _fpsT = DateTime.now();

  final _mhzCtl = TextEditingController();
  double _freqMhz = 5800;
  bool _started = false;
  bool _autoStart = true; // відкрили вкладку, а модуль не дивиться відео — одразу круговий автоскан
  bool _circular = true;
  double _dwell = 3;
  String _scanMode = 'full'; // full | range | grids (сітки — окремий, не основний режим)
  bool _modeSynced = false; // підхопити режим, у якому вже працює модуль
  bool _scanAudio = true;
  final _fromCtl = TextEditingController(text: '900');
  final _toCtl = TextEditingController(text: '1400');
  // Мініатюри підтвердженого відео: ключ — частота, МГц (округлена до 1)
  final Map<int, ui.Image> _thumbs = {};
  final Map<int, DateTime> _thumbAt = {};
  String _section = 'video'; // 'video' | 'audio'
  final Set<String> _scanBands = {'R', 'F', 'A', 'B', 'E', '1G2', '3G3'};
  // Аналогові сітки з бази модуля (оновлюється без перепрошивки)
  List<Map<String, dynamic>> _gridBands = const [];

  Future<void> _loadGrids() async {
    try {
      final r = await widget.api.get('/api/channels') as Map<String, dynamic>;
      final bands = (r['bands'] as List).cast<Map<String, dynamic>>().where((b) => b['kind'] == 'analog').toList()
        ..sort((a, b) => (b['popular'] == true ? 1 : 0).compareTo(a['popular'] == true ? 1 : 0));
      if (mounted) setState(() => _gridBands = bands);
    } catch (_) {}
  }

  Timer? _tuneDebounce;
  DateTime _lastTune = DateTime.fromMillisecondsSinceEpoch(0);

  static const _presets = [5800.0, 5658.0, 5880.0, 1200.0, 1280.0, 3350.0, 2440.0, 1080.0];
  static const _qualities = {'economy': 'Економно', 'normal': 'Звичайно', 'detail': 'Детально'};

  @override
  void didUpdateWidget(covariant VideoTab old) {
    super.didUpdateWidget(old);
    if (!widget.active) {
      _close();
      _started = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadGrids();
    widget.watchRequest?.addListener(_onWatchRequest);
    widget.listenRequest?.addListener(_onListenRequest);
  }

  void _onWatchRequest() {
    final hz = widget.watchRequest?.value;
    if (hz == null || !mounted) return;
    widget.watchRequest!.value = null;
    _goVideo(hz);
  }

  void _onListenRequest() {
    if (widget.listenRequest?.value == null || !mounted) return;
    _close();
    setState(() => _section = 'audio'); // AudioPanel сам підхопить запит
  }

  /// Перейти на відео на частоті: зупинити автоскан і стежити за нею.
  Future<void> _goVideo(double hz) async {
    final auto = context.read<LiveConnection>().watch?['autoscan'];
    if (auto != null) await _autoscan(false);
    setState(() {
      _section = 'video';
      _started = true;
    });
    _tune(hz / 1e6, immediate: true);
  }

  @override
  void dispose() {
    widget.watchRequest?.removeListener(_onWatchRequest);
    widget.listenRequest?.removeListener(_onListenRequest);
    for (final t in _thumbs.values) {
      t.dispose();
    }
    _tuneDebounce?.cancel();
    _close();
    _img.value?.dispose();
    super.dispose();
  }

  // ---- потік ------------------------------------------------------------------------------
  void _ensureStream() {
    if (_ws != null) return;
    _wsSince ??= DateTime.now();
    try {
      if (_src == 'baseband') {
        _ws = WebSocketChannel.connect(Uri.parse('${widget.api.wsUrl('/ws/baseband')}&quality=$_quality'));
        _sub = _ws!.stream.listen(_onBaseband, onDone: _close, onError: (_) => _close());
        // Немає жодного пакета за 4 с, а модуль на зв'язку — це старий модуль: беремо JPEG
        _fallbackTimer?.cancel();
        _fallbackTimer = Timer(const Duration(seconds: 4), () {
          if (_lastPacket == null && mounted && context.read<LiveConnection>().connected) {
            _close();
            setState(() => _src = 'jpeg');
          }
        });
      } else {
        final path = _src == 'color' ? '/ws/videoc' : '/ws/video';
        final extra = _src == 'color' ? '&sat=${_sat.toStringAsFixed(2)}&q=70' : '';
        _ws = WebSocketChannel.connect(Uri.parse('${widget.api.wsUrl(path)}$extra'));
        _sub = _ws!.stream.listen(
          (data) {
            if (data is! List<int>) return;
            _count(data.length);
            _jpeg.value = Uint8List.fromList(data);
          },
          onDone: _close,
          onError: (_) => _close(),
        );
      }
    } catch (_) {
      _ws = null;
    }
  }

  void _count(int bytes) {
    _lastPacket = DateTime.now();
    _frames++;
    _bytes += bytes;
    final dt = _lastPacket!.difference(_fpsT).inMilliseconds;
    if (dt > 1500) {
      _fps = _frames * 1000 / dt;
      _kbps = _bytes * 8 / dt;
      _frames = 0;
      _bytes = 0;
      _fpsT = _lastPacket!;
      if (mounted) setState(() {});
    }
  }

  void _onBaseband(dynamic data) {
    if (data is! List<int>) return;
    _count(data.length);
    // Реальний час важливіший за кожне поле: поки попереднє ще малюється — нове пропускаємо
    if (_busy) {
      _dropped++;
      return;
    }
    final p = BasebandPacket.parse(data is Uint8List ? data : Uint8List.fromList(data));
    if (p == null) return;
    _busy = true;
    final f = _dec.decode(p);
    ui.decodeImageFromPixels(f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, (img) {
      _busy = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      final old = _img.value;
      _img.value = img;
      _maybeThumb(f, p.freqHz);
      old?.dispose();
      final wasLocked = _stats?.locked;
      _stats = f.stats;
      if (wasLocked != f.stats.locked) setState(() {});
    });
  }

  /// Зберегти мініатюру впевнено розпізнаного відео (раз на 3 с для частоти) — для списку знайденого.
  void _maybeThumb(DecodedFrame f, double freqHz) {
    if (!f.stats.locked || f.stats.syncScore < 0.7) return;
    final key = (freqHz / 1e6).round();
    final now = DateTime.now();
    if (now.difference(_thumbAt[key] ?? DateTime(2000)).inSeconds < 3) return;
    _thumbAt[key] = now;
    // зменшена копія: кожен 2-й піксель по горизонталі й вертикалі
    final w = f.width ~/ 2, h = f.height ~/ 2;
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final si = ((y * 2) * f.width + x * 2) * 4, di = (y * w + x) * 4;
        px[di] = f.rgba[si];
        px[di + 1] = f.rgba[si + 1];
        px[di + 2] = f.rgba[si + 2];
        px[di + 3] = 255;
      }
    }
    ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _thumbs[key]?.dispose();
        _thumbs[key] = img;
      });
    });
  }

  ui.Image? _thumbFor(double mhz) {
    for (final d in const [0, 1, -1, 2, -2]) {
      final t = _thumbs[mhz.round() + d];
      if (t != null) return t;
    }
    return null;
  }

  void _close() {
    _fallbackTimer?.cancel();
    _sub?.cancel();
    _ws?.sink.close();
    _sub = null;
    _ws = null;
  }

  void _reconnect() {
    _close();
    _lastPacket = null;
    _wsSince = null;
    _ensureStream();
  }

  Future<void> _do(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Перейти на частоту (МГц). Під час перетягування повзунка — не частіше ніж раз на 150 мс.
  void _tune(double mhz, {bool immediate = false}) {
    _freqMhz = mhz.clamp(1, 7250);
    _mhzCtl.text = _freqMhz.toStringAsFixed(1);
    _dec.resetAccumulation();
    setState(() {});
    void send() {
      _lastTune = DateTime.now();
      _do(() => widget.api.watch(freqHz: _freqMhz * 1e6));
    }

    if (immediate || DateTime.now().difference(_lastTune).inMilliseconds > 150) {
      send();
    } else {
      _tuneDebounce?.cancel();
      _tuneDebounce = Timer(const Duration(milliseconds: 160), send);
    }
  }

  Future<void> _autoscan(bool on) => _do(
    () => widget.api.post('/api/control/video_autoscan', {
      'on': on,
      'bands': _scanBands.toList(),
      'circular': _circular,
      'dwell_s': _dwell,
      'mode': _scanMode,
      'audio': _scanAudio,
      if (_scanMode == 'range') 'start_hz': (double.tryParse(_fromCtl.text.replaceAll(',', '.')) ?? 900) * 1e6,
      if (_scanMode == 'range') 'stop_hz': (double.tryParse(_toCtl.text.replaceAll(',', '.')) ?? 1400) * 1e6,
    }),
  );

  /// Пояснення, чому немає навіть «снігу».
  String _noFrameHint(LiveConnection l) {
    final waited = _wsSince == null ? 0 : DateTime.now().difference(_wsSince!).inSeconds;
    if (l.status['sdr_connected'] == false) {
      final err = l.status['sdr_error'] ?? (l.status['stats'] as Map?)?['last_error'];
      return 'Модуль не може відкрити HackRF.\nПеревірте USB-кабель і живлення.'
          '${err != null && '$err'.isNotEmpty ? '\n\nПричина: $err' : ''}';
    }
    if (waited < 6) return 'Підключення до відеопотоку…';
    return 'Модуль не надсилає відео.\n\nСкоріше за все, на модулі стара прошивка. '
        'Оновіть модуль: вкладка «Керування» → «Оновлення», або перепрошийте карту образом pi-12 чи новішим.';
  }

  void _fullscreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenVideo(
          screen: _screen,
          freq: () => _freqMhz,
          onStep: (d) => _tune(_freqMhz + d, immediate: true),
          stats: () => _stats,
        ),
      ),
    );
  }

  /// Саме зображення: оновлюється саме по собі (без перебудови всієї вкладки на кожен кадр).
  Widget _screen() => _src == 'baseband'
      ? ValueListenableBuilder<ui.Image?>(
          valueListenable: _img,
          builder: (_, img, _) => img == null
              ? const SizedBox.shrink()
              : RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
        )
      : ValueListenableBuilder<Uint8List?>(
          valueListenable: _jpeg,
          builder: (_, b, _) => b == null
              ? const SizedBox.shrink()
              : Image.memory(b, gaplessPlayback: true, fit: BoxFit.fill, filterQuality: FilterQuality.low),
        );

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final sdr = (l.status['sdr'] as Map?)?.cast<String, dynamic>() ?? const {};
    final minMhz = ((sdr['min_freq_hz'] as num?)?.toDouble() ?? 1e6) / 1e6;
    final maxMhz = ((sdr['max_freq_hz'] as num?)?.toDouble() ?? 6e9) / 1e6;

    final sectionSwitch = Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'video', icon: Icon(Icons.videocam), label: Text('Відео')),
          ButtonSegment(value: 'audio', icon: Icon(Icons.headphones), label: Text('Звук')),
        ],
        selected: {_section},
        onSelectionChanged: (sel) => setState(() {
          _section = sel.first;
          if (_section == 'audio') {
            _close();
          } else {
            _started = false; // повернулися до відео — знову увімкнути стеження
          }
        }),
      ),
    );
    if (_section == 'audio') {
      return Column(
        children: [
          sectionSwitch,
          Expanded(
            child: AudioPanel(api: widget.api, listenRequest: widget.listenRequest),
          ),
        ],
      );
    }

    // Завжди тримаємо режим стеження, щоб екран був живий
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ensureStream();
        if (!_started && l.connected) {
          _started = true;
          final cur = (l.watch?['freq_hz'] as num?)?.toDouble() ?? (l.status['watch_freq_hz'] as num?)?.toDouble();
          if (l.audio?['active'] == true) {
            // Слухаємо звук — не перебивати його автосканом відео
          } else if (l.status['mode'] != 'watch') {
            if (_autoStart) {
              _autoscan(true); // одразу шукаємо відео по колу всіх сіток
            } else {
              _tune(cur != null ? cur / 1e6 : _freqMhz, immediate: true);
            }
          } else if (cur != null) {
            _freqMhz = cur / 1e6;
            _mhzCtl.text = _freqMhz.toStringAsFixed(1);
          }
        }
      });
    }

    final w = l.watch;
    final pv = (w?['video'] as Map<String, dynamic>?) ?? const {};
    if (w?['freq_hz'] != null && DateTime.now().difference(_lastTune).inMilliseconds > 600) {
      final f = (w!['freq_hz'] as num).toDouble() / 1e6;
      if ((f - _freqMhz).abs() > 0.05) {
        _freqMhz = f; // автоскан/AFC змінили частоту на модулі
        _mhzCtl.text = f.toStringAsFixed(1);
      }
    }
    final s = _src == 'baseband' ? _stats : null;
    final isVideo = s?.locked ?? (pv['is_video'] == true);
    final ch = w?['channel'] as Map<String, dynamic>?;
    final rec = w?['recording'] == true;
    final opts = (l.status['video_opts'] as Map?)?.cast<String, dynamic>() ?? {};
    final auto = w?['autoscan'] as Map<String, dynamic>?;
    if (auto != null && !_modeSynced) {
      _modeSynced = true;
      _scanMode = auto['mode'] as String? ?? _scanMode;
      _circular = auto['circular'] as bool? ?? _circular;
      _dwell = ((auto['dwell_s'] as num?)?.toDouble() ?? _dwell).clamp(1, 15);
      _scanAudio = auto['audio'] as bool? ?? _scanAudio;
    }
    final hasPicture = _src == 'baseband' ? _img.value != null : _jpeg.value != null;

    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        sectionSwitch,
        // ---- екран ----
        GestureDetector(
          onDoubleTap: _fullscreen,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _screen(),
                  if (!hasPicture)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _noFrameHint(l),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: _Osd(
                      lines: [
                        '${_freqMhz.toStringAsFixed(1)} МГц'
                            '${ch != null ? '  ${ch['name']}' : ''}',
                        if (isVideo)
                          s != null
                              ? '${s.standard} · сигнал/шум ${s.snrDb.toStringAsFixed(0)} дБ · синхро ${(s.syncScore * 100).round()}%'
                              : '${pv['standard']} · SNR ${pv['snr_db']} дБ · синхро ${((pv['sync_score'] as num? ?? 0) * 100).round()}%'
                        else
                          'немає відео — сніг (сигналу нема або він слабкий)',
                        if (s?.inverted ?? pv['inverted'] == true) 'інверсія — виправлено',
                        if ((s?.scrambled ?? pv['scrambled']) != null)
                          'скремблювання: ${s?.scrambled ?? pv['scrambled']}',
                        '${_fps.toStringAsFixed(0)} кадр/с · ${(_kbps / 1000).toStringAsFixed(1)} Мбіт/с'
                            '${switch (_src) {
                              'baseband' => ' · Ч/Б, декодує телефон',
                              'color' => ' · колір, декодує модуль',
                              _ => ' · старий модуль',
                            }}',
                        if (_dec.accumulate > 1) 'накопичення ×${_dec.accumulate}',
                      ],
                      good: isVideo,
                    ),
                  ),
                  if (auto != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: _Osd(
                        lines: [
                          'АВТОСКАН ${(auto['index'] as int) + 1}/${auto['total']}'
                              '${auto['circular'] == true ? ' · коло ${(auto['rounds'] as int? ?? 0) + 1}' : ''}',
                        ],
                      ),
                    ),
                  if (rec)
                    const Positioned(
                      right: 10,
                      top: 10,
                      child: Row(
                        children: [
                          Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
                          Text(
                            ' REC',
                            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  Positioned(
                    right: 0,
                    bottom: auto != null ? 36 : 0,
                    child: IconButton(
                      tooltip: 'На весь екран (або подвійний дотик)',
                      icon: const Icon(Icons.fullscreen, color: Colors.white70),
                      onPressed: _fullscreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ---- частота: смуга прокрутки по всьому діапазону + точне введення ----
        Slider(
          value: _freqMhz.clamp(minMhz, maxMhz),
          min: minMhz,
          max: maxMhz,
          label: '${_freqMhz.toStringAsFixed(0)} МГц',
          onChanged: (v) {
            if (auto != null) _autoscan(false);
            _tune(v);
          },
          onChangeEnd: (v) => _tune(v, immediate: true),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _mhzCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Частота, МГц',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (str) {
                    final v = double.tryParse(str.replaceAll(',', '.'));
                    if (v != null) _tune(v, immediate: true);
                  },
                ),
              ),
              _StepBtn(label: '−5', onTap: () => _tune(_freqMhz - 5, immediate: true)),
              _StepBtn(label: '−1', onTap: () => _tune(_freqMhz - 1, immediate: true)),
              _StepBtn(label: '+1', onTap: () => _tune(_freqMhz + 1, immediate: true)),
              _StepBtn(label: '+5', onTap: () => _tune(_freqMhz + 5, immediate: true)),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
            children: [
              for (final p in _presets)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(label: Text(p.toStringAsFixed(0)), onPressed: () => _tune(p, immediate: true)),
                ),
            ],
          ),
        ),

        // ---- круговий автоскан: 3 режими ----
        Card(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.autorenew, size: 18),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text('Круговий автоскан', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    FilledButton.icon(
                      icon: Icon(auto != null ? Icons.stop : Icons.play_arrow),
                      label: Text(auto != null ? 'Стоп' : 'Пуск'),
                      onPressed: () => _autoscan(auto == null),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'full', label: Text('Весь діапазон')),
                    ButtonSegment(value: 'range', label: Text('Від–до')),
                    ButtonSegment(value: 'grids', label: Text('Сітки')),
                  ],
                  selected: {_scanMode},
                  onSelectionChanged: (v) {
                    setState(() {
                      _scanMode = v.first;
                      _modeSynced = true;
                    });
                    if (auto != null) _autoscan(true);
                  },
                ),
                const SizedBox(height: 6),
                Text(switch (_scanMode) {
                  'grids' => 'Канали вибраних сіток по черзі.',
                  'full' => 'Увесь діапазон SDR по порядку, коло за колом.',
                  _ => 'Вказаний діапазон по порядку, коло за колом.',
                }, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                if (_scanMode == 'grids')
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final b
                          in _gridBands.isEmpty
                              ? const [
                                  {'code': 'R'},
                                  {'code': 'F'},
                                  {'code': 'A'},
                                  {'code': 'B'},
                                  {'code': 'E'},
                                  {'code': '1G2'},
                                  {'code': '3G3'},
                                ]
                              : _gridBands)
                        Tooltip(
                          message:
                              '${b['title'] ?? b['code']}${(b['makers'] as List?)?.isNotEmpty == true ? ' — ${(b['makers'] as List).take(3).join(', ')}' : ''}',
                          child: FilterChip(
                            label: Text(b['code'] as String),
                            selected: _scanBands.contains(b['code']),
                            onSelected: (v) =>
                                setState(() => v ? _scanBands.add(b['code'] as String) : _scanBands.remove(b['code'])),
                          ),
                        ),
                    ],
                  ),
                if (_scanMode == 'range')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _fromCtl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Від, МГц',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _toCtl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'До, МГц',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (auto != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ScanProgress(auto: auto),
                  ),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Параметри: ${_circular ? 'по колу, показ ${_dwell.round()} с' : 'зупинка на відео'}'
                      '${_scanAudio ? ', + голос' : ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    children: [
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Шукати й голос (рації < 1.3 ГГц)'),
                        value: _scanAudio,
                        onChanged: (v) {
                          setState(() => _scanAudio = v);
                          if (auto != null) _autoscan(true);
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('По колу (не зупинятися на знайденому)'),
                        value: _circular,
                        onChanged: (v) {
                          setState(() => _circular = v);
                          if (auto != null) _autoscan(true);
                        },
                      ),
                      if (_circular)
                        Row(
                          children: [
                            Text('Показ знайденого: ${_dwell.round()} с', style: const TextStyle(fontSize: 13)),
                            Expanded(
                              child: Slider(
                                value: _dwell,
                                min: 1,
                                max: 15,
                                divisions: 14,
                                onChanged: (v) => setState(() => _dwell = v),
                                onChangeEnd: (_) {
                                  if (auto != null) _autoscan(true);
                                },
                              ),
                            ),
                          ],
                        ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Запускати автоскан, коли відкриваю екран'),
                        value: _autoStart,
                        onChanged: (v) => setState(() => _autoStart = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // ---- знайдене: відео (з мініатюрами) і голос ----
        if (auto != null && (auto['found'] as List).isNotEmpty)
          _FoundList(
            found: (auto['found'] as List).cast<Map<String, dynamic>>(),
            thumbFor: _thumbFor,
            onVideo: (hz) => _goVideo(hz),
            onListen: (hz) {
              widget.listenRequest?.value = hz;
              _onListenRequest();
            },
            onEfir: widget.onShowInEfir,
          ),

        // ---- приймач: підсилення ----
        _GainCard(api: widget.api),

        // ---- слабкі сигнали та зображення (усе рахує телефон) ----
        if (_src != 'jpeg')
          Card(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: ExpansionTile(
              shape: const Border(),
              initiallyExpanded: false,
              title: const Text('Зображення', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                _src == 'color'
                    ? 'колір (модуль, MJPEG) · насиченість ×${_sat.toStringAsFixed(1)}'
                    : 'Ч/Б (телефон) · накопичення ×${_dec.accumulate} · ${_qualities[_quality]}',
                style: const TextStyle(fontSize: 12),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'baseband',
                      icon: Icon(Icons.contrast, size: 18),
                      label: Text('Ч/Б (телефон)'),
                    ),
                    ButtonSegment(value: 'color', icon: Icon(Icons.palette, size: 18), label: Text('Колір (модуль)')),
                  ],
                  selected: {_src},
                  onSelectionChanged: (v) {
                    setState(() {
                      _src = v.first;
                      _jpeg.value = null;
                    });
                    _reconnect();
                  },
                ),
                Text(
                  _src == 'color'
                      ? 'Колір PAL/NTSC розшифровує модуль на повній частоті й шле кадри JPEG (~3 Мбіт/с). '
                            'На слабкому сигналі колір зникає (як у телевізорах).'
                      : 'Найменша затримка; накопичення кадрів для слабких сигналів. Без кольору.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (_src == 'color')
                  Row(
                    children: [
                      SizedBox(width: 150, child: Text('Насиченість ×${_sat.toStringAsFixed(1)}')),
                      Expanded(
                        child: Slider(
                          value: _sat,
                          min: 0,
                          max: 2.5,
                          divisions: 25,
                          onChanged: (v) => setState(() => _sat = v),
                          onChangeEnd: (_) => _reconnect(),
                        ),
                      ),
                    ],
                  ),
                if (_src == 'baseband') ...[
                  Row(
                    children: [
                      SizedBox(width: 150, child: Text('Накопичення ×${_dec.accumulate}')),
                      Expanded(
                        child: Slider(
                          value: _dec.accumulate.toDouble(),
                          min: 1,
                          max: 16,
                          divisions: 15,
                          onChanged: (v) => setState(() => _dec.accumulate = v.round()),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      SizedBox(width: 150, child: Text('Контраст ×${_dec.gain.toStringAsFixed(1)}')),
                      Expanded(
                        child: Slider(
                          value: _dec.gain,
                          min: 1,
                          max: 3,
                          divisions: 20,
                          onChanged: (v) => setState(() => _dec.gain = v),
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    'Накопичення усереднює кадри: шум зменшується, а нерухома картинка проявляється навіть '
                    'зі «снігу». Для руху тримайте ×1–3.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  const Text('Якість потоку з модуля', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),
                  SegmentedButton<String>(
                    segments: [for (final e in _qualities.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                    selected: {_quality},
                    onSelectionChanged: (v) {
                      setState(() => _quality = v.first);
                      _reconnect();
                    },
                  ),
                  const Text(
                    'Економно ≈6 Мбіт/с (точка доступу телефона), звичайно ≈16, детально ≈27 Мбіт/с (Wi-Fi роутер).',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  const Text('Полярність відео', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),
                  SegmentedButton<Polarity>(
                    segments: const [
                      ButtonSegment(value: Polarity.auto, label: Text('Авто')),
                      ButtonSegment(value: Polarity.normal, label: Text('Норм.')),
                      ButtonSegment(value: Polarity.inverted, label: Text('Інв.')),
                    ],
                    selected: {_dec.polarity},
                    onSelectionChanged: (v) => setState(() => _dec.polarity = v.first),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Дескремблювання'),
                    value: _dec.descramble,
                    onChanged: (v) => setState(() => _dec.descramble = v),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Авто-контраст'),
                    value: _dec.autoContrast,
                    onChanged: (v) => setState(() => _dec.autoContrast = v),
                  ),
                  if (_dropped > 0)
                    Text(
                      'Пропущено полів (телефон не встигав): $_dropped',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                ],
              ],
            ),
          ),

        // ---- керування ----
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                icon: Icon(rec ? Icons.stop : Icons.fiber_manual_record, color: Colors.redAccent),
                label: Text(rec ? 'Стоп запис' : 'Запис на модулі'),
                onPressed: () => _do(() => widget.api.record(!rec)),
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.radar),
                label: const Text('Повернути сканування'),
                onPressed: () => _do(() async {
                  final st = await widget.api.post('/api/control/scan');
                  l.status = st as Map<String, dynamic>;
                  l.watch = null;
                  _started = true; // не запускати автоскан знову, поки користувач сам не вирішить
                  setState(() {});
                }),
              ),
            ],
          ),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Автопідстроювання частоти (AFC)'),
          value: opts['afc'] ?? true,
          onChanged: (x) => _setOpts({'afc': x}),
        ),
        if (_src == 'jpeg') ...[
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('Авто')),
              ButtonSegment(value: 'normal', label: Text('Норм.')),
              ButtonSegment(value: 'inverted', label: Text('Інв.')),
            ],
            selected: {opts['invert'] == null ? 'auto' : (opts['invert'] == true ? 'inverted' : 'normal')},
            onSelectionChanged: (s) => _setOpts(switch (s.first) {
              'auto' => {'invert_auto': true},
              'inverted' => {'invert': true},
              _ => {'invert': false},
            }),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Дескремблювання'),
            value: opts['descramble'] ?? true,
            onChanged: (x) => _setOpts({'descramble': x}),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Модуль старої версії: відео декодує сам модуль (повільніше). Оновіть модуль, щоб декодував телефон.',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _setOpts(Map<String, dynamic> o) => _do(() async {
    final r = await widget.api.post('/api/control/video', o) as Map<String, dynamic>;
    if (!mounted) return;
    final l = context.read<LiveConnection>();
    l.status = {...l.status, 'video_opts': r['video_opts']};
    setState(() {});
  });
}

class _Osd extends StatelessWidget {
  const _Osd({required this.lines, this.good = false});

  final List<String> lines;
  final bool good;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines.length; i++)
          Text(
            lines[i],
            style: TextStyle(
              fontSize: 11,
              color: i == 1 ? (good ? Colors.greenAccent : Colors.orangeAccent) : Colors.white,
              fontWeight: i == 0 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
      ],
    ),
  );
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: SizedBox(
      width: 40,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 44)),
        onPressed: onTap,
        child: Text(label),
      ),
    ),
  );
}

/// Де зараз автоскан: позиція в діапазоні, коло, час кола.
class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.auto});

  final Map<String, dynamic> auto;

  @override
  Widget build(BuildContext context) {
    final total = (auto['total'] as num?)?.toInt() ?? 1;
    final idx = (auto['index'] as num?)?.toInt() ?? 0;
    final pos = (auto['pos_hz'] as num?)?.toDouble();
    final roundS = (auto['round_s'] as num?)?.toDouble();
    final dwelling = auto['dwelling'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: total > 0 ? (idx + 1) / total : null, minHeight: 4),
        const SizedBox(height: 4),
        Text(
          '${dwelling ? 'Показую знайдене' : 'Пошук'}'
          '${pos != null ? ' · ${(pos / 1e6).toStringAsFixed(0)} МГц' : ''}'
          ' · коло ${(auto['rounds'] as num? ?? 0).toInt() + 1}'
          '${roundS != null ? ' · коло за ${roundS.toStringAsFixed(1)} с' : ''}'
          '${auto['sweep'] == true ? ' · sweep прошивки' : ''}',
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    );
  }
}

/// Список знайденого: відео з мініатюрою (тап — дивитися), голос (тап — слухати), «Ефір» — на спектрі.
class _FoundList extends StatelessWidget {
  const _FoundList({
    required this.found,
    required this.thumbFor,
    required this.onVideo,
    required this.onListen,
    this.onEfir,
  });

  final List<Map<String, dynamic>> found;
  final ui.Image? Function(double mhz) thumbFor;
  final void Function(double hz) onVideo;
  final void Function(double hz) onListen;
  final void Function(double hz)? onEfir;

  @override
  Widget build(BuildContext context) {
    final videos = found.where((e) => e['type'] == 'video').toList();
    final voices = found.where((e) => e['type'] == 'audio').toList()
      ..sort((a, b) => ((b['last_seen'] as num?) ?? 0).compareTo((a['last_seen'] as num?) ?? 0));
    String ago(Map<String, dynamic> e) {
      final t = (e['last_seen'] as num?)?.toDouble();
      if (t == null) return '';
      final s = DateTime.now().millisecondsSinceEpoch / 1000 - t;
      return s < 60 ? '${s.round()} с тому' : '${(s / 60).round()} хв тому';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (videos.isNotEmpty) ...[
              Text(
                'Знайдене відео (${videos.length}) — натисніть, щоб дивитися',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 128,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final e in videos)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => onVideo((e['freq_mhz'] as num).toDouble() * 1e6),
                          child: SizedBox(
                            width: 120,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    width: 120,
                                    height: 80,
                                    color: Colors.black,
                                    child: thumbFor((e['freq_mhz'] as num).toDouble()) != null
                                        ? RawImage(image: thumbFor((e['freq_mhz'] as num).toDouble()), fit: BoxFit.fill)
                                        : const Center(child: Icon(Icons.videocam, color: Colors.redAccent)),
                                  ),
                                ),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${e['channel'] ?? ''} ${e['freq_mhz']}',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (onEfir != null)
                                      InkWell(
                                        onTap: () => onEfir!((e['freq_mhz'] as num).toDouble() * 1e6),
                                        child: const Padding(
                                          padding: EdgeInsets.all(2),
                                          child: Icon(Icons.ssid_chart, size: 18, color: Colors.white60),
                                        ),
                                      ),
                                  ],
                                ),
                                Text(ago(e), style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (voices.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Голос / вузькі сигнали (${voices.length}) — натисніть, щоб слухати',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final e in voices.take(12))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.record_voice_over, color: Colors.lightBlueAccent),
                  title: Text('${(e['freq_mhz'] as num).toStringAsFixed(4)} МГц'),
                  subtitle: Text('+${e['level_db']} дБ над шумом · ${ago(e)} · бачено ${e['hits']}×'),
                  onTap: () => onListen((e['freq_mhz'] as num).toDouble() * 1e6),
                  trailing: onEfir == null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.ssid_chart),
                          tooltip: 'Показати в «Ефірі»',
                          onPressed: () => onEfir!((e['freq_mhz'] as num).toDouble() * 1e6),
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Підсилення приймача — тут, поруч з відео (найчастіше саме під картинку його й крутять).
class _GainCard extends StatelessWidget {
  const _GainCard({required this.api});

  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final g = (l.status['gain'] as Map?)?.cast<String, dynamic>() ?? const {};
    final auto = g['auto'] == true;
    Future<void> set(Map<String, dynamic> v) async {
      try {
        final st = await api.post('/api/control/gain', v);
        if (st is Map<String, dynamic>) l.updateStatus(st);
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }

    Widget slider(String name, String key, double max, double step) {
      final v = ((g[key] as num?)?.toDouble() ?? 0).clamp(0.0, max);
      return Row(
        children: [
          SizedBox(width: 92, child: Text('$name ${v.round()} дБ', style: const TextStyle(fontSize: 13))),
          Expanded(
            child: Slider(
              value: v,
              min: 0,
              max: max,
              divisions: (max / step).round(),
              onChanged: auto ? null : (x) => set({key: x}),
            ),
          ),
        ],
      );
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: ExpansionTile(
        shape: const Border(),
        title: const Text('Приймач', style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          auto
              ? 'підсилення автоматичне'
              : 'LNA ${((g['lna'] as num?) ?? 0).round()} · VGA ${((g['vga'] as num?) ?? 0).round()} дБ'
                    '${g['amp'] == true ? ' · AMP' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Автоматичне підсилення'),
            subtitle: const Text('Знижує підсилення при перевантаженні сильним сигналом'),
            value: auto,
            onChanged: (v) => set({'auto': v}),
          ),
          slider('LNA', 'lna', 40, 8),
          slider('VGA', 'vga', 62, 2),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('AMP +14 дБ (далекі слабкі сигнали)'),
            value: g['amp'] == true,
            onChanged: (v) => set({'amp': v}),
          ),
        ],
      ),
    );
  }
}

/// Повноекранне відео: власна сторінка з керуванням; орієнтація й системні панелі
/// відновлюються при БУДЬ-ЯКОМУ виході (кнопка «Назад», жест, кнопка закриття).
class _FullscreenVideo extends StatefulWidget {
  const _FullscreenVideo({required this.screen, required this.freq, required this.onStep, required this.stats});

  final Widget Function() screen;
  final double Function() freq;
  final void Function(double d) onStep;
  final VideoStats? Function() stats;

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  bool _controls = true;
  Timer? _hide;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHide();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _controls) setState(() {});
    });
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _tick?.cancel();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.stats();
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _controls = !_controls);
          if (_controls) _scheduleHide();
        },
        onDoubleTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(aspectRatio: 4 / 3, child: widget.screen()),
            ),
            if (_controls) ...[
              Positioned(
                left: 12,
                top: 12,
                child: _Osd(
                  lines: [
                    '${widget.freq().toStringAsFixed(1)} МГц',
                    st?.locked == true
                        ? '${st!.standard} · синхро ${(st.syncScore * 100).round()}%'
                        : 'немає відео — сніг',
                  ],
                  good: st?.locked == true,
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: IconButton.filledTonal(
                  icon: const Icon(Icons.fullscreen_exit),
                  tooltip: 'Вийти з повного екрана',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final d in const [-5.0, -1.0, 1.0, 5.0])
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: FilledButton.tonal(
                          onPressed: () {
                            widget.onStep(d);
                            _scheduleHide();
                          },
                          child: Text(d > 0 ? '+${d.round()}' : '${d.round()}'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
