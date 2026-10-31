import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../live.dart';
import '../widgets/spectrum_view.dart';

/// Звук з ефіру: рації, мовлення, авіація. Модуль демодулює, телефон лише програє (24 кГц, моно).
class AudioPanel extends StatefulWidget {
  const AudioPanel({super.key, required this.api});

  final ApiClient api;

  @override
  State<AudioPanel> createState() => _AudioPanelState();
}

class _Preset {
  const _Preset(this.name, this.start, this.stop, this.step, this.mod);

  final String name;
  final double start, stop, step; // МГц, МГц, кГц
  final String mod;
}

class _AudioPanelState extends State<AudioPanel> {
  static const _presets = [
    _Preset('PMR446', 446.00625, 446.19375, 12.5, 'nfm'),
    _Preset('LPD433', 433.075, 434.775, 25, 'nfm'),
    _Preset('2 м (аматори)', 144.0, 146.0, 12.5, 'nfm'),
    _Preset('70 см (аматори)', 430.0, 440.0, 12.5, 'nfm'),
    _Preset('Морський', 156.0, 162.05, 25, 'nfm'),
    _Preset('Авіація', 118.0, 137.0, 25, 'am'),
    _Preset('FM-мовлення', 87.5, 108.0, 100, 'wfm'),
  ];
  static const _mods = {'nfm': 'ЧМ вузька', 'wfm': 'ЧМ широка', 'am': 'АМ'};

  final _freq = TextEditingController(text: '446.00625');
  String _mod = 'nfm';
  double _squelch = 10;
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _pcmReady = false;
  bool _listening = false;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _initPcm();
  }

  Future<void> _initPcm() async {
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.none);
      await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(2400);
      FlutterPcmSound.setFeedCallback((_) {}); // дані подаємо самі, щойно приходять
      _pcmReady = true;
    } catch (_) {
      _pcmReady = false;
    }
  }

  @override
  void dispose() {
    _closeWs();
    FlutterPcmSound.release().catchError((_) {});
    super.dispose();
  }

  void _openWs() {
    if (_ws != null) return;
    _ws = WebSocketChannel.connect(Uri.parse(widget.api.wsUrl('/ws/audio')));
    _sub = _ws!.stream.listen(
      (data) {
        if (data is! List<int> || !_pcmReady) return;
        final b = Uint8List.fromList(data);
        _bytes += b.length;
        FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.sublistView(b)));
      },
      onDone: _closeWs,
      onError: (_) => _closeWs(),
    );
  }

  void _closeWs() {
    _sub?.cancel();
    _ws?.sink.close();
    _sub = null;
    _ws = null;
  }

  Future<void> _do(Future<void> Function() f) async {
    try {
      await f();
    } on ControlLockedException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast(e.toString());
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _listen() => _do(() async {
    final mhz = double.tryParse(_freq.text.replaceAll(',', '.'));
    if (mhz == null) throw ApiException('Вкажіть частоту в МГц');
    await widget.api.post('/api/audio/start', {'freq_hz': mhz * 1e6, 'mod': _mod, 'squelch_db': _squelch});
    _openWs();
    setState(() => _listening = true);
  });

  Future<void> _autoscan(_Preset p) => _do(() async {
    setState(() => _mod = p.mod);
    await widget.api.post('/api/audio/start', {
      'mod': p.mod,
      'squelch_db': _squelch,
      'scan_start_hz': p.start * 1e6,
      'scan_stop_hz': p.stop * 1e6,
      'scan_step_hz': p.step * 1e3,
    });
    _openWs();
    setState(() => _listening = true);
  });

  Future<void> _stop() => _do(() async {
    await widget.api.post('/api/audio/stop');
    _closeWs();
    setState(() => _listening = false);
  });

  Future<void> _params() => _do(() => widget.api.post('/api/audio/params', {'squelch_db': _squelch, 'mod': _mod}));

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final a = l.audio ?? const {};
    final active = a['active'] == true;
    final open = a['open'] == true;
    final level = (a['level_db'] as num?)?.toDouble();
    final frame = l.spectra[-2];
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: [
        // ---- стан ----
        Card(
          color: open ? const Color(0x3326C281) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(open ? Icons.volume_up : Icons.volume_off, color: open ? Colors.greenAccent : Colors.white38),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        active ? '${((a['freq_hz'] as num) / 1e6).toStringAsFixed(4)} МГц' : 'Звук вимкнено',
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (active) Text(_mods[a['mod']] ?? '', style: const TextStyle(color: Colors.white60)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  !active
                      ? 'Оберіть частоту або діапазон для автоскану'
                      : a['scanning'] == true
                      ? 'Автоскан: шукаю сигнал…'
                      : open
                      ? 'Є сигнал — звук іде'
                      : 'Тиша (сигнал нижче шумодава)',
                  style: TextStyle(color: open ? Colors.greenAccent : Colors.white60),
                ),
                const SizedBox(height: 8),
                // Рівень сигналу відносно шумодава
                LayoutBuilder(
                  builder: (_, c) {
                    final t = ((level ?? 0) / 50).clamp(0.0, 1.0);
                    final sq = (_squelch / 50).clamp(0.0, 1.0);
                    return SizedBox(
                      height: 14,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                          ),
                          FractionallySizedBox(
                            widthFactor: t,
                            child: Container(
                              decoration: BoxDecoration(
                                color: open ? Colors.greenAccent : Colors.blueGrey,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          Positioned(
                            left: c.maxWidth * sq - 1,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 2, color: Colors.orange),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                Text(
                  'Рівень: ${level == null ? '—' : '${level.toStringAsFixed(0)} дБ над шумом'} · шумодав ${_squelch.round()} дБ'
                  '${_bytes > 0 ? ' · отримано ${(_bytes / 1024).round()} КБ' : ''}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ),
        if (frame != null)
          SizedBox(
            height: 120,
            child: CustomPaint(
              painter: SpectrumPainter(frame: frame, peak: null, signals: const [], showPeak: false),
              child: const SizedBox.expand(),
            ),
          ),
        const SizedBox(height: 8),

        // ---- частота й модуляція ----
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _freq,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Частота, МГц',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _listen(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(icon: const Icon(Icons.headphones), label: const Text('Слухати'), onPressed: _listen),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [for (final e in _mods.entries) ButtonSegment(value: e.key, label: Text(e.value))],
          selected: {_mod},
          onSelectionChanged: (s) {
            setState(() => _mod = s.first);
            if (active) _params();
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Шумодав: ${_squelch.round()} дБ над шумом'),
          subtitle: Slider(
            value: _squelch,
            min: 0,
            max: 40,
            divisions: 40,
            onChanged: (v) => setState(() => _squelch = v),
            onChangeEnd: (_) {
              if (active) _params();
            },
          ),
        ),
        if (active)
          OutlinedButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Зупинити звук і повернутися до сканування'),
            onPressed: _stop,
          ),

        // ---- автоскан ----
        const SizedBox(height: 12),
        const Text('Автоскан діапазону', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          'Модуль перевіряє ~2 МГц за раз і зупиняється на першому сигналі вище шумодава; '
          'сигнал зник на 2 с — шукає далі.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in _presets)
              ActionChip(
                avatar: const Icon(Icons.autorenew, size: 16),
                label: Text('${p.name} · ${_mods[p.mod]}'),
                onPressed: () => _autoscan(p),
              ),
          ],
        ),
        if (!_listening && !active)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Порада: гучність — кнопками телефону. Поки звук увімкнено, сканування дронів на модулі '
              'призупинено (приймач один).',
              style: TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
          ),
      ],
    );
  }
}
