// Вибір найкращого кадру й текст для озвучення (без ML Kit / мережі).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdrwatch/analysis/frame_analysis.dart';
import 'package:sdrwatch/video/baseband_decoder.dart';

void main() {
  test('найкращий кадр — з найчистішою синхронізацією; середнє — по всіх кадрах із відео', () {
    final p = BasebandPacket.parse(File('test/fixtures/bb_color_pal.bin').readAsBytesSync())!;
    final good = BasebandDecoder().decode(p);
    final noise = BasebandDecoder().decode(BasebandPacket.parse(File('test/fixtures/bb_noise.bin').readAsBytesSync())!);
    final c = FrameCapture(5800e6);
    c.feed(noise); // без відео — не враховується
    expect(c.best, isNull);
    final weak = DecodedFrame(good.width, good.height, good.rgba, VideoStats()
      ..locked = true
      ..syncScore = 0.4);
    c.feed(weak);
    c.feed(good);
    expect(identical(c.best, good), isTrue);
    expect(c.n, 2);
    expect(c.average()!.length, good.width * good.height * 4);
  });

  test('знахідка: збереження і текст для голосу', () {
    final f = Finding(
      id: '1',
      freqHz: 5865e6,
      time: DateTime(2026, 11, 5, 12),
      imagePath: '/x.png',
      ocrText: '14.8V\nALT 120',
      labels: ['поле', 'дорога'],
    );
    final g = Finding.fromJson(f.toJson());
    expect(g.ocrText, f.ocrText);
    expect(g.labels, f.labels);
    expect(g.spoken(), contains('5865 мегагерц'));
    expect(g.spoken(), contains('поле, дорога'));
    expect(g.spoken(), contains('14.8V, ALT 120'));
  });
}
