// Демодуляція звуку на телефоні: пакети згенеровані модулем (pi/sdrwatch/dsp/audio.py) із симулятора.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdrwatch/audio/audio_demod.dart';

List<int> decode(String mode) {
  final b = File('test/fixtures/aiq_$mode.bin').readAsBytesSync();
  final d = PhoneAudioDemod();
  final pcm = <int>[];
  var off = 0, k = 0;
  while (off < b.length) {
    final n = ByteData.sublistView(b).getUint32(off, Endian.little);
    final p = AudioIqPacket.parse(Uint8List.sublistView(b, off + 4, off + 4 + n))!;
    final o = d.process(p);
    if (k++ > 0) pcm.addAll(o);
    off += 4 + n;
  }
  return pcm;
}

int tone(List<int> pcm) {
  var best = 0.0, bf = 0;
  for (var f = 300; f <= 3000; f += 20) {
    var re = 0.0, im = 0.0;
    for (var i = 0; i < pcm.length; i++) {
      re += pcm[i] * math.cos(2 * math.pi * f * i / 24000);
      im += pcm[i] * math.sin(2 * math.pi * f * i / 24000);
    }
    if (re * re + im * im > best) {
      best = re * re + im * im;
      bf = f;
    }
  }
  return bf;
}

void main() {
  for (final m in ['nfm', 'am']) {
    test('$m: тон 1 кГц, чутно, без кліпінгу', () {
      final pcm = decode(m);
      expect(tone(pcm), inInclusiveRange(980, 1020));
      final peak = pcm.map((e) => e.abs()).reduce(math.max);
      expect(peak, inInclusiveRange(3000, 32766));
    });
  }
}
