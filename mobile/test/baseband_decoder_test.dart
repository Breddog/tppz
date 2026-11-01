// Декодер відео на телефоні: пакети згенеровані модулем (pi/sdrwatch/dsp/baseband.py) із симулятора.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdrwatch/video/baseband_decoder.dart';

BasebandPacket load(String name) => BasebandPacket.parse(File('test/fixtures/$name.bin').readAsBytesSync())!;

void main() {
  test('PAL: синхронізація, розмір кадру', () {
    final f = BasebandDecoder().decode(load('bb_pal'));
    expect(f.stats.locked, isTrue);
    expect(f.stats.standard, 'PAL');
    expect(f.height, 288);
    expect(f.rgba.length, f.width * f.height * 4);
  });

  test('NTSC', () {
    final f = BasebandDecoder().decode(load('bb_ntsc'));
    expect(f.stats.standard, 'NTSC');
    expect(f.height, 240);
  });

  test('інверсне відео виправляється автоматично', () {
    final f = BasebandDecoder().decode(load('bb_inverted'));
    expect(f.stats.locked, isTrue);
    expect(f.stats.inverted, isTrue);
  });

  test('цифровий сигнал — сніг, а не відео', () {
    final f = BasebandDecoder().decode(load('bb_noise'));
    expect(f.stats.locked, isFalse);
    // сніг — різнобарвний, не чорний екран
    var sum = 0;
    for (var i = 0; i < f.rgba.length; i += 4) {
      sum += f.rgba[i];
    }
    final mean = sum / (f.rgba.length / 4);
    expect(mean, inInclusiveRange(60, 200));
  });

  test('накопичення не ламає кадр', () {
    final d = BasebandDecoder()..accumulate = 8;
    for (var i = 0; i < 5; i++) {
      final f = d.decode(load('bb_pal'));
      expect(f.stats.locked, isTrue);
    }
  });
}
