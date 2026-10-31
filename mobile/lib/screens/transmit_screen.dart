import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../models.dart';

/// Тестовий генератор: передати сигнал на заданій частоті, щоб перевірити приймання
/// інших пристроїв (приймачів FPV, сканерів). Передавач вмикається лише вручну й
/// сам вимикається за таймером.
class TransmitScreen extends StatefulWidget {
  const TransmitScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<TransmitScreen> createState() => _TransmitScreenState();
}

class _TransmitScreenState extends State<TransmitScreen> {
  static const _modes = {
    'bars': ('Тестова таблиця', 'Аналогове FPV-відео: смуги, рамка, хрест', Icons.grid_on),
    'image': ('Картинка як відео', 'Передати фото як аналогове FPV-відео', Icons.image),
    'carrier': ('Чиста несуча', 'Перевірити, чи приймач «бачить» частоту', Icons.cell_tower),
    'tone': ('Несуча + тон', 'FM-тон (свист у приймачі)', Icons.graphic_eq),
    'noise': ('Шум', 'Перевірити шумодав / пороги приймача', Icons.blur_on),
  };

  String _mode = 'bars';
  final _mhz = TextEditingController(text: '5800');
  String _standard = 'PAL';
  double _gain = 20;
  double _seconds = 60;
  bool _confirmed = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _tx;
  Uint8List? _image;
  bool _imageUploaded = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final j = await widget.api.get('/api/tx') as Map<String, dynamic>;
      if (mounted) setState(() => _tx = j);
    } catch (_) {}
  }

  bool get _active => _tx?['active'] == true;

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 720);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() {
      _image = bytes;
      _imageUploaded = false;
    });
  }

  Future<void> _start() async {
    final mhz = double.tryParse(_mhz.text.replaceAll(',', '.'));
    if (mhz == null) {
      setState(() => _error = 'Вкажіть частоту в МГц');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_mode == 'image') {
        if (_image == null) throw ApiException('Оберіть картинку');
        if (!_imageUploaded) {
          await widget.api.upload('/api/tx/image', {}, _image!);
          _imageUploaded = true;
        }
      }
      final r = await widget.api.post('/api/tx/start', {
        'mode': _mode,
        'freq_hz': mhz * 1e6,
        'gain_db': _gain.round(),
        'standard': _standard,
        'seconds': _seconds.round(),
      }) as Map<String, dynamic>;
      if (mounted) setState(() => _tx = r);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    try {
      final r = await widget.api.post('/api/tx/stop') as Map<String, dynamic>;
      if (mounted) setState(() => _tx = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final canTx = _tx == null || _tx!['can_transmit'] == true;
    final allowed = _tx == null || _tx!['allowed'] == true;
    final maxS = ((_tx?['max_seconds'] as num?) ?? 300).toDouble();
    return Scaffold(
      appBar: AppBar(title: const Text('Тестовий передавач')),
      body: _active ? _activeView() : _setupView(canTx, allowed, maxS),
    );
  }

  Widget _activeView() {
    final t = _tx!;
    final rem = (t['remaining_s'] as num?)?.toInt() ?? 0;
    final label = _modes[t['mode']]?.$1 ?? t['mode'];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cell_tower, size: 72, color: Colors.redAccent),
            const SizedBox(height: 12),
            const Text(
              'ПЕРЕДАЧА',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.redAccent),
            ),
            const SizedBox(height: 8),
            Text(
              '$label  ·  ${fmtFreq(((t['freq_hz'] as num).toDouble()))}',
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            Text('Підсилення ${t['gain_db']} дБ', style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 16),
            Text('Авто-стоп через $rem с', style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.all(16)),
                icon: const Icon(Icons.stop),
                label: const Text('ЗУПИНИТИ ПЕРЕДАЧУ', style: TextStyle(fontSize: 16)),
                onPressed: _stop,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setupView(bool canTx, bool allowed, double maxS) {
    if (!canTx) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Цей приймач не вміє передавати. Тестовий генератор працює лише з HackRF One.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          color: const Color(0x33FFC107),
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.amber),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Передавайте лише на навантаження/екрановано або на частотах, які вам дозволені. '
                    'Ефір у відкритому просторі регулюється законом, а передача може створити завади.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!allowed)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Передавання вимкнено в налаштуваннях модуля (tx.allow). Увімкніть його, якщо впевнені.',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        const SizedBox(height: 6),
        const Text('Що передати', style: TextStyle(fontWeight: FontWeight.bold)),
        RadioGroup<String>(
          groupValue: _mode,
          onChanged: (v) => setState(() => _mode = v!),
          child: Column(
            children: [
              for (final e in _modes.entries)
                RadioListTile<String>(
                  value: e.key,
                  title: Row(children: [Icon(e.value.$3, size: 18), const SizedBox(width: 8), Text(e.value.$1)]),
                  subtitle: Text(e.value.$2),
                  dense: true,
                ),
            ],
          ),
        ),
        if (_mode == 'image') ...[
          const SizedBox(height: 6),
          if (_image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(_image!, height: 120, fit: BoxFit.contain),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.photo_library),
            label: Text(_image == null ? 'Обрати картинку' : 'Змінити картинку'),
            onPressed: _pickImage,
          ),
        ],
        if (_mode == 'bars' || _mode == 'image') ...[
          const SizedBox(height: 10),
          const Text('Стандарт відео'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'PAL', label: Text('PAL')),
              ButtonSegment(value: 'NTSC', label: Text('NTSC')),
            ],
            selected: {_standard},
            onSelectionChanged: (s) => setState(() => _standard = s.first),
          ),
        ],
        const Divider(height: 28),
        TextField(
          controller: _mhz,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Частота, МГц', hintText: '5800'),
        ),
        const SizedBox(height: 12),
        Text('Підсилення передачі: ${_gain.round()} дБ (починайте з малого)'),
        Slider(
          value: _gain,
          min: 0,
          max: 47,
          divisions: 47,
          label: '${_gain.round()}',
          onChanged: (v) => setState(() => _gain = v),
        ),
        Text('Тривалість: ${_seconds.round()} с (авто-стоп)'),
        Slider(
          value: _seconds.clamp(5, maxS),
          min: 5,
          max: maxS,
          divisions: 60,
          label: '${_seconds.round()} с',
          onChanged: (v) => setState(() => _seconds = v),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _confirmed,
          onChanged: (v) => setState(() => _confirmed = v ?? false),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Я відповідаю за передачу на цій частоті', style: TextStyle(fontSize: 13)),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ),
        const SizedBox(height: 4),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.all(14)),
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.cell_tower),
          label: const Text('УВІМКНУТИ ПЕРЕДАЧУ', style: TextStyle(fontSize: 16)),
          onPressed: (_confirmed && allowed && !_busy) ? _start : null,
        ),
      ],
    );
  }
}
