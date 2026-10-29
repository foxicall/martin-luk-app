import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/services/background_scan_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MethodChannelBackgroundScanService.channelName);
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  final adapters = <MethodChannelBackgroundScanService>[];
  Map<String, Object?> nativeState = {'active': false, 'paused': false};

  MethodChannelBackgroundScanService create({
    bool? supportedOverride = true,
    Duration timeout = const Duration(seconds: 8),
    Duration startTimeout = MethodChannelBackgroundScanService.defaultStartTimeout,
  }) {
    final service = MethodChannelBackgroundScanService(
      channel: channel,
      supportedOverride: supportedOverride,
      attachImmediately: true,
      timeout: timeout,
      startTimeout: startTimeout,
    );
    adapters.add(service);
    return service;
  }

  void handle(Future<Object?> Function(MethodCall) callback) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return callback(call);
    });
  }

  Future<void> emit(Object? arguments, {String method = 'stateChanged'}) async {
    final completed = Completer<void>();
    // This is the actual platform-to-Dart direction. A mock outbound method
    // handler alone would not test notification action callbacks.
    ui.channelBuffers.push(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  setUp(() {
    calls.clear();
    adapters.clear();
    nativeState = {'active': false, 'paused': false};
    handle((call) async {
      switch (call.method) {
        case 'start':
        case 'resume':
          nativeState = {'active': true, 'paused': false};
          break;
        case 'pause':
          nativeState = {'active': true, 'paused': true};
          break;
        case 'stop':
          nativeState = {'active': false, 'paused': false};
          break;
      }
      return nativeState;
    });
  });

  tearDown(() {
    for (final service in adapters) {
      service.dispose();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('state parser requires booleans and coherent active/paused values', () {
    for (final value in <Object?>[
      null,
      false,
      {'active': true},
      {'active': 'true', 'paused': false},
      {'active': false, 'paused': true},
      {'active': true, 'paused': false, 'message': 10},
    ]) {
      expect(() => BackgroundScanState.fromMap(value), throwsFormatException);
    }
    expect(
      BackgroundScanState.fromMap({
        'active': true,
        'paused': false,
        'reason': '  繼續掃描  ',
      }),
      const BackgroundScanState(
        active: true,
        paused: false,
        message: '繼續掃描',
      ),
    );
    expect(
      BackgroundScanState.fromMap({
        'active': false,
        'paused': false,
        'message': ' ',
      }),
      BackgroundScanState.inactive,
    );
  });

  test('commands synchronize actual Android state and use matching methods',
      () async {
    final service = create();
    expect(service.state, BackgroundScanState.inactive);
    expect(await service.synchronize(), BackgroundScanState.inactive);
    expect((await service.start()).running, isTrue);
    expect((await service.pause()).paused, isTrue);
    expect((await service.resume()).running, isTrue);
    expect(await service.stop(), BackgroundScanState.inactive);
    expect(
      calls.map((call) => call.method),
      ['status', 'start', 'pause', 'resume', 'stop'],
    );
  });

  test('notification callback changes state and malformed events are ignored',
      () async {
    final service = create();
    final changes = <BackgroundScanState>[];
    final subscription = service.states.listen(changes.add);
    addTearDown(subscription.cancel);
    await emit({'active': true, 'paused': false});
    await emit({'active': true, 'paused': true, 'message': '通知已暫停'});
    await emit({'active': true, 'paused': 'wrong'});
    await emit({'active': false, 'paused': false}, method: 'unknownEvent');
    expect(service.state.active, isTrue);
    expect(service.state.paused, isTrue);
    expect(service.state.message, '通知已暫停');
    expect(changes, hasLength(2));
    await emit({'active': false, 'paused': false});
    expect(service.state, BackgroundScanState.inactive);
    expect(changes, hasLength(3));
    expect(calls, isEmpty);
  });

  test('notification progress passes complete counters without command churn',
      () async {
    final service = create();
    await service.update(
      title: '台股輪掃',
      text: '已嘗試 60/1979 檔',
      market: 'tw',
      attempted: 60,
      total: 1979,
      evaluated: 58,
      remaining: 1919,
    );
    expect(calls, hasLength(1));
    expect(calls.single.method, 'update');
    expect(calls.single.arguments, {
      'title': '台股輪掃',
      'text': '已嘗試 60/1979 檔',
      'market': 'tw',
      'attempted': 60,
      'total': 1979,
      'evaluated': 58,
      'remaining': 1919,
    });
    expect(service.state, BackgroundScanState.inactive);
    await expectLater(
      service.update(title: ' ', text: 'invalid'),
      throwsArgumentError,
    );
    await expectLater(
      service.update(title: 'scan', text: 'invalid', attempted: -1),
      throwsArgumentError,
    );
    expect(calls, hasLength(1));
  });

  test('permission rejection propagates and never enables the service',
      () async {
    handle((_) async => throw PlatformException(
          code: 'NOTIFICATION_PERMISSION_REQUIRED',
          message: '請允許背景掃描通知。',
        ));
    final service = create();
    await expectLater(
      service.start(),
      throwsA(isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'NOTIFICATION_PERMISSION_REQUIRED',
      )),
    );
    expect(service.state, BackgroundScanState.inactive);
    handle((_) async => {'active': true, 'paused': false});
    expect((await service.start()).running, isTrue);
  });

  test('missing native implementation and malformed responses remain errors',
      () async {
    final service = create();
    handle((_) async => false);
    await expectLater(service.start(), throwsFormatException);
    expect(service.state.active, isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(service.start(), throwsA(isA<MissingPluginException>()));
    expect(service.state.active, isFalse);
  });

  testWidgets('a hung status call has an eight second deadline and can retry',
      (tester) async {
    final pending = Completer<Object?>();
    handle((_) => pending.future);
    final service = create();
    final failure = expectLater(
      service.synchronize(),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(const Duration(seconds: 8));
    await failure;
    expect(service.state.active, isFalse);
    // Even if a platform status future replies late, Dart must not publish it.
    pending.complete({'active': true, 'paused': false});
    await tester.pump();
    expect(service.state.active, isFalse);
    handle((_) async => {'active': true, 'paused': false});
    expect((await service.start()).running, isTrue);
  });

  testWidgets('start allows user permission time beyond the status deadline',
      (tester) async {
    final pending = Completer<Object?>();
    handle((_) => pending.future);
    final service = create(
      timeout: const Duration(milliseconds: 10),
      startTimeout: const Duration(milliseconds: 80),
    );
    var settled = false;
    final request = service.start().then((value) {
      settled = true;
      return value;
    });
    await tester.pump(const Duration(milliseconds: 40));
    expect(settled, isFalse);
    pending.complete({'active': true, 'paused': false});
    await tester.pump();
    expect((await request).running, isTrue);
  });

  testWidgets('permission/start waiting also has a finite overall deadline',
      (tester) async {
    final pending = Completer<Object?>();
    handle((_) => pending.future);
    final service = create(startTimeout: const Duration(milliseconds: 80));
    final failure = expectLater(
      service.start(),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await failure;
    pending.complete({'active': true, 'paused': false});
    await tester.pump();
    expect(service.state.active, isFalse);
  });

  test('a late status reply cannot overwrite a newer notification action',
      () async {
    final pending = Completer<Object?>();
    handle((_) => pending.future);
    final service = create();
    final request = service.synchronize();
    await emit({'active': true, 'paused': true});
    pending.complete({'active': true, 'paused': false});
    final result = await request;
    expect(result.paused, isTrue);
    expect(service.state.paused, isTrue);
  });

  test('a late start reply cannot revive a subsequently stopped service',
      () async {
    final pending = Completer<Object?>();
    handle((call) async {
      if (call.method == 'start') return pending.future;
      return {'active': false, 'paused': false};
    });
    final service = create();
    final start = service.start();
    expect(await service.stop(), BackgroundScanState.inactive);
    pending.complete({'active': true, 'paused': false});
    expect(await start, BackgroundScanState.inactive);
    expect(service.state.active, isFalse);
  });

  testWidgets('dispose rejects pending work and cancels its timeout timer',
      (tester) async {
    final pending = Completer<Object?>();
    handle((_) => pending.future);
    final service = create();
    final failure = expectLater(service.start(), throwsStateError);
    service.dispose();
    await tester.pump();
    await failure;
    pending.complete({'active': true, 'paused': false});
    await tester.pump();
    expect(service.state, BackgroundScanState.inactive);
    expect(calls.where((call) => call.method == 'stop'), isEmpty);
    await expectLater(service.synchronize(), throwsStateError);
    await expectLater(service.stop(), throwsStateError);
    service.dispose();
  });

  test('disposing an old adapter preserves the replacement event handler',
      () async {
    final pending = Completer<Object?>();
    handle((_) => pending.future);
    final old = create();
    final oldFailure = expectLater(old.synchronize(), throwsStateError);
    final replacement = create();
    await oldFailure;
    old.dispose();
    await emit({'active': true, 'paused': true});
    expect(replacement.state.paused, isTrue);
    expect(old.state, BackgroundScanState.inactive);
    pending.complete({'active': true, 'paused': false});
    await Future<void>.delayed(Duration.zero);
    expect(replacement.state.paused, isTrue);
  });

  test('an unused lazy adapter cannot take or erase a running owner', () async {
    final owner = create();
    final unused = MethodChannelBackgroundScanService(
      channel: channel,
      supportedOverride: true,
    );
    adapters.add(unused);
    await emit({'active': true, 'paused': false});
    expect(owner.state.running, isTrue);
    expect(unused.state, BackgroundScanState.inactive);
    unused.dispose();
    await emit({'active': true, 'paused': true});
    expect(owner.state.paused, isTrue);
  });

  test('a lazy adapter claims ownership on its first native operation',
      () async {
    final old = create();
    final replacement = MethodChannelBackgroundScanService(
      channel: channel,
      supportedOverride: true,
    );
    adapters.add(replacement);
    nativeState = {'active': true, 'paused': false};
    expect((await replacement.synchronize()).running, isTrue);
    await expectLater(old.synchronize(), throwsStateError);
    old.dispose();
    await emit({'active': true, 'paused': true});
    expect(replacement.state.paused, isTrue);
  });

  test('unsupported platforms never invoke Android and stay inactive', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final service = create(supportedOverride: null);
    expect(service.supported, isFalse);
    expect(await service.synchronize(), BackgroundScanState.inactive);
    for (final action in [
      service.start,
      service.stop,
      service.pause,
      service.resume,
    ]) {
      await expectLater(action(), throwsUnsupportedError);
    }
    await expectLater(
      service.update(title: 'scan', text: 'progress'),
      throwsUnsupportedError,
    );
    expect(calls, isEmpty);
  });

  test('deadline configuration must remain positive and at most eight seconds',
      () {
    for (final value in [
      Duration.zero,
      const Duration(seconds: -1),
      const Duration(seconds: 9),
    ]) {
      expect(() => create(timeout: value), throwsArgumentError);
    }
    for (final value in [
      Duration.zero,
      const Duration(seconds: -1),
      const Duration(seconds: 61),
    ]) {
      expect(() => create(startTimeout: value), throwsArgumentError);
    }
  });
}
