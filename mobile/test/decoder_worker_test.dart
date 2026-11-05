// Декодування в окремому потоці: кадр приходить, кольоровий, а черга не росте.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdrwatch/video/baseband_decoder.dart';
import 'package:sdrwatch/video/decoder_worker.dart';

void main() {
  test('isolate декодує кольоровий кадр і відкидає застарілі поля', () async {
    final w = DecoderWorker(BasebandDecoder());
    final got = <DecodedFrame>[];
    final done = Completer<void>();
    w.onFrame = (f, freq, chroma) {
      got.add(f);
      expect(chroma, isTrue);
      if (!done.isCompleted) done.complete();
    };
    await w.start();
    final bytes = File('test/fixtures/bb_color_pal.bin').readAsBytesSync();
    for (var i = 0; i < 10; i++) {
      w.push(bytes);
    }
    await done.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(got.first.stats.locked, isTrue);
    expect(got.first.stats.colorQuality, greaterThan(0.5));
    expect(got.length, lessThan(10)); // частину полів пропущено — без накопичення затримки
    expect(w.dropped, greaterThan(0));
    w.dispose();
  });
}
