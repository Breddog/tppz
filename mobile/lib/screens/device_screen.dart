import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../live.dart';
import '../models.dart';
import '../notify_settings.dart';
import '../widgets/signal_widgets.dart';
import '../widgets/spectrum_view.dart';
import 'control_tab.dart';
import 'history_tab.dart';
import 'signal_detail_screen.dart';
import 'video_tab.dart';

/// Перегляд одного модуля.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.device});

  final Device device;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final ApiClient api = ApiClient(widget.device);
  late final LiveConnection live = LiveConnection(api)..connect();
  int _tab = 0;
  StreamSubscription? _evSub;
  NotifySettings? _ns;
  // Переходи між вкладками: «дивитися відео тут» / «слухати тут»
  final _watchReq = ValueNotifier<double?>(null);
  final _listenReq = ValueNotifier<double?>(null);

  void _watchFreq(double hz) {
    setState(() => _tab = 0);
    _watchReq.value = hz;
  }

  void _listenFreq(double hz) {
    setState(() => _tab = 0);
    _listenReq.value = hz;
  }

  void _showInEfir(double hz) {
    live.focusFreq(hz);
    setState(() => _tab = 1);
  }

  @override
  void initState() {
    super.initState();
    NotifySettings.load().then((v) => _ns = v);
    _evSub = live.events.listen((e) {
      if (!mounted || e['kind'] != 'new') return;
      final s = Signal(e['track'] as Map<String, dynamic>);
      final ns = _ns;
      if (ns == null || !ns.inApp || !ns.allows(s.cls?.code, s.rssi, s.freqHz)) return;
      if (!ns.isQuietNow) {
        if (ns.sound) SystemSound.play(SystemSoundType.alert); // звуковий сигнал про нову знахідку
        if (ns.vibrate) HapticFeedback.heavyImpact();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: classColor(s.cls?.code).withValues(alpha: 0.95),
          content: Text('Новий сигнал: ${s.hint}'),
          action: SnackBarAction(label: 'Деталі', textColor: Colors.white, onPressed: () => openSignal(s)),
        ),
      );
    });
  }

  @override
  void dispose() {
    _evSub?.cancel();
    _watchReq.dispose();
    _listenReq.dispose();
    live.dispose();
    super.dispose();
  }

  void openSignal(Signal s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SignalDetailScreen(api: api, signal: s, onWatch: () => watchSignal(s)),
      ),
    );
  }

  Future<void> watchSignal(Signal s) async => _watchFreq(s.freqHz);

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: live,
      child: Scaffold(
        appBar: AppBar(
          title: Consumer<LiveConnection>(
            builder: (_, l, _) => Row(
              children: [
                Icon(Icons.circle, size: 10, color: l.connected ? Colors.greenAccent : Colors.redAccent),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.device.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          actions: [
            Consumer<LiveConnection>(
              builder: (_, l, _) {
                final mode = l.status['mode'] ?? (l.watch != null ? 'watch' : 'scan');
                return IconButton(
                  tooltip: mode == 'paused' ? 'Відновити сканування' : 'Пауза',
                  icon: Icon(mode == 'paused' ? Icons.play_arrow : Icons.pause),
                  onPressed: () async {
                    try {
                      final st = mode == 'paused'
                          ? await api.post('/api/control/scan')
                          : await api.post('/api/control/pause');
                      l.status = st as Map<String, dynamic>;
                      l.watch = null;
                      setState(() {});
                    } catch (e) {
                      _toast(e.toString());
                    }
                  },
                );
              },
            ),
          ],
        ),
        body: IndexedStack(
          index: _tab,
          children: [
            // Відео — головний екран (відкривається першим)
            VideoTab(
              api: api,
              active: _tab == 0,
              watchRequest: _watchReq,
              listenRequest: _listenReq,
              onShowInEfir: _showInEfir,
            ),
            LiveTab(onSignal: openSignal, onWatchFreq: _watchFreq, onListenFreq: _listenFreq),
            SignalsTab(onSignal: openSignal, onWatch: watchSignal),
            HistoryTab(api: api),
            ControlTab(api: api, device: widget.device),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            const NavigationDestination(icon: Icon(Icons.videocam_outlined), label: 'Відео'),
            const NavigationDestination(icon: Icon(Icons.ssid_chart), label: 'Ефір'),
            NavigationDestination(
              icon: Consumer<LiveConnection>(
                builder: (_, l, _) {
                  final n = l.signals.where((s) => s.active && (s.cls?.priority ?? 0) >= 2).length;
                  return Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.radar));
                },
              ),
              label: 'Сигнали',
            ),
            const NavigationDestination(icon: Icon(Icons.history), label: 'Історія'),
            const NavigationDestination(icon: Icon(Icons.tune), label: 'Керування'),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------
// Вкладка «Ефір»: спектр із рівнем шуму / водоспад + підказки

enum ViewMode { spectrum, waterfall, both }

class LiveTab extends StatefulWidget {
  const LiveTab({super.key, required this.onSignal, this.onWatchFreq, this.onListenFreq});

  final void Function(Signal) onSignal;
  final void Function(double hz)? onWatchFreq;
  final void Function(double hz)? onListenFreq;

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  ViewMode _mode = ViewMode.both;
  bool _peak = true;
  String? _highlight;
  double? _marker;
  int _rowOffset = 0;
  // жест масштабу
  ViewWindow? _startView;
  double _startFocusHz = 0;
  double _graphWidth = 1;

  ViewWindow _view(LiveConnection l, int sel, SpectrumFrame f) => l.views[sel] ?? ViewWindow(f.fStart, f.fStop);

  double _hzAt(double dx, ViewWindow v) {
    final w = _graphWidth - SpectrumPainter.leftPad;
    return v.lo + ((dx - SpectrumPainter.leftPad) / w).clamp(0.0, 1.0) * v.span;
  }

  ViewWindow _clamp(ViewWindow v, SpectrumFrame f) {
    final full = f.fStop - f.fStart;
    final minSpan = math.max(full / 2048 * 16, 20e3);
    var span = v.span.clamp(minSpan, full);
    var lo = v.lo.clamp(f.fStart, f.fStop - span);
    return ViewWindow(lo, lo + span);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final ranges = ((l.status['ranges'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final watching = l.watch != null || l.status['mode'] == 'watch' || l.audio?['active'] == true;
    final autoscan = l.watch?['autoscan'] != null;
    // «Наживо» — те, що приймач робить зараз: автоскан (загальний спектр), стеження або звук
    final liveSrc = l.audio?['active'] == true && l.spectra.containsKey(-2)
        ? -2
        : (autoscan && l.spectra.containsKey(-3) ? -3 : -1);
    final sel = (watching && (l.followWatch || l.selectedRange == null)) ? liveSrc : l.selectedRange;
    final vfo = l.audio?['active'] == true
        ? (l.audio!['freq_hz'] as num?)?.toDouble()
        : (l.watch?['freq_hz'] as num?)?.toDouble();
    final vfoBw = l.audio?['active'] == true ? 12.5e3 : 8e6;

    return Column(
      children: [
        // Вибір діапазону
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              if (watching)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    avatar: const Icon(Icons.sensors, size: 16),
                    label: Text(
                      'Наживо · ${liveSrc == -3
                          ? 'автоскан'
                          : liveSrc == -2
                          ? 'звук'
                          : 'стеження'}',
                    ),
                    selected: sel == liveSrc,
                    onSelected: (_) => setState(() => l.followWatch = true),
                  ),
                ),
              for (final r in ranges)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(r['name'] as String),
                    selected: sel == r['index'],
                    onSelected: (_) {
                      setState(() => l.followWatch = false);
                      l.selectRange(r['index'] as int);
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<ViewMode>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: ViewMode.spectrum, icon: Icon(Icons.show_chart, size: 18), tooltip: 'Спектр'),
                    ButtonSegment(value: ViewMode.waterfall, icon: Icon(Icons.water, size: 18), tooltip: 'Водоспад'),
                    ButtonSegment(
                      value: ViewMode.both,
                      icon: Icon(Icons.view_agenda_outlined, size: 18),
                      tooltip: 'Спектр + водоспад',
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Утримання піків',
                icon: Icon(Icons.vertical_align_top, color: _peak ? Colors.orangeAccent : Colors.white38),
                onPressed: () => setState(() => _peak = !_peak),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Жести',
                icon: const Icon(Icons.help_outline),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Жести'),
                    content: const Text(
                      '• Два пальці — масштаб\n• Тягнути — прокрутка частот\n• Утримати — маркер: «Відео тут» / '
                      '«Слухати тут»\n• Подвійний дотик — увесь діапазон\n• Водоспад угору/вниз — історія\n'
                      '• Дотик по сигналу — деталі',
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Зрозуміло'))],
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Рівні, палітра, згладжування',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () =>
                    showModalBottomSheet<void>(context: context, builder: (_) => const _SpectrumSettings()),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Увесь діапазон (скинути масштаб)',
                icon: const Icon(Icons.zoom_out_map),
                onPressed: sel == null
                    ? null
                    : () {
                        l.setView(sel, null);
                        setState(() {
                          _rowOffset = 0;
                          _marker = null;
                        });
                      },
              ),
            ],
          ),
        ),
        ScanParams(status: l.status, frame: sel == null ? null : l.spectra[sel]),
        Expanded(
          flex: 6,
          child: ValueListenableBuilder<int>(
            valueListenable: l.spectrumTick,
            builder: (context, _, _) {
              final frame = sel == null ? null : l.spectra[sel];
              if (frame == null) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!l.connected) const Icon(Icons.cloud_off, size: 40, color: Colors.white24),
                      if (l.connected) const CircularProgressIndicator(),
                      const SizedBox(height: 10),
                      Text(
                        l.connected ? 'Очікування першого проходу…' : (l.error ?? 'Підключення…'),
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                );
              }
              final v = _view(l, sel!, frame);
              final inRange = l.signals
                  .where((s) => s.freqHz + s.bandwidthHz / 2 >= v.lo && s.freqHz - s.bandwidthHz / 2 <= v.hi)
                  .toList();
              return LayoutBuilder(
                builder: (context, c) {
                  _graphWidth = c.maxWidth - 12;
                  final spec = CustomPaint(
                    painter: SpectrumPainter(
                      frame: frame,
                      peak: _peak ? l.peakHold[sel] : null,
                      signals: inRange,
                      showPeak: _peak,
                      highlightId: _highlight,
                      lo: v.lo,
                      hi: v.hi,
                      zoom: l.zoomSpectra[sel],
                      marker: _marker,
                      vfo: vfo,
                      vfoBw: vfoBw,
                    ),
                    child: const SizedBox.expand(),
                  );
                  final wf = WaterfallView(
                    rows: l.waterfall[sel] ?? const [],
                    frame: frame,
                    signals: inRange,
                    lo: v.lo,
                    hi: v.hi,
                    rowOffset: _rowOffset,
                    repaint: l.spectrumTick,
                  );
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _tap(d.localPosition, v, inRange),
                    onDoubleTap: () {
                      l.setView(sel, null);
                      setState(() {
                        _rowOffset = 0;
                        _marker = null;
                      });
                    },
                    onLongPressStart: (d) => _markerAt(context, l, _hzAt(d.localPosition.dx - 4, v)),
                    onScaleStart: (d) {
                      _startView = v;
                      _startFocusHz = _hzAt(d.localFocalPoint.dx - 4, v);
                    },
                    onScaleUpdate: (d) {
                      final s0 = _startView;
                      if (s0 == null) return;
                      if (d.pointerCount == 1 &&
                          _mode != ViewMode.spectrum &&
                          d.focalPointDelta.dy.abs() > d.focalPointDelta.dx.abs() * 1.5) {
                        // вертикально по водоспаду — назад/вперед у часі
                        final rows = (l.waterfall[sel]?.length ?? 0);
                        setState(
                          () =>
                              _rowOffset = (_rowOffset - d.focalPointDelta.dy.round()).clamp(0, math.max(0, rows - 20)),
                        );
                        return;
                      }
                      final span = s0.span / d.horizontalScale.clamp(0.05, 50);
                      final w = _graphWidth - SpectrumPainter.leftPad;
                      final rel = ((d.localFocalPoint.dx - 4 - SpectrumPainter.leftPad) / w).clamp(0.0, 1.0);
                      final lo = _startFocusHz - rel * span;
                      l.setView(sel, _clamp(ViewWindow(lo, lo + span), frame));
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
                      child: switch (_mode) {
                        ViewMode.spectrum => spec,
                        ViewMode.waterfall => wf,
                        ViewMode.both => Column(
                          children: [
                            Expanded(flex: 5, child: spec),
                            const SizedBox(height: 4),
                            Expanded(flex: 4, child: wf),
                          ],
                        ),
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _markerAt(BuildContext context, LiveConnection l, double hz) {
    setState(() => _marker = hz);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${(hz / 1e6).toStringAsFixed(3)} МГц',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.videocam),
                    label: const Text('Відео тут'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      widget.onWatchFreq?.call(hz);
                    },
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.headphones),
                    label: const Text('Слухати тут'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      widget.onListenFreq?.call(hz);
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.zoom_in),
                    label: const Text('Збільшити тут'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      final f = l.spectra[l.selectedRange ?? -1];
                      final sel = l.spectra.containsKey(-1) && l.watch != null ? -1 : l.selectedRange;
                      if (sel != null && f != null) {
                        final span = _view(l, sel, f).span / 4;
                        l.setView(sel, _clamp(ViewWindow(hz - span / 2, hz + span / 2), f));
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _tap(Offset p, ViewWindow v, List<Signal> sigs) {
    if (sigs.isEmpty) return;
    final hz = _hzAt(p.dx - 4, v);
    Signal? best;
    var bestD = double.infinity;
    for (final s in sigs) {
      final d = (s.freqHz - hz).abs() - s.bandwidthHz / 2;
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    if (best != null && bestD < v.span * 0.03) {
      setState(() => _highlight = best!.id);
      widget.onSignal(best);
    }
  }
}

/// Налаштування спектра/водоспаду: рівні (авто/вручну), палітра, згладжування.
class _SpectrumSettings extends StatefulWidget {
  const _SpectrumSettings();

  @override
  State<_SpectrumSettings> createState() => _SpectrumSettingsState();
}

class _SpectrumSettingsState extends State<_SpectrumSettings> {
  void _set(VoidCallback f) {
    setState(f);
    SpectrumPrefs.notify();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Спектр і водоспад', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Рівні автоматично'),
              subtitle: const Text('Від рівня шуму до найсильнішого сигналу'),
              value: SpectrumPrefs.autoLevels,
              onChanged: (v) => _set(() => SpectrumPrefs.autoLevels = v),
            ),
            if (!SpectrumPrefs.autoLevels) ...[
              Text('Мінімум (чорне): ${SpectrumPrefs.minDb.round()} дБ'),
              Slider(
                value: SpectrumPrefs.minDb,
                min: -160,
                max: -20,
                onChanged: (v) => _set(() => SpectrumPrefs.minDb = math.min(v, SpectrumPrefs.maxDb - 5)),
              ),
              Text('Максимум (найяскравіше): ${SpectrumPrefs.maxDb.round()} дБ'),
              Slider(
                value: SpectrumPrefs.maxDb,
                min: -140,
                max: 0,
                onChanged: (v) => _set(() => SpectrumPrefs.maxDb = math.max(v, SpectrumPrefs.minDb + 5)),
              ),
            ],
            Text('Згладжування лінії: ${(SpectrumPrefs.smoothing * 100).round()} %'),
            Slider(
              value: SpectrumPrefs.smoothing,
              min: 0,
              max: 0.9,
              divisions: 9,
              onChanged: (v) => _set(() => SpectrumPrefs.smoothing = v),
            ),
            const Text('Палітра водоспаду'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                for (final name in kPalettes.keys)
                  ChoiceChip(
                    label: Text(name),
                    selected: SpectrumPrefs.palette == name,
                    onSelected: (_) => _set(() => SpectrumPrefs.palette = name),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------
// Вкладка «Сигнали»

class SignalsTab extends StatefulWidget {
  const SignalsTab({super.key, required this.onSignal, required this.onWatch});

  final void Function(Signal) onSignal;
  final void Function(Signal) onWatch;

  @override
  State<SignalsTab> createState() => _SignalsTabState();
}

class _SignalsTabState extends State<SignalsTab> {
  String _filter = 'all';
  bool _showLost = true;

  bool _match(Signal s) {
    final c = s.cls?.code ?? '';
    return switch (_filter) {
      'video' => c.startsWith('analog') || c == 'digital_video',
      'control' => c == 'control_link' || c == 'telemetry',
      'other' => !(c.startsWith('analog') || c == 'digital_video' || c == 'control_link' || c == 'telemetry'),
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final list = l.signals.where((s) => _match(s) && (_showLost || s.active)).toList();
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              for (final f in const [('all', 'Усі'), ('video', 'Відео'), ('control', 'Керування'), ('other', 'Інші')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(f.$2),
                    selected: _filter == f.$1,
                    onSelected: (_) => setState(() => _filter = f.$1),
                  ),
                ),
              FilterChip(
                label: const Text('Втрачені'),
                selected: _showLost,
                onSelected: (v) => setState(() => _showLost = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text('Сигналів не знайдено', style: TextStyle(color: Colors.white54)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: list.length,
                  itemBuilder: (_, i) => SignalTile(
                    s: list[i],
                    onTap: () => widget.onSignal(list[i]),
                    onWatch: () => widget.onWatch(list[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Параметри сканування одним рядком (розгортається по натиску).
class ScanParams extends StatefulWidget {
  const ScanParams({super.key, required this.status, required this.frame});

  final Map<String, dynamic> status;
  final SpectrumFrame? frame;

  @override
  State<ScanParams> createState() => _ScanParamsState();
}

class _ScanParamsState extends State<ScanParams> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final st = widget.status;
    final stats = (st['stats'] as Map?)?.cast<String, dynamic>() ?? const {};
    final dsp = (st['dsp'] as Map?)?.cast<String, dynamic>() ?? const {};
    final gain = (st['gain'] as Map?)?.cast<String, dynamic>() ?? const {};
    final echo = (st['echo_filter'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ranges = ((st['ranges'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final f = widget.frame;
    final cur = f == null ? null : ranges.where((r) => r['index'] == f.range).firstOrNull;
    final full = ranges.where((r) => r['full'] == true).firstOrNull;
    final fs = (st['sample_rate'] as num?)?.toDouble();
    final mode = switch (st['mode']) {
      'scan' => 'сканування',
      'watch' => 'стеження',
      'audio' => 'звук',
      'transmit' => 'ПЕРЕДАЧА',
      'paused' => 'пауза',
      _ => '${st['mode'] ?? '—'}',
    };
    final line =
        '$mode · прохід ${stats['sweep_s'] ?? '—'} с'
        '${fs != null ? ' · смуга ${(fs / 1e6).toStringAsFixed(1)} МГц' : ''}'
        '${dsp['rbw_hz'] != null ? ' · RBW ${((dsp['rbw_hz'] as num) / 1e3).toStringAsFixed(1)} кГц' : ''}'
        ' · поріг ${dsp['threshold_db'] ?? '—'} дБ';
    final style = const TextStyle(fontSize: 11.5, color: Colors.white60);
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_open ? Icons.expand_less : Icons.tune, size: 14, color: Colors.white38),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(line, style: style, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.only(left: 18, top: 2, bottom: 4),
                child: Text(
                  [
                    if (f != null) 'Діапазон: ${fmtFreq(f.fStart)} – ${fmtFreq(f.fStop)}',
                    if (cur != null) 'Сегментів: ${cur['segments']} · проходів: ${cur['sweeps']}',
                    'FFT: ${dsp['fft_size'] ?? '—'} точок × ${dsp['averages'] ?? '—'} усереднень',
                    'Підтвердження: ${dsp['confirm_hits'] ?? '—'} проходи',
                    'Підсилення: LNA ${gain['lna']} · VGA ${gain['vga']} · AMP ${gain['amp'] == true ? 'так' : 'ні'}'
                        '${gain['auto'] == true ? ' (авто)' : ''}',
                    if (full != null) 'Повний діапазон: прохід ${full['pass_s'] ?? '…'} с',
                    'Ехо-фільтр: ${echo['enabled'] == true ? (echo['learning'] == true ? 'вивчає фон' : 'увімкнено') : 'вимкнено'}',
                    'Помилок SDR: ${stats['errors'] ?? 0}',
                  ].join('\n'),
                  style: style,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
