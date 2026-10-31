import 'package:flutter/material.dart';

import '../models.dart';

/// Смужка сили сигналу (за SNR).
class StrengthBar extends StatelessWidget {
  const StrengthBar({super.key, required this.snr, this.width = 46});

  final double snr;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = ((snr - 8) / 35).clamp(0.05, 1.0);
    final col = Color.lerp(Colors.amber, Colors.redAccent, t)!;
    return SizedBox(
      width: width,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(value: t, backgroundColor: Colors.white12, color: col),
      ),
    );
  }
}

class ClassBadge extends StatelessWidget {
  const ClassBadge({super.key, required this.code, this.text, this.small = false});

  final String? code;
  final String? text;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = classColor(code);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        border: Border.all(color: c.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(classIcon(code), size: small ? 12 : 14, color: c),
          const SizedBox(width: 4),
          Text(
            text ?? kClassNames[code] ?? 'Аналіз…',
            style: TextStyle(color: c, fontSize: small ? 11 : 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Рядок сигналу у списку.
class SignalTile extends StatelessWidget {
  const SignalTile({super.key, required this.s, this.onTap, this.onWatch});

  final Signal s;
  final VoidCallback? onTap;
  final VoidCallback? onWatch;

  @override
  Widget build(BuildContext context) {
    final c = s.cls;
    final dist = s.distance;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: classColor(c?.code).withValues(alpha: s.active ? 0.2 : 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(classIcon(c?.code), color: classColor(c?.code).withValues(alpha: s.active ? 1 : 0.5)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(fmtFreq(s.freqHz), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        if (s.channelName.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                            child: Text(s.channelName, style: const TextStyle(fontSize: 11)),
                          ),
                        ],
                        const Spacer(),
                        if (!s.active)
                          const Text('втрачено', style: TextStyle(color: Colors.white38, fontSize: 11))
                        else
                          StrengthBar(snr: s.snr),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      c == null ? 'Аналізується…' : (c.subtype.isNotEmpty ? '${c.label} · ${c.subtype}' : c.label),
                      style: TextStyle(color: classColor(c?.code), fontSize: 12.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (dist != null) '📏 ${dist['text']}',
                        'RSSI ${s.rssi.toStringAsFixed(0)} дБм',
                        'смуга ${fmtBw(s.hopping ? (s.raw['hop_bandwidth_hz'] as num? ?? 0).toDouble() : s.bandwidthHz)}',
                      ].join(' · '),
                      style: const TextStyle(color: Colors.white60, fontSize: 11.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (onWatch != null && (c?.canShowVideo ?? false))
                IconButton(
                  icon: const Icon(Icons.play_circle_fill, size: 30),
                  color: Colors.redAccent,
                  onPressed: onWatch,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Панель підказок під спектром/водоспадом — для користувачів, які не розбираються в радіо.
class HintsPanel extends StatelessWidget {
  const HintsPanel({super.key, required this.signals, this.peakHz, this.onTap});

  final List<Signal> signals;
  final double? peakHz;
  final void Function(Signal)? onTap;

  @override
  Widget build(BuildContext context) {
    final act = signals.where((s) => s.active).toList()
      ..sort((a, b) {
        final p = (b.cls?.priority ?? 0).compareTo(a.cls?.priority ?? 0);
        return p != 0 ? p : b.snr.compareTo(a.snr);
      });
    if (act.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.greenAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                peakHz == null
                    ? 'Ефір чистий: сигналів вище рівня шуму не знайдено.'
                    : 'Значущих сигналів немає. Найсильніший пік шуму: ${fmtFreq(peakHz!)}.',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Text(
            'Найактивніші сигнали (${act.length})',
            style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        for (final s in act.take(8))
          InkWell(
            onTap: onTap == null ? null : () => onTap!(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(classIcon(s.cls?.code), size: 16, color: classColor(s.cls?.code)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_plainHint(s), style: const TextStyle(fontSize: 12.5, height: 1.3))),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: StrengthBar(snr: s.snr, width: 34),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Пояснення простими словами.
  static String _plainHint(Signal s) {
    final c = s.cls;
    final where = '${fmtFreq(s.freqHz)}${s.channelName.isNotEmpty ? ' (канал ${s.channelName})' : ''}';
    final dist = s.distanceText.isNotEmpty ? ', відстань ${s.distanceText}' : '';
    switch (c?.code) {
      case 'analog_video':
        return '$where — відео з камери дрона, можна дивитися$dist';
      case 'analog_video_inverted':
        return '$where — відео з інвертованими кольорами, модуль виправляє автоматично$dist';
      case 'analog_video_scrambled':
        return '$where — кодоване відео (${c!.subtype})$dist';
      case 'analog_video_weak':
        return '$where — схоже на відео, але сигнал слабкий$dist';
      case 'digital_video':
        return '$where — цифрове відео (${c!.subtype}), картинку показати неможливо$dist';
      case 'control_link':
        final wifiNote = s.freqHz > 2.3e9 && s.freqHz < 2.5e9 ? ' (увага: на 2.4 ГГц буває Wi-Fi/Bluetooth)' : '';
        return '$where — пульт керування дроном (${c!.subtype})$dist$wifiNote';
      case 'telemetry':
        return '$where — телеметрія або інший вузький лінк$dist';
      case 'wifi':
        return '$where — схоже на Wi-Fi (роутер/телефон), зазвичай не загроза; '
            'але Wi-Fi буває і в цифрових FPV — зверніть увагу, чи рухається джерело';
      case 'known_service':
        final cell = c!.subtype.contains(RegExp('GSM|LTE|UMTS|5G'));
        return '$where — ${cell ? 'мобільний зв\'язок (базова станція)' : 'стороння служба: ${c.subtype}'}, не дрон';
      case null:
        return '$where — сигнал аналізується…';
      default:
        return '$where — ${c!.label.toLowerCase()}$dist';
    }
  }
}
