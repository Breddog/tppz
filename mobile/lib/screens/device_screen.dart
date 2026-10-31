import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../live.dart';
import '../models.dart';
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

  @override
  void initState() {
    super.initState();
    _evSub = live.events.listen((e) {
      if (!mounted || e['kind'] != 'new') return;
      final s = Signal(e['track'] as Map<String, dynamic>);
      if ((s.cls?.priority ?? 0) < 2) return;
      SystemSound.play(SystemSoundType.alert); // звуковий сигнал про нову знахідку
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

  Future<void> watchSignal(Signal s) async {
    try {
      await api.watch(trackId: s.id, freqHz: s.freqHz);
      setState(() => _tab = 2);
    } catch (e) {
      _toast(e.toString());
    }
  }

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
            LiveTab(onSignal: openSignal),
            SignalsTab(onSignal: openSignal, onWatch: watchSignal),
            VideoTab(api: api, active: _tab == 2),
            HistoryTab(api: api),
            ControlTab(api: api, device: widget.device),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
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
            const NavigationDestination(icon: Icon(Icons.videocam_outlined), label: 'Відео'),
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
  const LiveTab({super.key, required this.onSignal});

  final void Function(Signal) onSignal;

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  ViewMode _mode = ViewMode.both;
  bool _peak = true;
  String? _highlight;

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    final ranges = ((l.status['ranges'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final watching = l.spectra.containsKey(-1) && (l.status['mode'] == 'watch' || l.watch != null);
    final sel = watching ? -1 : l.selectedRange;
    final frame = sel == null ? null : l.spectra[sel];
    final inRange = frame == null
        ? <Signal>[]
        : l.signals
              .where((s) => s.freqHz + s.bandwidthHz / 2 >= frame.fStart && s.freqHz - s.bandwidthHz / 2 <= frame.fStop)
              .toList();
    double? peakHz;
    if (frame != null && frame.bins.isNotEmpty) {
      var bi = 0;
      for (var i = 1; i < frame.bins.length; i++) {
        if (frame.bins[i] > frame.bins[bi]) bi = i;
      }
      peakHz = frame.fStart + (frame.fStop - frame.fStart) * bi / (frame.bins.length - 1);
    }

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
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Chip(avatar: Icon(Icons.gps_fixed, size: 16), label: Text('Стеження')),
                ),
              for (final r in ranges)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(r['name'] as String),
                    selected: !watching && sel == r['index'],
                    onSelected: (_) => l.selectRange(r['index'] as int),
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
                    ButtonSegment(value: ViewMode.spectrum, label: Text('Спектр')),
                    ButtonSegment(value: ViewMode.waterfall, label: Text('Водоспад')),
                    ButtonSegment(value: ViewMode.both, icon: Icon(Icons.view_agenda_outlined, size: 18)),
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
                tooltip: 'Скинути піки',
                icon: const Icon(Icons.restart_alt),
                onPressed: l.clearPeaks,
              ),
            ],
          ),
        ),
        ScanParams(status: l.status, frame: frame),
        Expanded(
          flex: 6,
          child: frame == null
              ? Center(
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
                )
              : GestureDetector(
                  onTapUp: (d) => _tap(context, d.localPosition, frame, inRange),
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final spec = CustomPaint(
                        painter: SpectrumPainter(
                          frame: frame,
                          peak: _peak ? l.peakHold[sel] : null,
                          signals: inRange,
                          showPeak: _peak,
                          highlightId: _highlight,
                        ),
                        child: const SizedBox.expand(),
                      );
                      final wf = WaterfallView(rows: l.waterfall[sel] ?? const [], frame: frame, signals: inRange);
                      return Padding(
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
                      );
                    },
                  ),
                ),
        ),
        const Divider(height: 1),
        Expanded(
          flex: 3,
          child: HintsPanel(signals: inRange.isEmpty ? l.signals : inRange, peakHz: peakHz, onTap: widget.onSignal),
        ),
      ],
    );
  }

  void _tap(BuildContext context, Offset p, SpectrumFrame f, List<Signal> sigs) {
    final box = context.size;
    if (box == null || sigs.isEmpty) return;
    final w = box.width - 12 - SpectrumPainter.leftPad;
    final hz = f.fStart + (p.dx - 4 - SpectrumPainter.leftPad) / w * (f.fStop - f.fStart);
    Signal? best;
    var bestD = double.infinity;
    for (final s in sigs) {
      final d = (s.freqHz - hz).abs() - s.bandwidthHz / 2;
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    if (best != null && bestD < (f.fStop - f.fStart) * 0.03) {
      setState(() => _highlight = best!.id);
      widget.onSignal(best);
    }
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
