import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'i18n.dart';

/// Where one permission stands. The gate draws from this and nothing else.
enum Access {
  /// Never asked, or asked and refused once. Asking again still works.
  ask,

  /// The motari said yes.
  granted,

  /// Refused for good: only the system settings screen can undo it.
  blocked,

  /// Granted to the app, but switched off for the whole phone. Location only.
  serviceOff,
}

extension AccessLabel on Access {
  String get label => switch (this) {
        Access.granted => t('gate.allowed'),
        Access.blocked => t('gate.blocked'),
        Access.serviceOff => t('gate.service_off'),
        Access.ask => t('gate.not_allowed'),
      };

  bool get ok => this == Access.granted;
}

/// What this phone lets Motari do: find the motari, reach them when the app is
/// behind another one, and ring out loud. Location is the one that decides
/// whether the app can work at all; the other two make it better.
class Permissions {
  static final _notifications = FlutterLocalNotificationsPlugin();
  static bool _notificationsReady = false;

  /* ── location ─────────────────────────────────────────────────────────── */

  static Future<Access> locationStatus() async {
    if (!await Geolocator.isLocationServiceEnabled()) return Access.serviceOff;
    return _fromLocation(await Geolocator.checkPermission());
  }

  /// Ask for location. Returns where things stand afterwards, so the caller
  /// never has to guess what the system dialog decided.
  static Future<Access> requestLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return Access.serviceOff;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return _fromLocation(permission);
  }

  static Access _fromLocation(LocationPermission p) => switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => Access.granted,
        LocationPermission.deniedForever => Access.blocked,
        _ => Access.ask,
      };

  /// The phone's own location switch, not the app's permission.
  static Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  /* ── notifications ────────────────────────────────────────────────────── */

  static Future<Access> notificationStatus() async {
    final status = await Permission.notification.status;
    return _fromStatus(status);
  }

  static Future<Access> requestNotifications() async {
    await _prepareNotifications();
    final status = await Permission.notification.request();
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
    return _fromStatus(status);
  }

  static Future<Access> overlayStatus() async {
    try {
      final status = await Permission.systemAlertWindow.status;
      return _fromStatus(status);
    } catch (_) {
      return Access.granted;
    }
  }

  static Future<Access> requestOverlay() async {
    try {
      final status = await Permission.systemAlertWindow.request();
      return _fromStatus(status);
    } catch (_) {
      return Access.granted;
    }
  }

  static Access _fromStatus(PermissionStatus s) {
    if (s.isGranted || s.isLimited || s.isProvisional) return Access.granted;
    if (s.isPermanentlyDenied) return Access.blocked;
    return Access.ask;
  }

  /// The channel an offer arrives on. Android wants it to exist before the
  /// first notification, and wants it loud: this is a phone call, not a badge.
  static Future<void> _prepareNotifications() async {
    if (_notificationsReady) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _notifications.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );
    final android_ = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android_?.createNotificationChannel(AndroidNotificationChannel(
      _channelId,
      t('notify.channel'),
      description: t('notify.channel_why'),
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
    _notificationsReady = true;
  }

  static const _channelId = 'motari.offers';

  /// Put an offer on the lock screen. The in-app ring is still the main event;
  /// this is what reaches a motari whose phone is in their pocket.
  static Future<void> showOffer({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      await _prepareNotifications();
      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            t('notify.channel'),
            channelDescription: t('notify.channel_why'),
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call,
            fullScreenIntent: true,
            ongoing: true,
            autoCancel: false,
            visibility: NotificationVisibility.public,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
      );
    } catch (e) {
      // A phone that refuses to show it still rings in the app.
      debugPrint('[motari] notification failed: $e');
    }
  }

  /// The offer is answered or gone: take it off the lock screen.
  static Future<void> clearOffer(int id) async {
    try {
      await _notifications.cancel(id: id);
    } catch (_) {
      // Nothing to clear.
    }
  }

  /// Show an immediate high-priority push/local notification for ride events
  /// (Bell ring, 400m ride started, Payment required / Cash declined, Ride finished).
  static Future<void> showAlertNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      await _prepareNotifications();
      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            t('notify.channel'),
            channelDescription: t('notify.channel_why'),
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            visibility: NotificationVisibility.public,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[motari] alert notification failed: $e');
    }
  }
}

/// Opening the phone's settings page for this app, kept apart from the class
/// so the name does not collide with permission_handler's own function.
Future<void> openPhoneSettings() => openAppSettings();
