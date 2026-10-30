import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../live.dart';
import '../models.dart';

/// Живе відео з аналогового FPV: вибір сигналу/каналу, AFC, інверсія, дескремблювання, запис.
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
  List<Map<String, dynamic>> _bands = [];
  bool _connecting = false;

  bool _watching(LiveConnection l) => l.status['mode'] == 'watch' || l.watch != null;

  @override
  void didUpdateWidget(covariant VideoTab old) {
    super.didUpdateWidget(old);
    if (!widget.active) _close();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _ensureStream() {
    if (_ws != null || _connecting || !widget.active) return;
    _connecting = true;
    try {
      _ws = WebSocketChannel.connect(Uri.parse(widget.api.wsUrl('/ws/video')));
      _sub = _ws!.stream.listen(
        (data) {
          if (data is! List<int>) return;
          _frames++;
          final now = DateTime.now();
          final dt = now.difference(_fpsT).inMilliseconds;
          if (dt > 2000) {
            _fps = _frames * 1000 / dt;
            _frames = 0;
            _fpsT = now;
          }
          if (mounted) setState(() => _frame = Uint8List.fromList(data));
        },
        onDone: _close,
        onError: (_) => _close(),
      );
    } finally {
      _connecting = false;
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

  @override
  Widget build(BuildContext context) {
    final l = context.watch<LiveConnection>();
    if (_watching(l)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStream());
      return _player(l);
    }
    _close();
    return _picker(l);
  }

  // ---- вибір, що дивитися --------------------------------------------------------------
  Widget _picker(LiveConnection l) {
    final vids = l.signals.where((s) => s.active && (s.cls?.canShowVideo ?? false)).toList();
    final digital = l.signals.where((s) => s.active && s.cls?.code == 'digital_video').toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('Знайдене аналогове відео', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        if (vids.isEmpty)
          const Text(
            'Поки що відеосигналів немає. Модуль продовжує сканування.',
            style: TextStyle(color: Colors.white54),
          ),
        for (final s in vids)
          Card(
            child: ListTile(
              leading: s.thumbnailId == null
                  ? Icon(classIcon(s.cls?.code), color: classColor(s.cls?.code))
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        widget.api.authUrl('/api/media/${s.thumbnailId}'),
                        width: 64,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(Icons.videocam),
                      ),
                    ),
              title: Text('${fmtFreq(s.freqHz)} ${s.channelName}'),
              subtitle: Text('${s.cls!.label}\n${s.distanceText}'),
              isThreeLine: true,
              trailing: const Icon(Icons.play_circle_fill, color: Colors.redAccent, size: 32),
              onTap: () => _do(() => widget.api.watch(trackId: s.id, freqHz: s.freqHz)),
            ),
          ),
        if (digital.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Цифрове відео (лише класифікація)', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final s in digital)
            ListTile(
              leading: Icon(Icons.hd, color: classColor(s.cls?.code)),
              title: Text('${fmtFreq(s.freqHz)} · ${s.cls!.subtype}'),
              subtitle: Text('Зображення зашифроване/цифрове — показати неможливо. ${s.distanceText}'),
            ),
        ],
        const Divider(height: 28),
        const Text('Налаштуватися вручну', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        _ManualTune(api: widget.api, bands: _bands, loadBands: _loadBands),
      ],
    );
  }

  Future<void> _loadBands() async {
    if (_bands.isNotEmpty) return;
    final j = await widget.api.get('/api/channels') as Map<String, dynamic>;
    setState(() => _bands = (j['bands'] as List).cast<Map<String, dynamic>>());
  }

  // ---- програвач ------------------------------------------------------------------------------
  Widget _player(LiveConnection l) {
    final w = l.watch;
    final v = (w?['video'] as Map<String, dynamic>?) ?? const {};
    final opts = (l.status['video_opts'] as Map?)?.cast<String, dynamic>() ?? {};
    final isVideo = v['is_video'] == true;
    final freq = (w?['freq_hz'] as num?)?.toDouble() ?? (l.status['watch_freq_hz'] as num?)?.toDouble() ?? 0;
    final ch = w?['channel'] as Map<String, dynamic>?;
    final rec = w?['recording'] == true;
    final searching = w?['searching'] == true;

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_frame != null) Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain),
                if (_frame == null || !isVideo)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (searching) const CircularProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(
                          searching ? 'Сигнал втрачено — пошук по сітці каналів…' : 'Немає синхронізації відео',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: _Osd(
                    lines: [
                      '${fmtFreq(freq)}${ch != null ? '  ${ch['name']} (${((ch['offset_hz'] as num) / 1e6).toStringAsFixed(1)} МГц)' : ''}',
                      if (isVideo)
                        '${v['standard']} · SNR ${v['snr_db']} дБ · синхро ${((v['sync_score'] as num) * 100).round()}%',
                      if (v['inverted'] == true) 'Інвертоване — виправлено',
                      if (v['scrambled'] != null)
                        'Скремблювання: ${v['scrambled']}${v['descrambled'] == true ? ' (дескрембльовано)' : ''}',
                      '${_fps.toStringAsFixed(1)} кадр/с',
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
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundBtn(icon: Icons.keyboard_double_arrow_left, label: '−5', onTap: () => _tune(freq - 5e6)),
                  _RoundBtn(icon: Icons.chevron_left, label: '−0.5', onTap: () => _tune(freq - 0.5e6)),
                  _RoundBtn(
                    icon: rec ? Icons.stop_circle : Icons.fiber_manual_record,
                    label: rec ? 'Стоп' : 'Запис',
                    color: Colors.redAccent,
                    onTap: () => _do(() => widget.api.record(!rec)),
                  ),
                  _RoundBtn(icon: Icons.chevron_right, label: '+0.5', onTap: () => _tune(freq + 0.5e6)),
                  _RoundBtn(icon: Icons.keyboard_double_arrow_right, label: '+5', onTap: () => _tune(freq + 5e6)),
                ],
              ),
              const SizedBox(height: 10),
              const Text('Полярність відео', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'auto', label: Text('Авто')),
                  ButtonSegment(value: 'normal', label: Text('Звичайна')),
                  ButtonSegment(value: 'inverted', label: Text('Інверсна')),
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
                title: const Text('Автопідстроювання частоти (AFC)'),
                subtitle: const Text('Тримає несучу по центру, навіть якщо VTX «пливе»'),
                value: opts['afc'] ?? true,
                onChanged: (v) => _setOpts({'afc': v}),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Автоконтраст'),
                value: opts['auto_contrast'] ?? true,
                onChanged: (v) => _setOpts({'auto_contrast': v}),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Дескремблювання'),
                subtitle: const Text('Спроба відновити кодоване відео (зсув/інверсія рядків)'),
                value: opts['descramble'] ?? true,
                onChanged: (v) => _setOpts({'descramble': v}),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.radar),
                label: const Text('Повернутися до сканування'),
                onPressed: () => _do(() async {
                  final st = await widget.api.post('/api/control/scan');
                  l.status = st as Map<String, dynamic>;
                  l.watch = null;
                  setState(() => _frame = null);
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _tune(double hz) => _do(() => widget.api.watch(freqHz: hz));

  Future<void> _setOpts(Map<String, dynamic> o) => _do(() async {
    final r = await widget.api.post('/api/control/video', o) as Map<String, dynamic>;
    if (!mounted) return;
    final l = context.read<LiveConnection>();
    l.status = {...l.status, 'video_opts': r['video_opts']};
    setState(() {});
  });
}

class _Osd extends StatelessWidget {
  const _Osd({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final s in lines) Text(s, style: const TextStyle(fontSize: 11, color: Colors.white))],
    ),
  );
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.label, required this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      IconButton.filledTonal(
        icon: Icon(icon, color: color),
        onPressed: onTap,
      ),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
    ],
  );
}

class _ManualTune extends StatefulWidget {
  const _ManualTune({required this.api, required this.bands, required this.loadBands});

  final ApiClient api;
  final List<Map<String, dynamic>> bands;
  final Future<void> Function() loadBands;

  @override
  State<_ManualTune> createState() => _ManualTuneState();
}

class _ManualTuneState extends State<_ManualTune> {
  final _mhz = TextEditingController();
  String? _band;

  @override
  void initState() {
    super.initState();
    widget.loadBands().catchError((_) {});
  }

  Future<void> _go(double hz) async {
    try {
      await widget.api.watch(freqHz: hz);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final analog = widget.bands.where((b) => b['kind'] == 'analog').toList();
    final band = analog.where((b) => b['code'] == _band).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _mhz,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Частота, МГц', hintText: '5800'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(_mhz.text.replaceAll(',', '.'));
                if (v != null) _go(v * 1e6);
              },
              child: const Text('Дивитися'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Або оберіть канал із відомої сітки:', style: TextStyle(color: Colors.white54)),
        Wrap(
          spacing: 6,
          children: [
            for (final b in analog)
              ChoiceChip(
                label: Text(b['code'] as String),
                selected: _band == b['code'],
                onSelected: (_) => setState(() => _band = b['code'] as String),
              ),
          ],
        ),
        if (band != null) ...[
          const SizedBox(height: 6),
          Text(band['title'] as String, style: const TextStyle(color: Colors.white54)),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in (band['channels'] as List).cast<Map<String, dynamic>>())
                ActionChip(
                  label: Text('${c['name']} · ${((c['freq_hz'] as num) / 1e6).toStringAsFixed(0)}'),
                  onPressed: () => _go((c['freq_hz'] as num).toDouble()),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
