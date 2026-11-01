import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../audio/audio_demod.dart';
import '../live.dart';
import '../widgets/spectrum_view.dart';
import '../widgets/tuning.dart';

/// Звук з ефіру: рації, мовлення, авіація. Модуль демодулює, телефон лише програє (24 кГц, моно).
class AudioPanel extends StatefulWidget {
  const AudioPanel({super.key, required this.api, this.listenRequest});

  final ApiClient api;

  /// Запит «слухати цю частоту» ззовні (зі списку знайденого, з маркера в «Ефірі»), Гц.
  final ValueNotifier<double?>? listenRequest;

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
  double _fHz = 446.00625e6;
  // Сканер
  String _scanMode = 'preset'; // preset | range | memory
  _Preset _preset = _presets.first;
  final _fromCtl = TextEditingController(text: '144.000');
  final _toCtl = TextEditingController(text: '146.000');
  double _rangeStep = 12.5e3;
  double _hold = 2;
  List<double> _memory = [];
  double _step = 12.5e3;
  Timer? _tuneT;
  DateTime _touched = DateTime(2000);
  bool _listening = false;
  int _bytes = 0;
  final _demod = PhoneAudioDemod();
  bool _phoneDemod = true; // false — старий модуль: готовий звук з модуля
  DateTime? _lastPkt;
  Timer? _fallback;

  @override
  void initState() {
    super.initState();
    _initPcm();
    SharedPreferences.getInstance().then((p) {
      final m = (p.getStringList('audio_memory') ?? const []).map(double.tryParse).whereType<double>().toList();
      if (mounted) setState(() => _memory = m);
    });
    widget.listenRequest?.addListener(_onRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRequest());
  }

  void _onRequest() {
    final hz = widget.listenRequest?.value;
    if (hz == null || !mounted) return;
    widget.listenRequest!.value = null;
    _freq.text = (hz / 1e6).toStringAsFixed(5);
    _fHz = hz;
    _listen();
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
    _tuneT?.cancel();
    widget.listenRequest?.removeListener(_onRequest);
    _closeWs();
    FlutterPcmSound.release().catchError((_) {});
    super.dispose();
  }

  void _openWs() {
    if (_ws != null) return;
    if (_phoneDemod) {
      // Модуль вирізає канал, телефон демодулює (менше затримки, модуль вільніший)
      _ws = WebSocketChannel.connect(Uri.parse(widget.api.wsUrl('/ws/audioiq')));
      _sub = _ws!.stream.listen(
        (data) {
          if (data is! List<int> || !_pcmReady) return;
          final b = data is Uint8List ? data : Uint8List.fromList(data);
          final p = AudioIqPacket.parse(b);
          if (p == null) return;
          _lastPkt = DateTime.now();
          _bytes += b.length;
          final pcm = _demod.process(p, squelchOpen: p.open);
          if (pcm.isNotEmpty) FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.sublistView(pcm)));
        },
        onDone: _closeWs,
        onError: (_) => _closeWs(),
      );
      _fallback?.cancel();
      _fallback = Timer(const Duration(seconds: 4), () {
        if (_lastPkt == null && _listening && mounted) {
          _closeWs();
          _phoneDemod = false; // модуль старої версії — беремо готовий звук
          _openWs();
        }
      });
      return;
    }
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
    _fallback?.cancel();
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

  /// Колесо/шкала: змінити частоту; якщо звук увімкнено — перебудувати модуль (не частіше ніж раз на 80 мс).
  void _setFreq(double hz) {
    hz = hz.clamp(1e6, 6e9);
    setState(() {
      _fHz = hz;
      _freq.text = (hz / 1e6).toStringAsFixed(5);
      _touched = DateTime.now();
    });
    final active = context.read<LiveConnection>().audio?['active'] == true;
    if (!active) return;
    _tuneT?.cancel();
    _tuneT = Timer(const Duration(milliseconds: 80), () {
      widget.api.post('/api/audio/params', {'freq_hz': _fHz}).catchError((_) => null);
    });
  }

  Future<void> _enterFreq() async {
    final c = TextEditingController(text: (_fHz / 1e6).toStringAsFixed(5));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Частота, МГц'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmitted: (t) => Navigator.pop(ctx, double.tryParse(t.replaceAll(',', '.'))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Скасувати')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.replaceAll(',', '.'))),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (v != null) _setFreq(v * 1e6);
  }

  Future<void> _listen() => _do(() async {
    final mhz = double.tryParse(_freq.text.replaceAll(',', '.'));
    if (mhz == null) throw ApiException('Вкажіть частоту в МГц');
    _fHz = mhz * 1e6;
    await widget.api.post('/api/audio/start', {'freq_hz': mhz * 1e6, 'mod': _mod, 'squelch_db': _squelch});
    _openWs();
    setState(() => _listening = true);
  });

  /// Для картки сканера (окремий віджет) — оновити стан панелі.
  void update(VoidCallback f) => setState(f);

  Future<void> _saveMemory() async {
    _memory.sort();
    (await SharedPreferences.getInstance()).setStringList('audio_memory', [for (final f in _memory) '$f']);
  }

  /// Сканер: пресет / від–до / збережені частоти. Модуль зупиняється на сигналі вище шумодава,
  /// після кінця передачі чекає «затримку» й шукає далі (як сканери Uniden / RadioShack).
  Future<void> _scan() => _do(() async {
    final body = <String, dynamic>{'mod': _mod, 'squelch_db': _squelch, 'hold_s': _hold};
    switch (_scanMode) {
      case 'preset':
        setState(() => _mod = _preset.mod);
        body['mod'] = _preset.mod;
        body['scan_start_hz'] = _preset.start * 1e6;
        body['scan_stop_hz'] = _preset.stop * 1e6;
        body['scan_step_hz'] = _preset.step * 1e3;
      case 'range':
        final a = double.tryParse(_fromCtl.text.replaceAll(',', '.'));
        final b = double.tryParse(_toCtl.text.replaceAll(',', '.'));
        if (a == null || b == null || b <= a) throw ApiException('Вкажіть діапазон «від» < «до», МГц');
        body['scan_start_hz'] = a * 1e6;
        body['scan_stop_hz'] = b * 1e6;
        body['scan_step_hz'] = _rangeStep;
      default:
        if (_memory.isEmpty) throw ApiException('Пам\'ять порожня — збережіть частоти кнопкою ★');
        body['scan_freqs'] = _memory.map((m) => m).toList();
    }
    await widget.api.post('/api/audio/start', body);
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
    // Автоскан модуля знайшов інший канал — показати (якщо користувач щойно не крутив сам)
    final mf = (a['freq_hz'] as num?)?.toDouble();
    if (active && mf != null && (mf - _fHz).abs() > 1 && DateTime.now().difference(_touched).inSeconds > 2) {
      _fHz = mf;
      _freq.text = (mf / 1e6).toStringAsFixed(5);
    }
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

        // ---- частота: дисплей, кнопка «звук», лінійка, колесо, крок ----
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: _enterFreq,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${(_fHz / 1e6).toStringAsFixed(_step < 1e4 ? 4 : 3)} МГц',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Зберегти частоту в пам\'ять сканера',
              icon: Icon(
                _memory.any((m) => (m - _fHz).abs() < 1) ? Icons.star : Icons.star_border,
                color: Colors.amberAccent,
              ),
              onPressed: () {
                setState(() {
                  if (_memory.any((m) => (m - _fHz).abs() < 1)) {
                    _memory.removeWhere((m) => (m - _fHz).abs() < 1);
                  } else {
                    _memory.add(_fHz);
                  }
                });
                _saveMemory();
              },
            ),
            // Один натиск — звук увімк./вимк.
            SizedBox(
              width: 76,
              height: 76,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  backgroundColor: active ? Colors.redAccent : Colors.greenAccent.shade700,
                ),
                onPressed: active ? _stop : _listen,
                child: Icon(active ? Icons.volume_off : Icons.volume_up, size: 34),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        FrequencyRuler(
          freqHz: _fHz,
          stepHz: _step,
          spanHz: (_step * 80).clamp(100e3, 2.0e6),
          spectrum: l.spectra[-2],
          onChanged: _setFreq,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final st in const [1e3, 5e3, 6.25e3, 12.5e3, 25e3, 100e3, 1e6])
                    ChoiceChip(
                      label: Text(st >= 1e6 ? '1 МГц' : '${(st / 1e3).toString().replaceAll(RegExp(r'\.0$'), '')} кГц'),
                      selected: _step == st,
                      onSelected: (_) => setState(() => _step = st),
                    ),
                ],
              ),
            ),
            TuningKnob(size: 130, onSteps: (n) => _setFreq(_fHz + n * _step)),
          ],
        ),
        const Text(
          'Тягніть шкалу або крутіть колесо — частота змінюється на крок; дотик до шкали — перейти туди. '
          'Під шкалою — живий спектр: горби — сигнали.',
          style: TextStyle(color: Colors.white38, fontSize: 11),
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
        Row(
          children: [
            const Icon(Icons.volume_up, size: 18, color: Colors.white54),
            Expanded(
              child: Slider(
                value: _demod.volume,
                min: 0.2,
                max: 4,
                onChanged: (v) => setState(() => _demod.volume = v),
              ),
            ),
            Text(
              _phoneDemod ? 'демодулює телефон' : 'звук з модуля',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        if (active)
          OutlinedButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Зупинити звук і повернутися до сканування'),
            onPressed: _stop,
          ),

        // ---- сканер (автоскан звуку) ----
        const SizedBox(height: 12),
        _ScannerCard(
          state: this,
          scan: (a['scan'] as Map?)?.cast<String, dynamic>(),
          scanning: a['scanning'] == true,
          active: active,
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

class _ScannerCard extends StatelessWidget {
  const _ScannerCard({required this.state, required this.scan, required this.scanning, required this.active});

  final _AudioPanelState state;
  final Map<String, dynamic>? scan;
  final bool scanning;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final st = state;
    final api = st.widget.api;
    final found = ((scan?['found'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final lockout = ((scan?['lockout'] as List?) ?? const []).cast<num>();
    String ago(num? t) {
      if (t == null) return '';
      final s = DateTime.now().millisecondsSinceEpoch / 1000 - t;
      return s < 60
          ? '${s.round()} с тому'
          : (s < 3600 ? '${(s / 60).round()} хв тому' : '${(s / 3600).round()} год тому');
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.radar, size: 18),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Сканер (автоскан звуку)', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (scan != null)
                  Text(
                    scanning ? 'шукає…' : 'на сигналі',
                    style: TextStyle(color: scanning ? Colors.white60 : Colors.greenAccent, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'preset', label: Text('Пресети')),
                ButtonSegment(value: 'range', label: Text('Від–до')),
                ButtonSegment(value: 'memory', label: Text('Пам\'ять')),
              ],
              selected: {st._scanMode},
              onSelectionChanged: (v) => st.update(() => st._scanMode = v.first),
            ),
            const SizedBox(height: 6),
            if (st._scanMode == 'preset')
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in _AudioPanelState._presets)
                    ChoiceChip(
                      label: Text('${p.name} · ${_AudioPanelState._mods[p.mod]}'),
                      selected: identical(st._preset, p),
                      onSelected: (_) => st.update(() => st._preset = p),
                    ),
                ],
              ),
            if (st._scanMode == 'range') ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: st._fromCtl,
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
                      controller: st._toCtl,
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
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final s in const [5e3, 6.25e3, 8.33e3, 12.5e3, 25e3, 100e3])
                    ChoiceChip(
                      label: Text('крок ${(s / 1e3).toStringAsFixed(s % 1000 == 0 ? 0 : 2)} кГц'),
                      selected: st._rangeStep == s,
                      onSelected: (_) => st.update(() => st._rangeStep = s),
                    ),
                ],
              ),
            ],
            if (st._scanMode == 'memory')
              st._memory.isEmpty
                  ? const Text(
                      'Збережіть частоти зірочкою ★ біля дисплея частоти — сканер обходитиме лише їх.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    )
                  : Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final m in st._memory)
                          InputChip(
                            label: Text((m / 1e6).toStringAsFixed(4)),
                            onPressed: () => st._setFreq(m),
                            onDeleted: () {
                              st.update(() => st._memory.remove(m));
                              st._saveMemory();
                            },
                          ),
                      ],
                    ),
            Row(
              children: [
                Text('Затримка після передачі: ${st._hold.toStringAsFixed(1)} с', style: const TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: st._hold,
                    min: 0.5,
                    max: 10,
                    divisions: 19,
                    onChanged: (v) => st.update(() => st._hold = v),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Сканувати'),
                  onPressed: st._scan,
                ),
                if (scan != null && !scanning)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.block),
                    label: const Text('Пропустити (блок.)'),
                    onPressed: () => st._do(() => api.post('/api/audio/skip')),
                  ),
                if (scan != null && !scanning)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Далі'),
                    onPressed: () => st._do(() => api.post('/api/audio/resume')),
                  ),
                if (active)
                  OutlinedButton.icon(icon: const Icon(Icons.stop), label: const Text('Стоп'), onPressed: st._stop),
              ],
            ),
            if (found.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Знайдено (${found.length}) — натисніть, щоб слухати; ★ — у пам\'ять',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
              for (final e in found.take(15))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.record_voice_over, color: Colors.lightBlueAccent),
                  title: Text('${((e['freq_hz'] as num) / 1e6).toStringAsFixed(4)} МГц'),
                  subtitle: Text('+${e['level_db']} дБ · ${e['hits']}× · ${ago(e['last_seen'] as num?)}'),
                  onTap: () {
                    st._freq.text = (((e['freq_hz'] as num) / 1e6)).toStringAsFixed(5);
                    st._listen();
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.star_border, color: Colors.amberAccent),
                    onPressed: () {
                      final f = (e['freq_hz'] as num).toDouble();
                      if (!st._memory.any((m) => (m - f).abs() < 1)) {
                        st.update(() => st._memory.add(f));
                        st._saveMemory();
                      }
                    },
                  ),
                ),
            ],
            if (lockout.isNotEmpty) ...[
              const Text('Заблоковані (пропускаються):', style: TextStyle(color: Colors.white60, fontSize: 12)),
              Wrap(
                spacing: 6,
                children: [
                  for (final f in lockout)
                    InputChip(
                      avatar: const Icon(Icons.block, size: 14),
                      label: Text((f / 1e6).toStringAsFixed(4)),
                      onDeleted: () => st._do(() => api.post('/api/audio/resume?unlock=$f')),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
