import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Локальні сповіщення: тривоги про сигнали + постійне сповіщення фонового сервісу (Android).
class Notifications {
  static final plugin = FlutterLocalNotificationsPlugin();
  static const alertsChannel = 'sdr_alerts';
  static const serviceChannel = 'sdr_service';
  static const serviceNotificationId = 888;
  static bool _ready = false;

  static Future<void> init({bool requestPermission = false}) async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await plugin.initialize(settings: settings);
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          alertsChannel,
          'Знайдені сигнали',
          description: 'Відео FPV, канали керування та інші сигнали',
          importance: Importance.high,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          serviceChannel,
          'Фоновий моніторинг',
          description: 'Постійне сповіщення фонового сервісу',
          importance: Importance.low,
        ),
      );
      if (requestPermission) await android.requestNotificationsPermission();
    }
    if (requestPermission && Platform.isIOS) {
      await plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
    _ready = true;
  }

  static Future<void> alert(int id, String title, String body, {bool high = true, String? payload}) {
    return plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          alertsChannel,
          'Знайдені сигнали',
          importance: high ? Importance.high : Importance.defaultImportance,
          priority: high ? Priority.high : Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(body),
          category: AndroidNotificationCategory.alarm,
        ),
        iOS: const DarwinNotificationDetails(presentSound: true, interruptionLevel: InterruptionLevel.timeSensitive),
      ),
    );
  }

  static Future<void> serviceStatus(String text) {
    return plugin.show(
      id: serviceNotificationId,
      title: 'SDR Watch — моніторинг',
      body: text,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          serviceChannel,
          'Фоновий моніторинг',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          onlyAlertOnce: true,
          showWhen: false,
        ),
      ),
    );
  }
}
