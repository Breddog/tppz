import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/signal_widgets.dart';
import '../widgets/spectrum_view.dart';

/// Історія з кільцевого запису на флешці модуля: події, кліпи відео, архів водоспаду.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  final List<EventItem> _items = [];
  bool _loading = false;
  bool _end = false;
  int _minPriority = 0;
  String? _class;
  Map<String, dynamic>? _usage;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    _items.clear();
    _end = false;
    await _more();
    try {
      final u = await widget.api.get('/api/storage') as Map<String, dynamic>;
      if (mounted) setState(() => _usage = u);
    } catch (_) {}
  }

  Future<void> _more() async {
    if (_loading || _end) return;
    setState(() => _loading = true);
    try {
      final evs = await widget.api.events(
        beforeId: _items.isEmpty ? null : _items.last.id,
        limit: 40,
        minPriority: _minPriority,
        classCode: _class,
      );
      _items.addAll(evs);
      _end = evs.length < 40;
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _more();
          return false;
        },
        child: ListView.builder(
          itemCount: _items.length + 2,
          itemBuilder: (context, i) {
            if (i == 0) return _header();
            if (i == _items.length + 1) {
              if (_error != null) return Padding(padding: const EdgeInsets.all(16), child: Text(_error!));
              return _loading
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : (_items.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(30),
                            child: Center(child: Text('Історія порожня')),
                          )
                        : const SizedBox(height: 30));
            }
            final e = _items[i - 1];
            return _EventTile(e: e, api: widget.api);
          },
        ),
      ),
    );
  }

  Widget _header() {
    final u = _usage;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (u != null) ...[
            Row(
              children: [
                const Icon(Icons.sd_card_outlined, size: 18),
                const SizedBox(width: 6),
                Text('Флешка: ${fmtBytes(u['used_bytes'] as num)} з ${fmtBytes(u['quota_bytes'] as num)}'),
                const Spacer(),
                if (u['oldest_media_ts'] != null)
                  Text(
                    'з ${fmtTime((u['oldest_media_ts'] as num).toDouble())}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: ((u['used_bytes'] as num) / (u['quota_bytes'] as num)).clamp(0.0, 1.0).toDouble(),
            ),
            const SizedBox(height: 4),
            const Text(
              'Запис по колу: коли місце закінчується, найстаріші записи перезаписуються.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.movie_outlined),
                  label: const Text('Відеозаписи'),
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ClipsScreen(api: widget.api))),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.water),
                  label: const Text('Архів водоспаду'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => WaterfallHistoryScreen(api: widget.api)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in const [(0, 'Усе'), (1, 'Важливе'), (2, 'Загрози')])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(p.$2),
                      selected: _minPriority == p.$1 && _class == null,
                      onSelected: (_) {
                        _minPriority = p.$1;
                        _class = null;
                        _reload();
                      },
                    ),
                  ),
                for (final c in const ['analog_video', 'analog_video_scrambled', 'digital_video', 'control_link'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(kClassNames[c]!),
                      selected: _class == c,
                      onSelected: (_) {
                        _class = c;
                        _minPriority = 0;
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.e, required this.api});

  final EventItem e;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final kindTxt = switch (e.kind) {
      'new' => 'Виявлено',
      'lost' => 'Втрачено',
      'reacquired' => 'Знову з\'явився',
      'changed' => 'Уточнено клас',
      _ => e.kind,
    };
    final thumb = e.media.where((m) => m['kind'] == 'thumb').firstOrNull;
    final hasClip = e.media.any((m) => m['kind'] == 'clip');
    return ListTile(
      leading: thumb != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                api.authUrl('/api/media/${thumb['id']}'),
                width: 56,
                height: 42,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(classIcon(e.classCode)),
              ),
            )
          : CircleAvatar(
              backgroundColor: classColor(e.classCode).withValues(alpha: 0.2),
              child: Icon(classIcon(e.classCode), color: classColor(e.classCode), size: 20),
            ),
      title: Text('${fmtFreq(e.freqHz)} · ${e.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$kindTxt · ${fmtTime(e.ts)}${e.signal.distanceText.isNotEmpty ? ' · ${e.signal.distanceText}' : ''}',
        style: TextStyle(color: e.kind == 'lost' ? Colors.white38 : Colors.white60, fontSize: 12),
      ),
      trailing: hasClip ? const Icon(Icons.movie, color: Colors.redAccent) : null,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EventDetailScreen(api: api, e: e),
        ),
      ),
    );
  }
}

class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({super.key, required this.api, required this.e});

  final ApiClient api;
  final EventItem e;

  @override
  Widget build(BuildContext context) {
    final s = e.signal;
    return Scaffold(
      appBar: AppBar(title: Text(fmtTime(e.ts))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final m in e.media.where((m) => m['kind'] == 'clip'))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ClipPlayer(api: api, fileId: m['id'] as int),
            ),
          for (final m in e.media.where((m) => m['kind'] == 'thumb'))
            if (!e.media.any((x) => x['kind'] == 'clip'))
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  api.authUrl('/api/media/${m['id']}'),
                  errorBuilder: (_, _, _) =>
                      const Padding(padding: EdgeInsets.all(20), child: Text('Кадр перезаписано')),
                ),
              ),
          const SizedBox(height: 10),
          SignalTile(s: s),
          const SizedBox(height: 8),
          if (s.cls != null)
            for (final h in s.cls!.hints) Padding(padding: const EdgeInsets.all(4), child: Text('• $h')),
          if (s.video != null) Padding(padding: const EdgeInsets.all(4), child: Text('Відео: ${s.video}')),
        ],
      ),
    );
  }
}

/// Програвач кліпу: кадри MJPEG з флешки модуля.
class ClipPlayer extends StatefulWidget {
  const ClipPlayer({super.key, required this.api, required this.fileId});

  final ApiClient api;
  final int fileId;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer> {
  List<List<num>> _frames = [];
  int _i = 0;
  bool _playing = false;
  Timer? _t;
  String? _err;

  @override
  void initState() {
    super.initState();
    widget.api
        .get('/api/media/${widget.fileId}')
        .then((j) {
          final meta = (j as Map<String, dynamic>)['meta'] as Map<String, dynamic>;
          setState(() => _frames = (meta['frames'] as List).map((f) => (f as List).cast<num>()).toList());
          _show(0);
        })
        .catchError((e) {
          if (mounted) setState(() => _err = 'Запис перезаписано або недоступний');
        });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _show(int i) async {
    if (_frames.isEmpty) return;
    i = i % _frames.length;
    // Підвантажити кадр заздалегідь, щоб відтворення було плавним
    await precacheImage(
      NetworkImage(widget.api.authUrl('/api/clips/${widget.fileId}/frame/$i')),
      context,
    ).catchError((_) {});
    if (mounted) setState(() => _i = i);
  }

  void _toggle() {
    if (_playing) {
      _t?.cancel();
      setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    _step();
  }

  void _step() {
    if (!_playing || _frames.isEmpty) return;
    final next = (_i + 1) % _frames.length;
    final dt = next == 0 ? 0.5 : ((_frames[next][2] - _frames[_i][2]).toDouble()).clamp(0.03, 2.0);
    _t = Timer(Duration(milliseconds: (dt * 1000).round()), () async {
      await _show(next);
      _step();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) return Text(_err!, style: const TextStyle(color: Colors.white54));
    final url = widget.api.authUrl('/api/clips/${widget.fileId}/frame/$_i');
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            child: _frames.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Image.network(url, gaplessPlayback: true, fit: BoxFit.contain),
          ),
        ),
        Row(
          children: [
            IconButton(icon: Icon(_playing ? Icons.pause : Icons.play_arrow), onPressed: _toggle),
            Expanded(
              child: Slider(
                value: _i.toDouble(),
                max: (_frames.length - 1).clamp(0, 1 << 30).toDouble(),
                onChanged: _frames.length < 2 ? null : (v) => _show(v.round()),
              ),
            ),
            Text('${_i + 1}/${_frames.length}'),
          ],
        ),
      ],
    );
  }
}

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

class _ClipsScreenState extends State<ClipsScreen> {
  List<Map<String, dynamic>>? _clips;

  @override
  void initState() {
    super.initState();
    widget.api
        .get('/api/clips', {'limit': 200})
        .then((j) {
          setState(() => _clips = ((j as Map)['clips'] as List).cast<Map<String, dynamic>>());
        })
        .catchError((_) {
          if (mounted) setState(() => _clips = []);
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Відеозаписи')),
      body: _clips == null
          ? const Center(child: CircularProgressIndicator())
          : _clips!.isEmpty
          ? const Center(child: Text('Записів немає'))
          : ListView(
              children: [
                for (final c in _clips!)
                  ListTile(
                    leading: const Icon(Icons.movie),
                    title: Text('${fmtFreq((c['freq_hz'] as num? ?? 0).toDouble())} · ${c['label'] ?? ''}'),
                    subtitle: Text(
                      '${fmtTime((c['ts'] as num).toDouble())} · ${c['frames']} кадрів · '
                      '${c['duration_s'] ?? '?'} с · ${fmtBytes(c['size'] as num)}',
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: Text(fmtTime((c['ts'] as num).toDouble()))),
                          body: Padding(
                            padding: const EdgeInsets.all(12),
                            child: ClipPlayer(api: widget.api, fileId: c['id'] as int),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Архів водоспаду: що відбувалося в ефірі за обраний період.
class WaterfallHistoryScreen extends StatefulWidget {
  const WaterfallHistoryScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<WaterfallHistoryScreen> createState() => _WaterfallHistoryScreenState();
}

class _WaterfallHistoryScreenState extends State<WaterfallHistoryScreen> {
  List<String> _ranges = [];
  String? _range;
  int _minutes = 60;
  Map<String, dynamic>? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    widget.api
        .get('/api/waterfall/ranges')
        .then((j) {
          final r = ((j as Map)['ranges'] as List).cast<String>();
          setState(() {
            _ranges = r;
            _range = r.isEmpty ? null : r.first;
          });
          _load();
        })
        .catchError((_) {});
  }

  Future<void> _load() async {
    if (_range == null) return;
    setState(() => _loading = true);
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    try {
      final j = await widget.api.get('/api/waterfall', {
        'range_name': _range,
        'ts_from': now - _minutes * 60,
        'ts_to': now,
        'max_rows': 500,
      }) as Map<String, dynamic>;
      setState(() => _data = j);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final rows = d == null
        ? <Float32List>[]
        : (d['rows'] as List).reversed
              .map((r) => Float32List.fromList((r as List).map((v) => (v as num).toDouble()).toList()))
              .toList();
    final ts = d == null ? <num>[] : (d['ts'] as List).cast<num>();
    SpectrumFrame? frame;
    if (rows.isNotEmpty) {
      final sorted = List<double>.from(rows.first)..sort();
      frame = SpectrumFrame(
        0,
        _range!,
        (d!['f_start'] as num).toDouble(),
        (d['f_stop'] as num).toDouble(),
        rows.first,
        Float32List(rows.first.length)..fillRange(0, rows.first.length, sorted[sorted.length ~/ 4]),
        8,
        0,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Архів водоспаду')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _range,
                    items: [for (final r in _ranges) DropdownMenuItem(value: r, child: Text(r))],
                    onChanged: (v) {
                      _range = v;
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _minutes,
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('10 хв')),
                    DropdownMenuItem(value: 60, child: Text('1 год')),
                    DropdownMenuItem(value: 360, child: Text('6 год')),
                    DropdownMenuItem(value: 1440, child: Text('24 год')),
                    DropdownMenuItem(value: 10080, child: Text('7 днів')),
                  ],
                  onChanged: (v) {
                    _minutes = v!;
                    _load();
                  },
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: frame == null
                ? Center(child: Text(_ranges.isEmpty ? 'Архів ще не записано' : 'Немає даних за період'))
                : Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: SpectrumPainter.leftPad),
                            Text(fmtFreq(frame.fStart), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                            const Spacer(),
                            Text(fmtFreq(frame.fStop), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                          ],
                        ),
                        Expanded(
                          child: WaterfallView(rows: rows, frame: frame, signals: const []),
                        ),
                        if (ts.isNotEmpty)
                          Text(
                            '${fmtTime(ts.first.toDouble())} — ${fmtTime(ts.last.toDouble())}',
                            style: const TextStyle(fontSize: 11, color: Colors.white54),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
