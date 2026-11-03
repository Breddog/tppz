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

  test('PAL колір: смуги правильних кольорів (кадр збирає телефон)', () {
    final p = load('bb_color_pal');
    expect(p.hasChroma, isTrue);
    final f = BasebandDecoder().decode(p);
    expect(f.stats.locked, isTrue);
    expect(f.stats.colorQuality, greaterThan(0.5));
    List<double> bar(int k) {
      final x = ((k + 0.5) * f.width / 8).floor();
      final m = [0.0, 0.0, 0.0];
      for (var r = 100; r < 200; r++) {
        for (var c = 0; c < 3; c++) {
          m[c] += f.rgba[(r * f.width + x) * 4 + c] / 100;
        }
      }
      return m;
    }

    final yellow = bar(1), red = bar(5), blue = bar(6), green = bar(3);
    expect(yellow[2], lessThan(yellow[0] - 40)); // жовтий: мало синього
    expect(red[0], greaterThan(red[1] + 60)); // червоний
    expect(blue[2], greaterThan(blue[0] + 60)); // синій
    expect(green[1], greaterThan(green[0] + 40)); // зелений
  });

  test('без кольорової складової — як раніше, сірий', () {
    final f = BasebandDecoder().decode(load('bb_pal'));
    expect(f.rgba[(150 * f.width + 50) * 4], f.rgba[(150 * f.width + 50) * 4 + 2]);
  });

  test('HackRF напряму (DirectDsp, Java): колір і полярність без підказки модуля', () {
    final p = load('bb_direct_color');
    expect(p.polarityUnknown, isTrue);
    expect(p.hasChroma, isTrue);
    final f = BasebandDecoder().decode(p);
    expect(f.stats.locked, isTrue);
    expect(f.stats.inverted, isFalse);
    expect(f.stats.colorQuality, greaterThan(0.5));
    final x = ((5 + 0.5) * f.width / 8).floor(); // червона смуга
    final j = (150 * f.width + x) * 4;
    expect(f.rgba[j], greaterThan(f.rgba[j + 1] + 60));
  });

  test('HackRF напряму: інверсне відео визначається телефоном', () {
    final f = BasebandDecoder().decode(load('bb_direct_inv'));
    expect(f.stats.locked, isTrue);
    expect(f.stats.inverted, isTrue);
  });
}
