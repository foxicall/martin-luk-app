import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android owns the running service; Dart owns only this platform adapter.
/// A paused service remains active and retains its notification/Flutter engine.
@immutable
class BackgroundScanState {
  const BackgroundScanState({
    required this.active,
    required this.paused,
    this.message,
  });

  static const inactive = BackgroundScanState(active: false, paused: false);

  final bool active;
  final bool paused;
  final String? message;

  bool get running => active && !paused;

  factory BackgroundScanState.fromMap(Object? value) {
    if (value is! Map ||
        value['active'] is! bool ||
        value['paused'] is! bool) {
      throw const FormatException('Android 背景掃描回傳的狀態格式無效。');
    }
    final active = value['active'] as bool;
    final paused = value['paused'] as bool;
    if (!active && paused) {
      throw const FormatException('已停止的背景掃描不能同時處於暫停狀態。');
    }
    final message = value['message'] ?? value['reason'];
    if (message != null && message is! String) {
      throw const FormatException('Android 背景掃描回傳的訊息格式無效。');
    }
    final text = (message as String?)?.trim();
    return BackgroundScanState(
      active: active,
      paused: paused,
      message: text == null || text.isEmpty ? null : text,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackgroundScanState &&
      other.active == active &&
      other.paused == paused &&
      other.message == message;

  @override
  int get hashCode => Object.hash(active, paused, message);
}

/// Injectable boundary for the Android foreground data-sync service.
///
/// Starting requires a visible Android activity and notification permission.
/// Native permission errors are propagated; the UI must explain them instead
/// of enabling a preference before the actual service has started.
abstract class BackgroundScanService {
  bool get supported;
  BackgroundScanState get state;
  Stream<BackgroundScanState> get states;

  Future<BackgroundScanState> synchronize();
  Future<BackgroundScanState> start();
  Future<BackgroundScanState> stop();
  Future<BackgroundScanState> pause();
  Future<BackgroundScanState> resume();

  Future<void> update({
    required String title,
    required String text,
    String? market,
    int? attempted,
    int? total,
    int? evaluated,
    int? remaining,
  });

  /// Detaches listeners and rejects pending calls without stopping Android.
  /// Call [stop] explicitly when the user chooses to end background scanning.
  void dispose();
}

class MethodChannelBackgroundScanService implements BackgroundScanService {
  /// Native registration is lazy so ordinary controller construction does not
  /// require a Flutter binding. Tests listening for unsolicited native events
  /// may opt into [attachImmediately] after initializing their test binding.
  MethodChannelBackgroundScanService({
    MethodChannel? channel,
    bool? supportedOverride,
    bool attachImmediately = false,
    this.timeout = const Duration(seconds: 8),
    this.startTimeout = defaultStartTimeout,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _supported = supportedOverride ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 8)) {
      throw ArgumentError.value(timeout, 'timeout', '背景服務逾時須為 0 至 8 秒。');
    }
    if (startTimeout <= Duration.zero || startTimeout > defaultStartTimeout) {
      throw ArgumentError.value(
          startTimeout, 'startTimeout', '通知授權與啟動逾時須為 0 至 60 秒。');
    }
    if (_supported && attachImmediately) _ensureAttached();
  }

  static const channelName = 'martin_luk/background_scan';
  // The initial start can include a human answering Android's permission
  // dialog (native: 45 seconds), Activity resumption (5 seconds), and the
  // actual service start (7 seconds). Network/status operations never use this
  // longer allowance; their deadline remains at most eight seconds.
  static const defaultStartTimeout = Duration(seconds: 60);
  static final Map<String, MethodChannelBackgroundScanService> _owners = {};

  final MethodChannel _channel;
  final bool _supported;
  final Duration timeout;
  final Duration startTimeout;
  final StreamController<BackgroundScanState> _states =
      StreamController<BackgroundScanState>.broadcast();
  final Set<Completer<void>> _pending = {};
  BackgroundScanState _state = BackgroundScanState.inactive;
  bool _disposed = false;
  bool _superseded = false;
  bool _attached = false;
  int _generation = 0;
  int _stateRevision = 0;

  @override
  bool get supported => _supported;

  @override
  BackgroundScanState get state => _state;

  @override
  Stream<BackgroundScanState> get states => _states.stream;

  void _checkUsable() {
    if (_disposed) throw StateError('背景掃描連線已關閉。');
    if (_superseded) throw StateError('背景掃描連線已由新的畫面接管。');
  }

  void _ensureAttached() {
    _checkUsable();
    if (_attached) return;
    // Installing a channel handler needs ServicesBinding. Plain controller
    // construction, unsupported clients and disposal must remain usable in
    // non-widget tests without initializing any Flutter binding. Ownership is
    // claimed only when this adapter actually performs native work.
    _channel.setMethodCallHandler(_onNativeCall);
    _owners[_channel.name]?._supersede();
    _owners[_channel.name] = this;
    _attached = true;
  }

  Future<Object?> _invoke(String method, [Map<String, Object>? args]) async {
    _checkUsable();
    if (!_supported) throw UnsupportedError('背景掃描服務僅支援 Android。');
    _ensureAttached();
    final cancellation = Completer<void>();
    _pending.add(cancellation);
    final deadline = method == 'start' ? startTimeout : timeout;
    try {
      final result = await Future.any<Object?>([
        _channel.invokeMethod<Object?>(method, args),
        cancellation.future.then<Object?>((_) =>
            throw StateError('背景掃描連線已關閉或由新的畫面接管。')),
      ]).timeout(
        deadline,
        onTimeout: () => throw TimeoutException(
          'Android 背景掃描服務未於 ${deadline.inSeconds} 秒內回應，請重試。',
          deadline,
        ),
      );
      _checkUsable();
      return result;
    } finally {
      _pending.remove(cancellation);
    }
  }

  Future<BackgroundScanState> _changeState(String method) async {
    _checkUsable();
    final generation = ++_generation;
    final revision = _stateRevision;
    final response = await _invoke(method);
    // A notification action/newer command is authoritative. A late status or
    // start response must never revive a service that has since been stopped.
    if (generation != _generation || revision != _stateRevision) return _state;
    _acceptState(BackgroundScanState.fromMap(response));
    return _state;
  }

  void _acceptState(BackgroundScanState value) {
    _checkUsable();
    _stateRevision++;
    if (value == _state) return;
    _state = value;
    _states.add(value);
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (_disposed || _superseded || call.method != 'stateChanged') return null;
    try {
      _acceptState(BackgroundScanState.fromMap(call.arguments));
    } on FormatException catch (error) {
      // Reject malformed native events without crashing the Dart engine or
      // replacing a known state with an invented active/inactive value.
      debugPrint('[BackgroundScan] 無法讀取 Android 狀態：$error');
    }
    return null;
  }

  @override
  Future<BackgroundScanState> synchronize() async {
    _checkUsable();
    if (!_supported) return _state;
    return _changeState('status');
  }

  @override
  Future<BackgroundScanState> start() => _changeState('start');

  @override
  Future<BackgroundScanState> stop() => _changeState('stop');

  @override
  Future<BackgroundScanState> pause() => _changeState('pause');

  @override
  Future<BackgroundScanState> resume() => _changeState('resume');

  @override
  Future<void> update({
    required String title,
    required String text,
    String? market,
    int? attempted,
    int? total,
    int? evaluated,
    int? remaining,
  }) async {
    if (title.trim().isEmpty || text.trim().isEmpty) {
      throw ArgumentError('背景掃描通知標題與內容不得為空。');
    }
    for (final count in [attempted, total, evaluated, remaining]) {
      if (count != null && count < 0) {
        throw ArgumentError('背景掃描進度不得為負數。');
      }
    }
    await _invoke('update', {
      'title': title,
      'text': text,
      if (market != null) 'market': market,
      if (attempted != null) 'attempted': attempted,
      if (total != null) 'total': total,
      if (evaluated != null) 'evaluated': evaluated,
      if (remaining != null) 'remaining': remaining,
    });
  }

  void _cancelPending() {
    _generation++;
    for (final pending in _pending) {
      if (!pending.isCompleted) pending.complete();
    }
    _pending.clear();
  }

  void _supersede() {
    _superseded = true;
    _cancelPending();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelPending();
    if (identical(_owners[_channel.name], this)) {
      _owners.remove(_channel.name);
      _channel.setMethodCallHandler(null);
    }
    unawaited(_states.close());
  }
}
