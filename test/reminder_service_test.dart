import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/services/reminder_service.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];
  var permissionGranted = true;
  var initializationWorks = true;
  int? failScheduleAt;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    permissionGranted = true;
    initializationWorks = true;
    failScheduleAt = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return initializationWorks;
        case 'requestNotificationsPermission':
          return permissionGranted;
        case 'zonedSchedule':
          if (failScheduleAt != null &&
              calls.where((item) => item.method == 'zonedSchedule').length ==
                  failScheduleAt) {
            throw PlatformException(code: 'schedule_failed');
          }
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  List<Map<dynamic, dynamic>> scheduled() => calls
      .where((call) => call.method == 'zonedSchedule')
      .map((call) => call.arguments as Map<dynamic, dynamic>)
      .toList();

  tz.TZDateTime localDate(Map<dynamic, dynamic> arguments) {
    // The plugin supplies a local wall-clock ISO date plus an IANA time zone.
    // Strip an optional offset before reconstructing that local date; this
    // keeps the test compatible with equivalent plugin serialization formats.
    final text = (arguments['scheduledDateTime'] as String)
        .replaceFirst(RegExp(r'(Z|[+-]\d{2}:?\d{2})$'), '');
    final parsed = DateTime.parse(text);
    return tz.TZDateTime(
      tz.getLocation(arguments['timeZoneName'] as String),
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
    );
  }

  test('Registers exactly 20 unique weekday reminders in exchange time zones',
      () async {
    final service = ReminderService(now: () => DateTime.utc(2026, 3, 7, 12));
    expect(await service.setEnabled(true), isTrue);
    final reminders = scheduled();
    expect(reminders, hasLength(20));
    expect(reminders.map((item) => item['id']).toSet(), hasLength(20));
    expect(
      reminders.where((item) => item['timeZoneName'] == 'Asia/Taipei'),
      hasLength(10),
    );
    expect(
      reminders.where((item) => item['timeZoneName'] == 'America/New_York'),
      hasLength(10),
    );
    for (final reminder in reminders) {
      final date = localDate(reminder);
      expect(date.weekday, inInclusiveRange(DateTime.monday, DateTime.friday));
      expect(date.isAfter(DateTime.utc(2026, 3, 7, 12)), isTrue);
      expect(reminder['matchDateTimeComponents'],
          DateTimeComponents.dayOfWeekAndTime.index);
    }
  });

  for (final scenario in [
    (clock: DateTime.utc(2026, 3, 1, 12), monday: 2, utcHour: 13),
    (clock: DateTime.utc(2026, 3, 7, 12), monday: 9, utcHour: 12),
  ]) {
    test('US 08:45 keeps exchange time across DST on March ${scenario.monday}',
        () async {
      final service = ReminderService(now: () => scenario.clock);
      await service.setEnabled(true);
      final monday = localDate(
        scheduled().singleWhere((item) => item['id'] == 1021),
      );
      expect(monday.day, scenario.monday);
      expect(monday.hour, 8);
      expect(monday.minute, 45);
      expect(monday.toUtc().hour, scenario.utcHour);
      expect(monday.toUtc().minute, 45);
    });
  }

  test('Denied permission returns false and registers no reminders', () async {
    permissionGranted = false;
    final service = ReminderService();
    expect(await service.setEnabled(true), isFalse);
    expect(scheduled(), isEmpty);
    expect(calls.where((call) => call.method == 'cancelAll'), hasLength(1));
  });

  test('Disabling cancels notifications without requesting permission',
      () async {
    final service = ReminderService();
    expect(await service.setEnabled(false), isTrue);
    expect(calls.where((call) => call.method == 'cancelAll'), hasLength(1));
    expect(
      calls.where((call) => call.method == 'requestNotificationsPermission'),
      isEmpty,
    );
  });

  test('Failed initialization is retried rather than cached forever', () async {
    final service = ReminderService();
    initializationWorks = false;
    await expectLater(service.initialize(), throwsStateError);
    initializationWorks = true;
    await service.initialize();
    await service.initialize();
    expect(calls.where((call) => call.method == 'initialize'), hasLength(2));
  });

  test('A registration failure cancels partially registered reminders',
      () async {
    failScheduleAt = 4;
    final service = ReminderService();
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<PlatformException>()),
    );
    expect(scheduled(), hasLength(4));
    expect(calls.where((call) => call.method == 'cancelAll'), hasLength(2));
    expect(calls.last.method, 'cancelAll');
  });

  test('Unsupported platforms report reminders unavailable without channels',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final service = ReminderService();
    await service.initialize();
    expect(await service.setEnabled(true), isFalse);
    expect(await service.setEnabled(false), isTrue);
    expect(calls, isEmpty);
  });
}
