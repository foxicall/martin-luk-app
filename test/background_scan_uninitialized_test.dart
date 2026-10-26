import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/services/background_scan_service.dart';

// Deliberately do not initialize TestWidgetsFlutterBinding in this file.
// These plain model/controller tests must not need a platform messenger merely
// because Android supports an optional foreground service.
void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('default Android adapter constructs and disposes without a binding',
      () async {
    final service = MethodChannelBackgroundScanService();
    final values = <BackgroundScanState>[];
    final subscription = service.states.listen(values.add);
    final closed = subscription.asFuture<void>();
    expect(service.supported, isTrue);
    expect(service.state, BackgroundScanState.inactive);
    service.dispose();
    service.dispose();
    await closed;
    expect(values, isEmpty);
  });

  test('default AppController constructs and disposes without a binding', () {
    final controller = AppController(forceMockPreview: false);
    expect(controller.backgroundScanSupported, isTrue);
    expect(controller.backgroundScanActive, isFalse);
    expect(controller.backgroundScanBusy, isFalse);
    controller.dispose();
  });
}
