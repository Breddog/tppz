import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../device_store.dart';
import '../models.dart';
import '../widgets/hotspot_help.dart';
import '../widgets/signal_widgets.dart';
import 'add_device_screen.dart';
import 'app_settings_screen.dart';
import 'device_screen.dart';
import 'direct_screen.dart';

/// Головний екран: усі модулі, як камери спостереження, або HackRF напряму (без Raspberry Pi).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _mode = 'pi'; // pi — модулі Raspberry Pi | direct — HackRF через USB OTG

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final m = p.getString('home.mode');
      if (m != null && mounted) setState(() => _mode = m);
    });
  }

  Future<void> _setMode(String m) async {
    setState(() => _mode = m);
    (await SharedPreferences.getInstance()).setString('home.mode', m);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    final direct = _mode == 'direct';
    return Scaffold(
      appBar: AppBar(
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'pi', icon: Icon(Icons.developer_board), label: Text('Модуль Pi')),
                ButtonSegment(value: 'direct', icon: Icon(Icons.usb), label: Text('HackRF напряму')),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => _setMode(v.first),
            ),
          ),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SDR Watch'),
            Text('збірка $appBuild', style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Налаштування застосунку',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppSettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: direct
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Додати модуль'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddDeviceScreen())),
            ),
      body: direct
          ? const DirectScreen()
          : store.devices.isEmpty
          ? const _Empty()
          : LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth > 900 ? 3 : (c.maxWidth > 560 ? 2 : 1);
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 90),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisExtent: 210,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: store.devices.length,
                  itemBuilder: (_, i) => DeviceCard(device: store.devices[i], key: ValueKey(store.devices[i].id)),
                );
              },
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 100),
      children: const [
        Icon(Icons.settings_input_antenna, size: 72, color: Colors.white24),
        SizedBox(height: 16),
        Text('Модулі ще не додано', textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
        SizedBox(height: 8),
        Text(
          'Увімкніть Raspberry Pi з SDR-приймачем і протягом 15 хвилин натисніть «Додати модуль» → '
          '«Знайти в локальній мережі».',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
        SizedBox(height: 20),
        HotspotHelp(compact: true),
      ],
    );
  }
}

class DeviceCard extends StatefulWidget {
  const DeviceCard({super.key, required this.device});

  final Device device;

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  late final ApiClient api = ApiClient(widget.device);
  Map<String, dynamic>? status;
  List<Signal> signals = [];
  String? error;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _refresh();
    _t = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final st = await api.status();
      final sg = await api.signals();
      if (!mounted) return;
      setState(() {
        status = st;
        signals = sg.where((s) => s.active).toList();
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = error == null && status != null;
    final top = [...signals]..sort((a, b) => (b.cls?.priority ?? 0).compareTo(a.cls?.priority ?? 0));
    final threat = top.isNotEmpty && (top.first.cls?.priority ?? 0) >= 2;
    final thumb = top.where((s) => s.thumbnailId != null).firstOrNull;
    final mode = status?['mode'] as String?;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: threat ? Colors.redAccent : Colors.white10, width: threat ? 1.5 : 1),
      ),
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceScreen(device: widget.device))),
        child: Stack(
          children: [
            if (thumb != null && online)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.25,
                  child: Image.network(
                    api.authUrl('/api/media/${thumb.thumbnailId}'),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: online ? Colors.greenAccent : Colors.redAccent),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.device.name,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (mode != null) _ModeChip(mode: mode),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    online
                        ? 'Активних сигналів: ${signals.length} · ${(status!['sdr'] as Map)['name']} · '
                              '${status!['cpu_temp_c'] != null ? '${status!['cpu_temp_c']}°C' : ''}'
                        : (error ?? 'Підключення…'),
                    style: TextStyle(color: online ? Colors.white60 : Colors.redAccent, fontSize: 12),
                  ),
                  const Spacer(),
                  if (online && status!['sdr_connected'] == false)
                    const Row(
                      children: [
                        Icon(Icons.usb_off, color: Colors.orangeAccent, size: 18),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'SDR не підключено — перевірте HackRF',
                            style: TextStyle(color: Colors.orangeAccent, fontSize: 12.5),
                          ),
                        ),
                      ],
                    )
                  else if (online && top.isEmpty)
                    const Row(
                      children: [
                        Icon(Icons.verified_outlined, color: Colors.greenAccent, size: 18),
                        SizedBox(width: 6),
                        Text('Ефір чистий', style: TextStyle(color: Colors.greenAccent)),
                      ],
                    ),
                  for (final s in top.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          ClassBadge(code: s.cls?.code, small: true),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${fmtFreq(s.freqHz)} ${s.distanceText}',
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final (txt, col) = switch (mode) {
      'scan' => ('Сканування', Colors.greenAccent),
      'watch' => ('Стеження', Colors.orangeAccent),
      _ => ('Пауза', Colors.white38),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: col),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(txt, style: TextStyle(color: col, fontSize: 11)),
    );
  }
}
