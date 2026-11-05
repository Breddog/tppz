import 'dart:io';

import 'package:flutter/services.dart';

/// Прив'язка застосунку до Wi-Fi без інтернету (див. MainActivity.kt).
///
/// Без неї Android шле запити до модуля через мобільний інтернет: модуль «знаходиться»
/// пошуком, але «недоступний».
class NetBind {
  static const _ch = MethodChannel('sdrwatch/net');
  static bool bound = false;

  /// Прив'язатися до Wi-Fi, якщо в ньому немає інтернету. true — прив'язано.
  static Future<bool> wifi() async {
    if (!Platform.isAndroid) return false;
    try {
      bound = await _ch.invokeMethod<bool>('bindWifi') ?? false;
    } catch (_) {
      bound = false; // напр. фоновий сервіс (окремий рушій без каналу)
    }
    return bound;
  }

  /// Виконати запит в ІНТЕРНЕТ (GitHub): тимчасово зняти прив'язку до Wi-Fi без інтернету.
  static Future<T> forInternet<T>(Future<T> Function() f) async {
    if (!bound) return f();
    try {
      await _ch.invokeMethod('unbind');
      bound = false;
      return await f();
    } finally {
      await wifi();
    }
  }
}
