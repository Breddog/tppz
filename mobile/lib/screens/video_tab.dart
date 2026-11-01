import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../live.dart';
import '../models.dart';
import '../video/baseband_decoder.dart';
import 'audio_panel.dart';

/// Вкладка «Відео» — ГОЛОВНИЙ екран: живе відео в реальному часі.
///
/// Модуль шле «сирий» відеосигнал (після ЧМ-детектора), а ТЕЛЕФОН сам синхронізує рядки/кадри,
/// виправляє полярність, дескремблює, накопичує слабкі сигнали й малює. Без сигналу — справжній сніг.
/// Старий модуль (без /ws/baseband) — автоматично показуємо готові кадри з модуля (JPEG).
class VideoTab extends StatefulWidget {
  const VideoTab({super.key, required this.api, required this.active});

  final ApiClient api;
  final bool active;

  @override
  State<VideoTab> createState() => _VideoTabState();
}

class _VideoTabState extends State<VideoTab> {
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  String _src = 'baseband'; // 'baseband' — декодує телефон | 'jpeg' — старий модуль
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
  double _dwell = 4;
  String _section = 'video'; // 'video' | 'audio'
  final Set<String> _scanBands = {'R', 'F', 'A', 'B', 'E', '1G2', '3G3'};
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
  void dispose() {
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
        _ws = WebSocketChannel.connect(Uri.parse(widget.api.wsUrl('/ws/video')));
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
      old?.dispose();
      final wasLocked = _stats?.locked;
      _stats = f.stats;
      if (wasLocked != f.stats.locked) setState(() {});
    });
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
    }),
  );

  /// Пояснення, чому немає навіть «снігу».
  String _noFrameHint(LiveConnection l) {
    final waited = _wsSince == null ? 0 : DateTime.now().difference(_wsSince!).inSeconds;
    if (l.status['sdr_connected'] == false) {
      return 'HackRF не підключено до модуля — приймати нічого.\nПеревірте USB-кабель і живлення.';
    }
    if (waited < 6) return 'Підключення до відеопотоку…';
    return 'Модуль не надсилає відео.\n\nСкоріше за все, на модулі стара прошивка. '
        'Оновіть модуль: вкладка «Керування» → «Оновлення», або перепрошийте карту образом pi-12 чи новішим.';
  }

  void _fullscreen() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              body: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Center(
                  child: AspectRatio(aspectRatio: 4 / 3, child: _screen()),
                ),
              ),
            ),
          ),
        )
        .then((_) {
          SystemChrome.setPreferredOrientations([]);
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        });
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
          Expanded(child: AudioPanel(api: widget.api)),
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
          if (l.status['mode'] != 'watch') {
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
                            '${_src == 'baseband' ? ' · декодує телефон' : ' · старий модуль'}',
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

        // ---- круговий автоскан ----
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
                      child: Text('Круговий автоскан відео', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    FilledButton.icon(
                      icon: Icon(auto != null ? Icons.stop : Icons.play_arrow),
                      label: Text(auto != null ? 'Стоп' : 'Пуск'),
                      onPressed: () => _autoscan(auto == null),
                    ),
                  ],
                ),
                Text(
                  _circular
                      ? 'Іде по колу всіх вибраних каналів; знайшов картинку — показує ${_dwell.round()} с і йде далі. '
                            'Знайдене збирається нижче — тап, щоб зупинитися на ньому.'
                      : 'Іде по каналах і ЗУПИНЯЄТЬСЯ на першій картинці; зникла — шукає далі.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final b in const ['R', 'F', 'A', 'B', 'E', 'L', 'U', 'O', 'H', '1G2', '1G3', '3G3'])
                      FilterChip(
                        label: Text(b),
                        selected: _scanBands.contains(b),
                        onSelected: (v) => setState(() => v ? _scanBands.add(b) : _scanBands.remove(b)),
                      ),
                  ],
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
                if (auto != null && (auto['found'] as List).isNotEmpty) ...[
                  const Text('Знайдено відео:', style: TextStyle(color: Colors.white60, fontSize: 12)),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final f in (auto['found'] as List).cast<Map<String, dynamic>>())
                        ActionChip(
                          avatar: const Icon(Icons.videocam, size: 16, color: Colors.redAccent),
                          label: Text('${f['channel']} · ${f['freq_mhz']}'),
                          onPressed: () async {
                            await _autoscan(false);
                            _tune((f['freq_mhz'] as num).toDouble(), immediate: true);
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        // ---- швидкий перехід на знайдене сканером відео ----
        _VideoSignals(onTune: (hz) => _tune(hz / 1e6, immediate: true)),

        // ---- слабкі сигнали та зображення (усе рахує телефон) ----
        if (_src == 'baseband')
          Card(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Слабкі сигнали та зображення', style: TextStyle(fontWeight: FontWeight.bold)),
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
              ),
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

/// Горизонтальний список знайденого відео — тап переводить екран на нього.
class _VideoSignals extends StatelessWidget {
  const _VideoSignals({required this.onTune});

  final void Function(double hz) onTune;

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final vids = l.signals
        .where((s) => s.active && ((s.cls?.canShowVideo ?? false) || s.cls?.code == 'digital_video'))
        .toList();
    if (vids.isEmpty) return const SizedBox(height: 4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 8, 14, 2),
          child: Text(
            'Знайдене відео — натисніть, щоб подивитися',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final s in vids)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    avatar: Icon(classIcon(s.cls?.code), size: 16, color: classColor(s.cls?.code)),
                    label: Text('${fmtFreq(s.freqHz)}${s.channelName.isNotEmpty ? ' ${s.channelName}' : ''}'),
                    onPressed: () => onTune(s.freqHz),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
