import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'baseband_decoder.dart';

/// Декодування відео в ОКРЕМОМУ потоці (isolate): інтерфейс, спектр і прокрутка не «підвисають»,
/// поки рахується кадр. Налаштування беруться з [settings] (звичайний BasebandDecoder, який сам
/// нічого не декодує) у момент надсилання кожного поля.
///
/// Реальний час важливіший за кожне поле: поки попереднє поле ще рахується, нове тримається
/// лише одне (найсвіжіше) — черга не росте, затримка не накопичується.
class DecoderWorker {
  DecoderWorker(this.settings);

  final BasebandDecoder settings;
  SendPort? _to;
  Isolate? _iso;
  ReceivePort? _from;
  bool _busy = false;
  Uint8List? _pending;
  bool _reset = false;
  int dropped = 0;
  void Function(DecodedFrame f, double freqHz, bool hasChroma)? onFrame;
  Completer<void>? _ready;

  Future<void> start() async {
    if (_ready != null) return _ready!.future;
    _ready = Completer<void>();
    final rp = ReceivePort();
    _from = rp;
    rp.listen(_onMessage);
    _iso = await Isolate.spawn(_main, rp.sendPort, debugName: 'video-decoder');
    return _ready!.future;
  }

  void resetAccumulation() => _reset = true;

  /// Надіслати поле (SDRB). Якщо потік зайнятий — замінює попереднє непочате поле.
  void push(Uint8List packet) {
    if (_to == null || _busy) {
      if (_pending != null) dropped++;
      _pending = packet;
      return;
    }
    _send(packet);
  }

  void _send(Uint8List packet) {
    _busy = true;
    final s = settings;
    _to!.send(<Object>[
      TransferableTypedData.fromList([packet]),
      s.polarity.index,
      s.accumulate,
      s.gain,
      s.descramble,
      s.autoContrast,
      s.color,
      s.saturation,
      _reset,
    ]);
    _reset = false;
  }

  void _onMessage(dynamic m) {
    if (m is SendPort) {
      _to = m;
      _ready?.complete();
      final p = _pending;
      _pending = null;
      if (p != null) _send(p);
      return;
    }
    _busy = false;
    if (m is List && m.length == 6) {
      final rgba = (m[2] as TransferableTypedData).materialize().asUint8List();
      final st = VideoStats()
        ..locked = (m[3] as List)[0] as bool
        ..standard = (m[3] as List)[1] as String?
        ..inverted = (m[3] as List)[2] as bool
        ..syncScore = (m[3] as List)[3] as double
        ..snrDb = (m[3] as List)[4] as double
        ..scrambled = (m[3] as List)[5] as String?
        ..deviationMhz = (m[3] as List)[6] as double
        ..afcOffsetKhz = (m[3] as List)[7] as double
        ..colorQuality = (m[3] as List)[8] as double;
      onFrame?.call(DecodedFrame(m[0] as int, m[1] as int, rgba, st), m[4] as double, m[5] as bool);
    }
    final p = _pending;
    _pending = null;
    if (p != null && _to != null) _send(p);
  }

  void dispose() {
    _iso?.kill(priority: Isolate.immediate);
    _from?.close();
    _iso = null;
    _to = null;
    _ready = null;
  }

  static void _main(SendPort out) {
    final rp = ReceivePort();
    out.send(rp.sendPort);
    final dec = BasebandDecoder();
    rp.listen((dynamic m) {
      final a = m as List;
      final bytes = (a[0] as TransferableTypedData).materialize().asUint8List();
      dec
        ..polarity = Polarity.values[a[1] as int]
        ..accumulate = a[2] as int
        ..gain = a[3] as double
        ..descramble = a[4] as bool
        ..autoContrast = a[5] as bool
        ..color = a[6] as bool
        ..saturation = a[7] as double;
      if (a[8] as bool) dec.resetAccumulation();
      final p = BasebandPacket.parse(bytes);
      if (p == null) {
        out.send(null);
        return;
      }
      final f = dec.decode(p);
      final s = f.stats;
      out.send(<Object?>[
        f.width,
        f.height,
        TransferableTypedData.fromList([f.rgba]),
        <Object?>[
          s.locked,
          s.standard,
          s.inverted,
          s.syncScore,
          s.snrDb,
          s.scrambled,
          s.deviationMhz,
          s.afcOffsetKhz,
          s.colorQuality,
        ],
        p.freqHz,
        p.hasChroma,
      ]);
    });
  }
}
