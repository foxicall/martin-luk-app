import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

/// Schedules local Android reminders, never background financial scans.
///
/// The four market sessions repeat Monday through Friday in the exchange's
/// time zone. US daylight saving changes are handled by [tz.TZDateTime]. Public
/// holidays still need to be checked against the backend's trading calendar.
/// Android can delay inexact alarms under battery restrictions.
class ReminderService {
  ReminderService({
    FlutterLocalNotificationsPlugin? notifications,
    DateTime Function()? now,
  })  : _notifications =
            notifications ?? FlutterLocalNotificationsPlugin(),
        _now = now ?? DateTime.now;

  final FlutterLocalNotificationsPlugin _notifications;
  final DateTime Function() _now;
  bool _initialized = false;
  Future<void>? _initializing;

  bool get _supportsNotifications =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Initializes the plugin once; failures propagate to the controller so the
  /// application can explain them instead of pretending reminders are enabled.
  Future<void> initialize() async {
    if (_initialized) return;
    if (_initializing != null) {
      await _initializing;
      return;
    }
    _initializing = _initializePlugin();
    try {
      await _initializing;
      _initialized = true;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _initializePlugin() async {
    if (!_supportsNotifications) return;
    timezone_data.initializeTimeZones();
    const initialization = InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_momentum'),
    );
    final initialized = await _notifications.initialize(initialization);
    if (initialized != true) {
      throw StateError('Android 通知服務初始化失敗。');
    }
  }

  /// Returns false when Android notification permission was denied or the
  /// platform does not support these reminders. Disabled reminders are a
  /// successful no-op on unsupported platforms.
  ///
  /// A single registration error cancels the whole group, avoiding a partly
  /// enabled schedule. The caller can retain a false persisted preference.
  Future<bool> setEnabled(bool enabled) async {
    if (!_supportsNotifications) return !enabled;
    await initialize();
    if (!enabled) {
      await _notifications.cancelAll();
      return true;
    }

    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final allowed = await android?.requestNotificationsPermission();
    if (allowed != true) {
      await _notifications.cancelAll();
      return false;
    }

    await _notifications.cancelAll();
    try {
      final taipei = tz.getLocation('Asia/Taipei');
      final newYork = tz.getLocation('America/New_York');
      await _scheduleWeekdays(
        group: 0,
        location: taipei,
        hour: 8,
        minute: 30,
        title: '台股盤前評估提醒',
        body: '台北時間 08:30。開啟 App 更新台股候選清單；休市日無須評估。',
        market: 'tw',
      );
      await _scheduleWeekdays(
        group: 1,
        location: taipei,
        hour: 14,
        minute: 0,
        title: '台股盤後評估提醒',
        body: '台北時間 14:00。開啟 App 檢查台股動能與風險；休市日無須評估。',
        market: 'tw',
      );
      await _scheduleWeekdays(
        group: 2,
        location: newYork,
        hour: 8,
        minute: 45,
        title: '美股盤前評估提醒',
        body: '美東時間 08:45。開啟 App 更新美股三大交易所候選清單；休市日無須評估。',
        market: 'us',
      );
      await _scheduleWeekdays(
        group: 3,
        location: newYork,
        hour: 16,
        minute: 30,
        title: '美股盤後評估提醒',
        body: '美東時間 16:30。開啟 App 檢查美股動能與風險；休市日無須評估。',
        market: 'us',
      );
      return true;
    } catch (_) {
      await _notifications.cancelAll();
      rethrow;
    }
  }

  Future<void> _scheduleWeekdays({
    required int group,
    required tz.Location location,
    required int hour,
    required int minute,
    required String title,
    required String body,
    required String market,
  }) async {
    const notification = NotificationDetails(
      android: AndroidNotificationDetails(
        'market_evaluation_reminders',
        '市場評估提醒',
        channelDescription: '台股與美股盤前、盤後的本機提醒。',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: 'ic_stat_momentum',
      ),
    );
    for (var weekday = DateTime.monday;
        weekday <= DateTime.friday;
        weekday++) {
      await _notifications.zonedSchedule(
        1000 + group * 10 + weekday,
        title,
        body,
        _nextOccurrence(location, weekday, hour, minute),
        notification,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: market,
      );
    }
  }

  tz.TZDateTime _nextOccurrence(
    tz.Location location,
    int weekday,
    int hour,
    int minute,
  ) {
    final now = tz.TZDateTime.from(_now(), location);
    var scheduled =
        tz.TZDateTime(location, now.year, now.month, now.day, hour, minute);
    while (scheduled.weekday != weekday || !scheduled.isAfter(now)) {
      // Reconstruct local wall-clock time; adding 24 hours across US daylight
      // saving changes would shift a reminder by an hour.
      scheduled = tz.TZDateTime(location, scheduled.year, scheduled.month,
          scheduled.day + 1, hour, minute);
    }
    return scheduled;
  }

  /// Timers are owned by Android, so closing the UI retains enabled reminders.
  void dispose() {}
}
