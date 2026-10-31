import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../live.dart';
import '../models.dart';

/// Вкладка «Відео»: ЗАВЖДИ живий екран у реальному часі.
/// Є сигнал — показує відео, немає — реальний «сніг» (ніколи не чорний/синій екран).
/// Частота — повзунком по всьому діапазону або вводом. AFC, інверсія, дескремблювання, запис.
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
  Uint8List? _frame;
  int _frames = 0;
  double _fps = 0;
  DateTime _fpsT = DateTime.now();
  final _mhzCtl = TextEditingController();
  double _freqMhz = 5800;
  bool _started = false;
  Timer? _tuneDebounce;
  DateTime _lastTune = DateTime.fromMillisecondsSinceEpoch(0);

  static const _presets = [5800.0, 5658.0, 5880.0, 1200.0, 1280.0, 2440.0, 1080.0];

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
    super.dispose();
  }

  // ---- потік відеокадрів ------------------------------------------------------
  void _ensureStream() {
    if (_ws != null) return;
    try {
      _ws = WebSocketChannel.connect(Uri.parse(widget.api.wsUrl('/ws/video')));
      _sub = _ws!.stream.listen(
        (data) {
          if (data is! List<int>) return;
          _frames++;
          final now = DateTime.now();
          final dt = now.difference(_fpsT).inMilliseconds;
          if (dt > 1500) {
            _fps = _frames * 1000 / dt;
            _frames = 0;
            _fpsT = now;
          }
          if (mounted) setState(() => _frame = Uint8List.fromList(data));
        },
        onDone: _close,
        onError: (_) => _close(),
      );
    } catch (_) {
      _ws = null;
    }
  }

  void _close() {
    _sub?.cancel();
    _ws?.sink.close();
    _sub = null;
    _ws = null;
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

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final sdr = (l.status['sdr'] as Map?)?.cast<String, dynamic>() ?? const {};
    final minMhz = ((sdr['min_freq_hz'] as num?)?.toDouble() ?? 1e6) / 1e6;
    final maxMhz = ((sdr['max_freq_hz'] as num?)?.toDouble() ?? 6e9) / 1e6;

    // Завжди тримаємо режим стеження, щоб екран був живий
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureStream();
        if (!_started) {
          _started = true;
          final cur = (l.watch?['freq_hz'] as num?)?.toDouble() ?? (l.status['watch_freq_hz'] as num?)?.toDouble();
          if (l.status['mode'] != 'watch') {
            _tune(cur != null ? cur / 1e6 : _freqMhz, immediate: true);
          } else if (cur != null) {
            _freqMhz = cur / 1e6;
            _mhzCtl.text = _freqMhz.toStringAsFixed(1);
          }
        }
      });
    }

    final w = l.watch;
    final v = (w?['video'] as Map<String, dynamic>?) ?? const {};
    final isVideo = v['is_video'] == true;
    final ch = w?['channel'] as Map<String, dynamic>?;
    final rec = w?['recording'] == true;
    final opts = (l.status['video_opts'] as Map?)?.cast<String, dynamic>() ?? {};

    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        // ---- екран ----
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_frame != null)
                  Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill, filterQuality: FilterQuality.low)
                else
                  const Center(
                    child: Text('Підключення до відеопотоку…', style: TextStyle(color: Colors.white54)),
                  ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: _Osd(
                    lines: [
                      '${_freqMhz.toStringAsFixed(1)} МГц'
                          '${ch != null ? '  ${ch['name']}' : ''}',
                      if (isVideo)
                        '${v['standard']} · SNR ${v['snr_db']} дБ · синхро ${((v['sync_score'] as num) * 100).round()}%'
                      else
                        'немає відео — сніг (сигналу нема або він слабкий)',
                      if (v['inverted'] == true) 'інверсія — виправлено',
                      if (v['scrambled'] != null) 'скремблювання: ${v['scrambled']}',
                      '${_fps.toStringAsFixed(0)} кадр/с',
                    ],
                    good: isVideo,
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
                if (l.status['sdr_connected'] == false)
                  const Positioned(
                    bottom: 8,
                    left: 8,
                    child: Text('SDR не підключено', style: TextStyle(color: Colors.orangeAccent)),
                  ),
              ],
            ),
          ),
        ),

        // ---- частота ----
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
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
                  onSubmitted: (s) {
                    final v = double.tryParse(s.replaceAll(',', '.'));
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
        // Повзунок по всьому діапазону SDR
        Slider(
          value: _freqMhz.clamp(minMhz, maxMhz),
          min: minMhz,
          max: maxMhz,
          label: '${_freqMhz.toStringAsFixed(0)} МГц',
          onChanged: (v) => _tune(v),
          onChangeEnd: (v) => _tune(v, immediate: true),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(minMhz.toStringAsFixed(0), style: const TextStyle(color: Colors.white38, fontSize: 11)),
              Text('${maxMhz.toStringAsFixed(0)} МГц', style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final p in _presets)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(label: Text(p.toStringAsFixed(0)), onPressed: () => _tune(p, immediate: true)),
                ),
            ],
          ),
        ),

        // ---- швидкий перехід на знайдене відео ----
        _VideoSignals(onTune: (hz) => _tune(hz / 1e6, immediate: true)),

        // ---- керування ----
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                icon: Icon(rec ? Icons.stop : Icons.fiber_manual_record, color: Colors.redAccent),
                label: Text(rec ? 'Стоп запис' : 'Запис'),
                onPressed: () => _do(() => widget.api.record(!rec)),
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.radar),
                label: const Text('Сканування'),
                onPressed: () => _do(() async {
                  final st = await widget.api.post('/api/control/scan');
                  l.status = st as Map<String, dynamic>;
                  l.watch = null;
                  _started = false;
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
