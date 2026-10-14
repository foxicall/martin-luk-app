import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

/// 期限涵蓋排隊、連線、回應標頭及完整本文。
/// 逾時會中止請求；finally 確保釋放並行名額。
class NetworkRequest {
  NetworkRequest({
    http.Client? client,
    this.timeout = defaultTimeout,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null {
    validateTimeout(timeout);
  }

  static const defaultTimeout = Duration(seconds: 8);
  static const maximumTimeout = Duration(seconds: 10);
  static const storageTimeout = Duration(seconds: 5);

  // 一般本機快取維持較短期限；需要時可明確指定至 5 秒。
  static const defaultStorageTimeout = Duration(seconds: 2);
  static const maximumConcurrentRequests = 5;

  static const Map<String, String> requestHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  static final _permits =
      _HttpPermitPool(maximumConcurrentRequests);

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  final Map<String, String> defaultHeaders = requestHeaders;
  final Set<_PendingRequest> _active = {};
  bool _closed = false;

  static void validateTimeout(Duration value) {
    if (value <= Duration.zero || value > maximumTimeout) {
      throw ArgumentError.value(
        value,
        'requestTimeout',
        'HTTP 逾時必須大於零且不得超過 10 秒。',
      );
    }
  }

  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    if (_closed) {
      throw StateError('網路服務已關閉。');
    }

    final deadline = timeout ?? this.timeout;
    validateTimeout(deadline);

    final pending = _PendingRequest(_permits.acquire());
    _active.add(pending);
    var succeeded = false;

    try {
      final response = await Future.any<http.Response>([
        _sendWhenPermitted(uri, headers ?? const {}, pending),
        pending.abort.future.then<http.Response>(
          (_) => throw http.RequestAbortedException(uri),
        ),
      ]).timeout(
        deadline,
        onTimeout: () {
          pending.cancel();
          throw TimeoutException('HTTP 請求超過期限。', deadline);
        },
      );

      if (_closed) {
        throw StateError('網路服務已關閉。');
      }

      succeeded = true;
      return response;
    } finally {
      _active.remove(pending);

      if (!succeeded) {
        pending.cancel();
      }

      pending.permit.release();
    }
  }

  Future<http.Response> _sendWhenPermitted(
    Uri uri,
    Map<String, String> headers,
    _PendingRequest pending,
  ) async {
    await pending.permit.ready;

    if (_closed ||
        pending.abort.isCompleted ||
        !pending.permit.isActive) {
      throw http.RequestAbortedException(uri);
    }

    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: pending.abort.future,
    );

    request.headers.addAll(headers);

    // 強制保留標準瀏覽器標頭，也保留其他自訂標頭。
    request.headers.addAll(requestHeaders);

    final streamedResponse = await _client.send(request);
    return http.Response.fromStream(streamedResponse);
  }

  void close() {
    if (_closed) return;
    _closed = true;

    for (final pending in _active) {
      pending.cancel();
    }
    _active.clear();

    // 注入的 Client 由呼叫者負責關閉。
    if (_ownsClient) {
      _client.close();
    }
  }
}

class _PendingRequest {
  _PendingRequest(this.permit);

  final _HttpPermit permit;
  final abort = Completer<void>();

  void cancel() {
    if (!abort.isCompleted) {
      abort.complete();
    }
    permit.release();
  }
}

/// 同一 Dart isolate 中的所有實例共用 FIFO 名額池。
class _HttpPermitPool {
  _HttpPermitPool(this.limit);

  final int limit;
  int _used = 0;
  final Queue<_HttpPermit> _queue = Queue<_HttpPermit>();

  _HttpPermit acquire() {
    final permit = _HttpPermit(this);
    _queue.addLast(permit);
    _drain();
    return permit;
  }

  void _release(_HttpPermit permit) {
    if (permit._released) return;
    permit._released = true;

    if (permit._granted) {
      _used--;
    } else {
      _queue.remove(permit);
    }

    // 被取消的排隊請求也必須醒來並結束。
    if (!permit._ready.isCompleted) {
      permit._ready.complete();
    }

    _drain();
  }

  void _drain() {
    while (_used < limit && _queue.isNotEmpty) {
      final permit = _queue.removeFirst();
      if (permit._released) continue;

      permit._granted = true;
      _used++;
      permit._ready.complete();
    }
  }
}

class _HttpPermit {
  _HttpPermit(this._pool);

  final _HttpPermitPool _pool;
  final _ready = Completer<void>();

  bool _granted = false;
  bool _released = false;

  Future<void> get ready => _ready.future;
  bool get isActive => _granted && !_released;

  void release() => _pool._release(this);
}
