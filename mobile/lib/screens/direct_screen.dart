import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/frame_analysis.dart';
import '../direct/hackrf_direct.dart';
import '../models.dart';
import '../video/baseband_decoder.dart';
import '../video/decoder_worker.dart';
import '../widgets/spectrum_view.dart';
import 'analysis_bar.dart';
import 'video_tab.dart' show FullscreenVideo;

/// Режим «HackRF напряму»: HackRF під'єднано до телефону через USB OTG, Raspberry Pi не потрібен.
/// Головне — відео (колір, слабкі сигнали), спектр поточного вікна, підсилення і круговий автоскан
/// (сітки / весь діапазон / від–до).
class DirectScreen extends StatefulWidget {
  const DirectScreen({super.key});

  @override
  State<DirectScreen> createState() => _DirectScreenState();
}

class _Found {
  _Found(this.hz);

  final double hz;
  DateTime last = DateTime.now();
  int hits = 1;
  ui.Image? thumb;
}

class _DirectScreenState extends State<DirectScreen> {
  final hr = HackRfDirect.instance;
  final _dec = BasebandDecoder();
  late final _worker = DecoderWorker(_dec)..onFrame = _onFrame;
  final _img = ValueNotifier<ui.Image?>(null);
  final _spec = ValueNotifier<SpectrumFrame?>(null);
  StreamSubscription? _pSub, _sSub, _eSub;
  Timer? _statsTimer;

  String? _error;
  bool _opening = false;
  bool _uploading = false;
  VideoStats? _stats;
  bool _gotChroma = false;
  Map<String, dynamic> _st = const {};

  double _freqMhz = 5800;
  final _mhzCtl = TextEditingController(text: '5800.0');
  int _lna = 32, _vga = 30;
  bool _amp = false;
  bool _color = true;
  double _rate = 20e6;

  // ---- автоскан ----
  List<GridBand> _bands = const [];
  final Set<String> _scanBands = {};
  String _scanMode = 'grids'; // grids | full | range
  final _fromCtl = TextEditingController(text: '5600');
  final _toCtl = TextEditingController(text: '6000');
  bool _scanning = false;
  bool _circular = true;
  double _dwell = 3;
  String _scanPos = '';
  double _roundS = 0;
  final Map<int, _Found> _found = {};
  void Function(VideoStats s, double freq)? _probeHook;
  void Function(SpectrumFrame f)? _specHook;

  @override
  void initState() {
    super.initState();
    _worker.start();
    FindingsStore.instance.load();
    _pSub = hr.packets.listen(_worker.push);
    _sSub = hr.spectra.listen((f) {
      _spec.value = f;
      _specHook?.call(f);
    });
    _eSub = hr.errors.listen((e) {
      if (mounted) setState(() => _error = e);
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!hr.opened) return;
      try {
        final s = await hr.stats();
        if (mounted) setState(() => _st = s);
      } catch (_) {}
    });
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _freqMhz = p.getDouble('direct.freq') ?? 5800;
    _mhzCtl.text = _freqMhz.toStringAsFixed(1);
    _lna = p.getInt('direct.lna') ?? 32;
    _vga = p.getInt('direct.vga') ?? 30;
    _amp = p.getBool('direct.amp') ?? false;
    _color = p.getBool('direct.color') ?? true;
    _rate = p.getDouble('direct.rate') ?? 20e6;
    try {
      _bands = await GridBand.load();
      _scanBands.addAll(_bands.where((b) => b.popular).map((b) => b.code));
    } catch (_) {}
    if (mounted) setState(() {});
    _open();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('direct.freq', _freqMhz);
    await p.setInt('direct.lna', _lna);
    await p.setInt('direct.vga', _vga);
    await p.setBool('direct.amp', _amp);
    await p.setBool('direct.color', _color);
    await p.setDouble('direct.rate', _rate);
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      if (!await hr.available()) {
        throw 'HackRF не під\'єднано.\n\nПід\'єднайте HackRF до телефону через OTG-перехідник (USB-C → USB-A). '
            'Якщо телефон не тягне живлення — OTG-кабель з додатковим живленням.';
      }
      await hr.open(rate: _rate);
      await hr.config(color: _color, targetFs: 4e6, maxFps: 25);
      await hr.gain(_lna, _vga, _amp);
      await hr.tune(_freqMhz * 1e6);
    } catch (e) {
      _error = e is PlatformException ? (e.message ?? e.code) : '$e';
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _scanning = false;
    _statsTimer?.cancel();
    _pSub?.cancel();
    _sSub?.cancel();
    _eSub?.cancel();
    _worker.dispose();
    hr.close();
    _img.value?.dispose();
    for (final f in _found.values) {
      f.thumb?.dispose();
    }
    super.dispose();
  }

  // ---- кадри -----------------------------------------------------------------------------------
  void _onFrame(DecodedFrame f, double freqHz, bool hasChroma) {
    if (!mounted) return;
    _probeHook?.call(f.stats, freqHz);
    AutoAnalyzer.instance.feed(f, freqHz);
    if (f.stats.locked && f.stats.standard != null) {
      // підказати Java піднесучу для кольору (PAL/NTSC)
      final fsc = f.stats.standard == 'NTSC' ? 3.579545e6 : 4.43361875e6;
      if (_lastFsc != fsc) {
        _lastFsc = fsc;
        hr.config(fsc: fsc);
      }
    }
    if (_uploading) return;
    _uploading = true;
    _gotChroma = hasChroma;
    ui.decodeImageFromPixels(f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, (img) {
      _uploading = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      final old = _img.value;
      _img.value = img;
      old?.dispose();
      _maybeThumb(f, freqHz);
      final was = _stats?.locked;
      _stats = f.stats;
      if (was != f.stats.locked) setState(() {});
    });
  }

  double _lastFsc = 0;

  void _maybeThumb(DecodedFrame f, double freqHz) {
    if (!f.stats.locked || f.stats.syncScore < 0.6) return;
    final e = _found[(freqHz / 1e6).round()];
    if (e == null || (e.thumb != null && DateTime.now().difference(e.last).inSeconds < 3)) return;
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
        e.thumb?.dispose();
        e.thumb = img;
      });
    });
  }

  // ---- настройка -------------------------------------------------------------------------------
  Future<void> _tune(double mhz) async {
    _freqMhz = mhz.clamp(1, 6000);
    _mhzCtl.text = _freqMhz.toStringAsFixed(1);
    _worker.resetAccumulation();
    setState(() {});
    if (hr.opened) await hr.tune(_freqMhz * 1e6);
    _save();
  }

  void _goVideo(double hz) {
    setState(() => _scanning = false);
    _tune(hz / 1e6);
  }

  // ---- автоскан --------------------------------------------------------------------------------
  /// Дочекатися спектра саме з частоти hz (не раніше перенастройки).
  Future<SpectrumFrame?> _spectrumAt(double hz) {
    final c = Completer<SpectrumFrame?>();
    var skip = 1; // перший кадр після перенастройки може бути зібраний частково — беремо наступний
    _specHook = (f) {
      final mid = (f.fStart + f.fStop) / 2;
      if ((mid - hz).abs() > 1e5 || c.isCompleted) return;
      if (skip-- > 0) return;
      c.complete(f);
    };
    return c.future
        .timeout(const Duration(milliseconds: 600), onTimeout: () => null)
        .whenComplete(() => _specHook = null);
  }

  /// Чи є на частоті відео (синхроімпульси) — 3 поля, ~150 мс.
  Future<bool> _probe(double hz) async {
    await hr.tune(hz);
    final c = Completer<bool>();
    var n = 0;
    _probeHook = (s, f) {
      if ((f - hz).abs() > 1e5 || c.isCompleted) return;
      n++;
      if (s.locked && s.syncScore >= 0.5) {
        c.complete(true);
      } else if (n >= 3) {
        c.complete(false);
      }
    };
    return c.future
        .timeout(const Duration(milliseconds: 700), onTimeout: () => false)
        .whenComplete(() => _probeHook = null);
  }

  /// Вікна по 16 МГц, які покривають діапазон (центри, Гц), і кандидати в кожному.
  List<(double, List<double>)> _plan() {
    if (_scanMode == 'grids') {
      final fs = <double>{
        for (final b in _bands.where((b) => _scanBands.contains(b.code)))
          for (final f in b.freqsMhz)
            if (f >= 1 && f <= 6000) f * 1e6,
      }.toList()..sort();
      final out = <(double, List<double>)>[];
      var i = 0;
      while (i < fs.length) {
        final c = fs[i] + 7e6;
        final group = <double>[];
        while (i < fs.length && fs[i] <= c + 8e6) {
          group.add(fs[i++]);
        }
        out.add((c, group));
      }
      return out;
    }
    final lo = _scanMode == 'full' ? 10e6 : (double.tryParse(_fromCtl.text.replaceAll(',', '.')) ?? 5600) * 1e6;
    final hi = _scanMode == 'full' ? 6000e6 : (double.tryParse(_toCtl.text.replaceAll(',', '.')) ?? 6000) * 1e6;
    return [for (var c = lo + 8e6; c < hi + 8e6; c += 16e6) (c, const <double>[])];
  }

  Future<void> _scan(bool on) async {
    if (!on) {
      setState(() => _scanning = false);
      await hr.config(spectrumEveryField: false);
      return;
    }
    if (!hr.opened) return;
    setState(() => _scanning = true);
    await hr.config(spectrumEveryField: true);
    while (_scanning && mounted) {
      final plan = _plan();
      if (plan.isEmpty) break;
      final t0 = DateTime.now();
      for (final (c, grid) in plan) {
        if (!_scanning || !mounted) break;
        setState(() => _scanPos = '${(c / 1e6).toStringAsFixed(0)} МГц');
        await hr.tune(c);
        final f = await _spectrumAt(c);
        if (f == null) continue;
        final cands = grid.isNotEmpty
            ? [
                for (final g in grid)
                  if ((HackRfDirect.levelAt(f, g) ?? 0) > 5) g,
              ]
            : HackRfDirect.wideSignals(f);
        for (final hz in cands) {
          if (!_scanning || !mounted) break;
          if (await _probe(hz)) {
            await _onFound(hz);
          }
        }
      }
      _roundS = DateTime.now().difference(t0).inMilliseconds / 1000;
      if (mounted) setState(() {});
    }
    if (mounted) await hr.config(spectrumEveryField: false);
  }

  Future<void> _onFound(double hz) async {
    AutoAnalyzer.instance.found(hz, source: 'HackRF напряму');
    final key = (hz / 1e6).round();
    final e = _found[key];
    if (e == null) {
      _found[key] = _Found(hz);
    } else {
      e
        ..hits += 1
        ..last = DateTime.now();
    }
    setState(() {
      _freqMhz = hz / 1e6;
      _mhzCtl.text = _freqMhz.toStringAsFixed(1);
    });
    if (!_circular) {
      setState(() => _scanning = false);
      return;
    }
    // показати знайдене dwell секунд і шукати далі
    final until = DateTime.now().add(Duration(milliseconds: (_dwell * 1000).round()));
    await hr.config(spectrumEveryField: false);
    while (_scanning && mounted && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_scanning) await hr.config(spectrumEveryField: true);
  }

  // ---- інтерфейс -------------------------------------------------------------------------------
  Widget _screen() => ValueListenableBuilder<ui.Image?>(
    valueListenable: _img,
    builder: (_, img, _) => img == null
        ? const SizedBox.shrink()
        : RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
  );

  void _fullscreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FullscreenVideo(
          screen: _screen,
          freq: () => _freqMhz,
          onStep: (d) => _tune(_freqMhz + d),
          stats: () => _stats,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final locked = s?.locked ?? false;
    return ListView(
      padding: const EdgeInsets.only(bottom: 30),
      children: [
        if (_error != null || !hr.opened)
          Card(
            color: Colors.orange.withValues(alpha: 0.15),
            margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _opening ? 'Підключення до HackRF…' : (_error ?? 'HackRF не підключено'),
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: _opening
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.usb),
                    label: const Text('Підключити HackRF'),
                    onPressed: _opening ? null : _open,
                  ),
                ],
              ),
            ),
          ),
        // ---- відео ----
        GestureDetector(
          onDoubleTap: _fullscreen,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _screen(),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _Badge(
                      '${_freqMhz.toStringAsFixed(1)} МГц'
                      '${locked ? ' · ${s!.standard}${_gotChroma && s.colorQuality > 0 ? ' · колір' : ''}' : ''}',
                      good: locked,
                    ),
                  ),
                  if (_scanning) Positioned(right: 6, top: 6, child: _Badge('автоскан · $_scanPos', good: true)),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: IconButton(
                      icon: const Icon(Icons.fullscreen, color: Colors.white70),
                      onPressed: _fullscreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
          child: Text(
            [
              if (hr.info['board'] != null) '${hr.info['board']} ${hr.info['version'] ?? ''}'.trim(),
              if (_st['fields_s'] != null) '${(_st['fields_s'] as num).toStringAsFixed(0)} кадр/с',
              if (_st['usb_mbs'] != null) 'USB ${(_st['usb_mbs'] as num).toStringAsFixed(1)} МБ/с',
              if (_worker.dropped > 0) 'пропущено ${_worker.dropped}',
              if (!locked) 'немає відео — сніг',
            ].join(' · '),
            style: const TextStyle(fontSize: 11.5, color: Colors.white60),
          ),
        ),
        AnalysisBar(freqHz: () => _freqMhz * 1e6, source: 'HackRF напряму', enabled: hr.opened),
        // ---- частота ----
        Card(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_double_arrow_left),
                      onPressed: () => _tune(_freqMhz - 5),
                    ),
                    IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _tune(_freqMhz - 1)),
                    Expanded(
                      child: TextField(
                        controller: _mhzCtl,
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(suffixText: 'МГц', isDense: true),
                        onSubmitted: (v) => _tune(double.tryParse(v.replaceAll(',', '.')) ?? _freqMhz),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _tune(_freqMhz + 1)),
                    IconButton(
                      icon: const Icon(Icons.keyboard_double_arrow_right),
                      onPressed: () => _tune(_freqMhz + 5),
                    ),
                  ],
                ),
                SizedBox(
                  height: 90,
                  child: ValueListenableBuilder<SpectrumFrame?>(
                    valueListenable: _spec,
                    builder: (_, f, _) => f == null
                        ? const Center(
                            child: Text('Спектр з\'явиться після підключення', style: TextStyle(color: Colors.white38)),
                          )
                        : LayoutBuilder(
                            builder: (_, c) => GestureDetector(
                              // дотик по спектру — перейти на цю частоту
                              onTapUp: (d) => _tune(
                                (f.fStart + (f.fStop - f.fStart) * (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)) /
                                    1e6,
                              ),
                              child: CustomPaint(
                                painter: SpectrumPainter(
                                  frame: f,
                                  peak: null,
                                  signals: const [],
                                  showPeak: false,
                                  vfo: _freqMhz * 1e6,
                                  vfoBw: 8e6,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // ---- автоскан ----
        Card(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.radar),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Круговий автоскан', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    Switch(value: _scanning, onChanged: hr.opened ? _scan : null),
                  ],
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'grids', label: Text('Сітки')),
                    ButtonSegment(value: 'full', label: Text('Весь')),
                    ButtonSegment(value: 'range', label: Text('Від–до')),
                  ],
                  selected: {_scanMode},
                  onSelectionChanged: (v) => setState(() => _scanMode = v.first),
                ),
                const SizedBox(height: 6),
                if (_scanMode == 'grids')
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final b in _bands)
                        FilterChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(b.code),
                          tooltip: b.title,
                          selected: _scanBands.contains(b.code),
                          onSelected: (v) => setState(() => v ? _scanBands.add(b.code) : _scanBands.remove(b.code)),
                        ),
                    ],
                  ),
                if (_scanMode == 'range')
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _fromCtl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Від, МГц', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _toCtl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'До, МГц', isDense: true),
                        ),
                      ),
                    ],
                  ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_circular ? 'По колу: показ знайденого ${_dwell.round()} с' : 'Зупинятися на знайденому'),
                  value: _circular,
                  onChanged: (v) => setState(() => _circular = v),
                ),
                if (_circular)
                  Slider(value: _dwell, min: 1, max: 15, divisions: 14, onChanged: (v) => setState(() => _dwell = v)),
                if (_roundS > 0)
                  Text(
                    'Коло: ${_roundS.toStringAsFixed(1)} с',
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
              ],
            ),
          ),
        ),
        // ---- знайдене ----
        if (_found.isNotEmpty)
          Card(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Знайдене відео (${_found.length}) — натисніть, щоб дивитися',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 120,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final e in _found.values.toList()..sort((a, b) => b.last.compareTo(a.last)))
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: InkWell(
                              onTap: () => _goVideo(e.hz),
                              child: SizedBox(
                                width: 128,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AspectRatio(
                                      aspectRatio: 4 / 3,
                                      child: Container(
                                        color: Colors.black,
                                        child: e.thumb == null
                                            ? const Icon(Icons.videocam, color: Colors.white24)
                                            : RawImage(image: e.thumb, fit: BoxFit.fill),
                                      ),
                                    ),
                                    Text(
                                      '${(e.hz / 1e6).toStringAsFixed(0)} МГц · ${e.hits}×',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        // ---- приймач ----
        Card(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: ExpansionTile(
            shape: const Border(),
            title: const Text('Приймач і зображення', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              'LNA $_lna · VGA $_vga${_amp ? ' · AMP' : ''} · ${(_rate / 1e6).toStringAsFixed(0)} МГц · '
              '${_color ? 'колір' : 'Ч/Б'}',
              style: const TextStyle(fontSize: 12),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            children: [
              _slider('LNA', _lna.toDouble(), 40, 5, (v) => _lna = v.round()),
              _slider('VGA', _vga.toDouble(), 62, 31, (v) => _vga = v.round()),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('AMP (+14 дБ, для слабких сигналів)'),
                value: _amp,
                onChanged: (v) {
                  setState(() => _amp = v);
                  hr.gain(_lna, _vga, _amp);
                  _save();
                },
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Колір PAL/NTSC'),
                value: _color,
                onChanged: (v) {
                  setState(() => _color = v);
                  hr.config(color: v);
                  _save();
                },
              ),
              Row(
                children: [
                  SizedBox(width: 130, child: Text('Накопичення ×${_dec.accumulate}')),
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
              const Align(alignment: Alignment.centerLeft, child: Text('Частота дискретизації')),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 10e6, label: Text('10 МГц')),
                  ButtonSegment(value: 16e6, label: Text('16 МГц')),
                  ButtonSegment(value: 20e6, label: Text('20 МГц')),
                ],
                selected: {_rate},
                onSelectionChanged: (v) async {
                  setState(() => _rate = v.first);
                  await _save();
                  await hr.close();
                  _open();
                },
              ),
              const Text(
                '20 МГц — найкраща картинка; 10–16 МГц — для слабших телефонів (менше навантаження).',
                style: TextStyle(fontSize: 11.5, color: Colors.white54),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _slider(String name, double v, double max, int div, void Function(double) set) => Row(
    children: [
      SizedBox(width: 90, child: Text('$name ${v.round()} дБ')),
      Expanded(
        child: Slider(
          value: v.clamp(0, max),
          min: 0,
          max: max,
          divisions: div,
          onChanged: (x) => setState(() => set(x)),
          onChangeEnd: (_) {
            hr.gain(_lna, _vga, _amp);
            _save();
          },
        ),
      ),
    ],
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.good = false});

  final String text;
  final bool good;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: (good ? Colors.green : Colors.black).withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
  );
}
