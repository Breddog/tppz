import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../netbind.dart';
import '../video/baseband_decoder.dart';

/// Аналіз кадрів знайденого відео.
///
/// Коли автоскан ловить відео, кілька секунд збираються кадри: найкращий (найчистіша синхронізація,
/// найменше шуму, колір) стає знімком, а середнє кількох кадрів (нерухомий екранний текст OSD стає
/// чіткішим) іде на розпізнавання тексту. Далі:
///   • без інтернету, на телефоні (ML Kit): текст на екрані (OSD) і що на кадрі (мітки);
///   • з інтернетом, за бажанням: детальний опис від Claude;
///   • усе озвучується (синтез мовлення телефона) і зберігається в «Знахідках».
class AnalysisSettings {
  static bool auto = true; // аналізувати знайдене автосканом
  static bool speak = true;
  static bool ocr = true;
  static bool labels = true;
  static bool ai = false;
  static String apiKey = '';
  static String model = 'claude-opus-5-5';
  static int repeatMin = 3; // ту саму частоту — не частіше, хв
  static final changed = ValueNotifier<int>(0);

  static const models = {
    'claude-opus-5-5': 'Claude Opus 5.5 — найточніший',
    'claude-sonnet-5-5': 'Claude Sonnet 5.5 — швидший, дешевший',
    'claude-haiku-5-5': 'Claude Haiku 5.5 — найдешевший',
  };

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    auto = p.getBool('an.auto') ?? auto;
    speak = p.getBool('an.speak') ?? speak;
    ocr = p.getBool('an.ocr') ?? ocr;
    labels = p.getBool('an.labels') ?? labels;
    ai = p.getBool('an.ai') ?? ai;
    apiKey = p.getString('an.key') ?? '';
    model = p.getString('an.model') ?? model;
    if (!models.containsKey(model)) model = 'claude-opus-5-5';
    repeatMin = p.getInt('an.repeat') ?? repeatMin;
    changed.value++;
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('an.auto', auto);
    await p.setBool('an.speak', speak);
    await p.setBool('an.ocr', ocr);
    await p.setBool('an.labels', labels);
    await p.setBool('an.ai', ai);
    await p.setString('an.key', apiKey);
    await p.setString('an.model', model);
    await p.setInt('an.repeat', repeatMin);
    changed.value++;
  }
}

/// Одна знахідка: знімок + що розпізнано.
class Finding {
  Finding({
    required this.id,
    required this.freqHz,
    required this.time,
    required this.imagePath,
    this.source = '',
    this.standard,
    this.ocrText = '',
    this.labels = const [],
    this.aiText,
    this.aiError,
  });

  final String id;
  final double freqHz;
  final DateTime time;
  final String imagePath;
  final String source;
  final String? standard;
  String ocrText;
  List<String> labels;
  String? aiText;
  String? aiError;

  Map<String, dynamic> toJson() => {
    'id': id,
    'freq_hz': freqHz,
    'time': time.toIso8601String(),
    'image': imagePath,
    'source': source,
    'standard': standard,
    'ocr': ocrText,
    'labels': labels,
    'ai': aiText,
    'ai_error': aiError,
  };

  factory Finding.fromJson(Map<String, dynamic> j) => Finding(
    id: j['id'] as String,
    freqHz: (j['freq_hz'] as num).toDouble(),
    time: DateTime.parse(j['time'] as String),
    imagePath: j['image'] as String,
    source: j['source'] as String? ?? '',
    standard: j['standard'] as String?,
    ocrText: j['ocr'] as String? ?? '',
    labels: ((j['labels'] as List?) ?? const []).cast<String>(),
    aiText: j['ai'] as String?,
    aiError: j['ai_error'] as String?,
  );

  /// Текст для озвучення.
  String spoken({bool withAi = true}) {
    final b = StringBuffer('Відео ${(freqHz / 1e6).round()} мегагерц.');
    if (labels.isNotEmpty) b.write(' На кадрі: ${labels.join(', ')}.');
    if (ocrText.trim().isNotEmpty) {
      final t = ocrText.replaceAll('\n', ', ');
      b.write(' На екрані: ${t.length > 160 ? t.substring(0, 160) : t}.');
    }
    if (withAi && aiText != null) b.write(' $aiText');
    return b.toString();
  }
}

/// Збережені знахідки (файл JSON + знімки PNG у теці застосунку).
class FindingsStore extends ChangeNotifier {
  FindingsStore._();

  static final instance = FindingsStore._();

  final List<Finding> items = [];
  Directory? _dir;
  bool _loaded = false;

  Future<Directory> dir() async {
    _dir ??= Directory('${(await getApplicationDocumentsDirectory()).path}/findings');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File('${(await dir()).path}/findings.json');
      if (await f.exists()) {
        final l = jsonDecode(await f.readAsString()) as List;
        items
          ..clear()
          ..addAll(l.map((e) => Finding.fromJson(e as Map<String, dynamic>)));
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    final f = File('${(await dir()).path}/findings.json');
    await f.writeAsString(jsonEncode([for (final i in items) i.toJson()]));
  }

  Future<void> add(Finding f) async {
    await load();
    items.insert(0, f);
    while (items.length > 300) {
      final old = items.removeLast();
      try {
        await File(old.imagePath).delete();
      } catch (_) {}
    }
    await _save();
    notifyListeners();
  }

  Future<void> changedItem() async {
    await _save();
    notifyListeners();
  }

  Future<void> remove(Finding f) async {
    items.remove(f);
    try {
      await File(f.imagePath).delete();
    } catch (_) {}
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    for (final f in [...items]) {
      try {
        await File(f.imagePath).delete();
      } catch (_) {}
    }
    items.clear();
    await _save();
    notifyListeners();
  }
}

/// Кадри одного сигналу: найкращий + середнє (для тексту OSD).
class FrameCapture {
  FrameCapture(this.freqHz, {this.manual = false}) : started = DateTime.now();

  final double freqHz;
  final bool manual;
  final DateTime started;
  DecodedFrame? best;
  double bestScore = -1;
  Float32List? _sum;
  int n = 0, w = 0, h = 0;

  static double score(VideoStats s) =>
      s.syncScore * 2 + (s.snrDb / 40).clamp(0.0, 1.0) + s.colorQuality.clamp(0.0, 1.0) * 0.5;

  void feed(DecodedFrame f) {
    if (!f.stats.locked) return;
    final sc = score(f.stats);
    if (sc > bestScore) {
      bestScore = sc;
      best = f;
    }
    if (_sum == null || w != f.width || h != f.height) {
      w = f.width;
      h = f.height;
      _sum = Float32List(w * h * 3);
      n = 0;
    }
    final s = _sum!, px = f.rgba;
    for (var i = 0, j = 0; j < s.length; i += 4, j += 3) {
      s[j] += px[i];
      s[j + 1] += px[i + 1];
      s[j + 2] += px[i + 2];
    }
    n++;
  }

  Uint8List? average() {
    if (_sum == null || n == 0) return null;
    final out = Uint8List(w * h * 4);
    final s = _sum!;
    for (var i = 0, j = 0; j < s.length; i += 4, j += 3) {
      out[i] = (s[j] / n).round();
      out[i + 1] = (s[j + 1] / n).round();
      out[i + 2] = (s[j + 2] / n).round();
      out[i + 3] = 255;
    }
    return out;
  }
}

/// Голос (синтез мовлення телефона, українською, якщо голос встановлено).
class Speaker {
  static FlutterTts? _tts;

  static Future<void> say(String text) async {
    try {
      if (_tts == null) {
        _tts = FlutterTts();
        await _tts!.setLanguage('uk-UA');
        await _tts!.setSpeechRate(0.5);
        await _tts!.awaitSpeakCompletion(true);
      }
      await _tts!.speak(text);
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

/// Автоматичний аналіз: знахідки автоскану → знімок найкращого кадру → розпізнавання → голос.
class AutoAnalyzer extends ChangeNotifier {
  AutoAnalyzer._();

  static final instance = AutoAnalyzer._();

  static const _collect = Duration(milliseconds: 2500); // скільки збирати кадри
  static const _maxFrames = 40;

  FrameCapture? _cap;
  String _source = '';
  final Map<int, DateTime> _done = {};
  bool busy = false;
  String? status;
  Future<void> _queue = Future.value();

  bool get capturing => _cap != null;

  /// Автоскан знайшов відео на частоті (виклик можна повторювати — повтори відкидаються).
  void found(double hz, {required String source}) {
    if (!AnalysisSettings.auto) return;
    final key = (hz / 2e6).round();
    final last = _done[key];
    if (last != null && DateTime.now().difference(last).inMinutes < AnalysisSettings.repeatMin) return;
    if (_cap != null && (_cap!.freqHz - hz).abs() < 2e6) return;
    _done[key] = DateTime.now();
    _start(FrameCapture(hz), source);
  }

  /// Кнопка «Аналіз кадру».
  void manual(double hz, {required String source}) {
    _done[(hz / 2e6).round()] = DateTime.now();
    _start(FrameCapture(hz, manual: true), source);
  }

  void _start(FrameCapture c, String source) {
    _finish();
    _cap = c;
    _source = source;
    status = 'Знімок ${(c.freqHz / 1e6).round()} МГц…';
    notifyListeners();
    Timer(c.manual ? const Duration(milliseconds: 1500) : _collect, () {
      if (identical(_cap, c)) _finish();
    });
  }

  /// Кожен декодований кадр (з частотою, на якій він знятий).
  void feed(DecodedFrame f, double freqHz) {
    final c = _cap;
    if (c == null) return;
    if ((freqHz - c.freqHz).abs() > 2e6) {
      // приймач пішов далі (автоскан) — аналізуємо те, що встигли зібрати
      if (DateTime.now().difference(c.started).inMilliseconds > 300) _finish();
      return;
    }
    c.feed(f);
    if (c.n >= _maxFrames) _finish();
  }

  void _finish() {
    final c = _cap;
    _cap = null;
    if (c == null) return;
    if (c.best == null) {
      status = null;
      notifyListeners();
      return;
    }
    final src = _source;
    _queue = _queue.then((_) => _analyze(c, src)).catchError((Object e) {
      status = 'Помилка аналізу: $e';
      notifyListeners();
    });
  }

  Future<void> _analyze(FrameCapture c, String source) async {
    busy = true;
    status = 'Розпізнавання ${(c.freqHz / 1e6).round()} МГц…';
    notifyListeners();
    final store = FindingsStore.instance;
    final dir = await store.dir();
    final best = c.best!;
    final stamp = DateTime.now();
    final id = '${stamp.millisecondsSinceEpoch}_${(c.freqHz / 1e6).round()}';
    // знімок у пропорціях 4:3 (як на екрані)
    final png = await _render(best.rgba, best.width, best.height, 1);
    final path = '${dir.path}/$id.png';
    await File(path).writeAsBytes(png);
    final f = Finding(
      id: id,
      freqHz: c.freqHz,
      time: stamp,
      imagePath: path,
      source: source,
      standard: best.stats.standard,
    );
    final tmp = await getTemporaryDirectory();
    // текст OSD — із середнього кадру, збільшеного (шум менший, літери чіткіші)
    if (AnalysisSettings.ocr) {
      try {
        final avg = c.average() ?? best.rgba;
        final big = await _render(avg, c.w == 0 ? best.width : c.w, c.h == 0 ? best.height : c.h, 3);
        final p = '${tmp.path}/ocr_$id.png';
        await File(p).writeAsBytes(big);
        final rec = TextRecognizer(script: TextRecognitionScript.latin);
        final r = await rec.processImage(InputImage.fromFilePath(p));
        await rec.close();
        f.ocrText = [
          for (final b in r.blocks)
            for (final l in b.lines)
              if (RegExp(r'[0-9A-Za-z]').allMatches(l.text).length >= 2) l.text.trim(),
        ].join('\n');
        File(p).delete().ignore();
      } catch (_) {}
    }
    if (AnalysisSettings.labels) {
      try {
        final lab = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.55));
        final r = await lab.processImage(InputImage.fromFilePath(path));
        await lab.close();
        f.labels = <String>{
          for (final l in r)
            if (kLabelsUk[l.label] != null) kLabelsUk[l.label]!,
        }.take(6).toList();
      } catch (_) {}
    }
    await store.add(f);
    busy = false;
    status = null;
    notifyListeners();
    if (AnalysisSettings.speak) await Speaker.say(f.spoken(withAi: false));
    if (AnalysisSettings.ai && AnalysisSettings.apiKey.isNotEmpty) {
      await describeWithAi(f);
      if (AnalysisSettings.speak && f.aiText != null) await Speaker.say(f.aiText!);
    }
  }

  /// Детальний опис кадру від Claude (потрібен інтернет і ключ API).
  static Future<void> describeWithAi(Finding f) async {
    try {
      final src = await File(f.imagePath).readAsBytes();
      final img = await _decode(src);
      final big = await _scaled(img, 2); // 768×576 — дрібні деталі й текст OSD читаються краще
      final b64 = base64Encode(big);
      final model = AnalysisSettings.model;
      final fallback = model != 'claude-haiku-5-5'; // Haiku не має заміни на сервері
      final body = <String, dynamic>{
        'model': model,
        'max_tokens': 1024,
        'output_config': {'effort': 'low'},
        if (fallback) 'fallbacks': 'default',
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64},
              },
              {'type': 'text', 'text': _prompt(f)},
            ],
          },
        ],
      };
      final r = await NetBind.forInternet(
        () => http
            .post(
              Uri.parse('https://api.anthropic.com/v1/messages'),
              headers: {
                'x-api-key': AnalysisSettings.apiKey,
                'anthropic-version': '2026-10-21',
                'content-type': 'application/json',
                if (fallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 60)),
      );
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        f.aiError = 'Помилка ШІ (${r.statusCode}): ${(j['error'] as Map?)?['message'] ?? r.body}';
      } else if (j['stop_reason'] == 'refusal') {
        f.aiError = 'ШІ відмовився описувати кадр';
      } else {
        final text = [
          for (final c in (j['content'] as List).cast<Map<String, dynamic>>())
            if (c['type'] == 'text') c['text'] as String,
        ].join(' ').trim();
        f.aiText = text.isEmpty ? null : text;
        f.aiError = null;
      }
    } catch (e) {
      f.aiError = 'Немає зв\'язку з ШІ: $e';
    }
    await FindingsStore.instance.changedItem();
  }

  static String _prompt(Finding f) =>
      'Це кадр аналогового FPV-відео з дрона, перехопленого радіоприймачем на частоті '
      '${(f.freqHz / 1e6).round()} МГц. Кадр може бути шумним, зі смугами, низької роздільності.\n'
      'Опиши українською 2–4 короткими реченнями для озвучення: що видно (місцевість, будівлі, дороги, '
      'техніка, люди, вода, ліс), куди і як високо приблизно летить дрон, якщо можна судити, і дані з '
      'екранного меню (OSD), якщо видно: напруга батареї, висота, відстань, швидкість, координати, позивний.\n'
      'Не вигадуй: якщо щось нечітко — так і скажи. Без форматування і списків.'
      '${f.ocrText.isNotEmpty ? '\nРозпізнаний на телефоні текст з екрана (може містити помилки): ${f.ocrText.replaceAll('\n', ' | ')}' : ''}';

  // ---- зображення ----------------------------------------------------------------------------
  static Future<ui.Image> _fromPixels(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  static Future<ui.Image> _decode(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    return (await codec.getNextFrame()).image;
  }

  /// Масштаб у k разів по висоті, ширина — до пропорцій 4:3.
  static Future<Uint8List> _scaled(ui.Image src, int k) async {
    final th = src.height * k, tw = (th * 4 / 3).round();
    final rec = ui.PictureRecorder();
    final cv = ui.Canvas(rec);
    cv.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      ui.Paint()..filterQuality = FilterQuality.high,
    );
    final out = await rec.endRecording().toImage(tw, th);
    final bd = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    return bd!.buffer.asUint8List();
  }

  static Future<Uint8List> _render(Uint8List rgba, int w, int h, int k) async {
    final img = await _fromPixels(rgba, w, h);
    final r = await _scaled(img, k);
    img.dispose();
    return r;
  }
}

/// Мітки ML Kit (англійською) → українською. Незнайомі мітки не озвучуємо.
const kLabelsUk = <String, String>{
  'Person': 'людина',
  'Crowd': 'натовп',
  'Team': 'група людей',
  'Car': 'автомобіль',
  'Vehicle': 'техніка',
  'Truck': 'вантажівка',
  'Bus': 'автобус',
  'Motorcycle': 'мотоцикл',
  'Bicycle': 'велосипед',
  'Tractor': 'трактор',
  'Train': 'потяг',
  'Boat': 'човен',
  'Ship': 'корабель',
  'Airplane': 'літак',
  'Aircraft': 'літальний апарат',
  'Helicopter': 'гелікоптер',
  'Building': 'будівля',
  'House': 'будинок',
  'Skyscraper': 'висотка',
  'Factory': 'завод',
  'Church': 'церква',
  'Tower': 'вежа',
  'Bridge': 'міст',
  'Road': 'дорога',
  'Street': 'вулиця',
  'Highway': 'шосе',
  'Railway': 'залізниця',
  'Parking': 'парковка',
  'City': 'місто',
  'Town': 'містечко',
  'Village': 'село',
  'Tree': 'дерева',
  'Forest': 'ліс',
  'Plant': 'рослинність',
  'Grass': 'трава',
  'Field': 'поле',
  'Farm': 'ферма',
  'Garden': 'сад',
  'Park': 'парк',
  'Mountain': 'гори',
  'Hill': 'пагорб',
  'Rock': 'скелі',
  'Sand': 'пісок',
  'Desert': 'пустеля',
  'Beach': 'пляж',
  'Water': 'вода',
  'River': 'річка',
  'Lake': 'озеро',
  'Sea': 'море',
  'Pier': 'пірс',
  'Snow': 'сніг',
  'Ice': 'лід',
  'Sky': 'небо',
  'Cloud': 'хмари',
  'Sunset': 'захід сонця',
  'Fire': 'вогонь',
  'Smoke': 'дим',
  'Bonfire': 'багаття',
  'Fence': 'паркан',
  'Wall': 'стіна',
  'Roof': 'дах',
  'Window': 'вікно',
  'Dog': 'собака',
  'Cat': 'кіт',
  'Bird': 'птах',
  'Horse': 'кінь',
  'Cattle': 'худоба',
  'Flag': 'прапор',
  'Military': 'військові',
  'Weapon': 'зброя',
  'Gun': 'зброя',
  'Tank': 'танк',
  'Helmet': 'шолом',
  'Night': 'ніч',
  'Room': 'приміщення',
};
