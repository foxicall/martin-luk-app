import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

/// A deadline covers permit queueing, response headers and the complete body.
/// Per-request abortion prevents a timed-out socket from consuming a connection
/// indefinitely. Closing this wrapper never closes a caller-owned HTTP client.
/// All instances share five permits, including simultaneous scan/holding polls.
class NetworkRequest {
  NetworkRequest({
    http.Client? client,
    this.timeout = defaultTimeout,
    String acceptedContentTypes = 'application/json',
  }) : _acceptedContentTypes = _validateAcceptedContentTypes(acceptedContentTypes),
       _client = client ?? http.Client(),
       _ownsClient = client == null {
    validateTimeout(timeout);
  }

  static const defaultTimeout = Duration(seconds: 8);
  static const maximumTimeout = Duration(seconds: 10);
  static const storageTimeout = Duration(seconds: 5);
  static const defaultStorageTimeout = Duration(seconds: 2);
  static const maximumConcurrentRequests = 5;
  static const Map<String, String> requestHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
  };
  static final _permits = _HttpPermitPool(maximumConcurrentRequests);

  final http.Client _client;
  final bool _ownsClient;
  final String _acceptedContentTypes;
  final Duration timeout;
  /// The actual enforced headers, including this service's response formats.
  Map<String, String> get defaultHeaders => Map<String, String>.unmodifiable({
    ...requestHeaders,
    'Accept': _acceptedContentTypes,
  });
  final Set<_PendingRequest> _active = {};
  bool _closed = false;

  static void validateTimeout(Duration value) {
    if (value <= Duration.zero || value > maximumTimeout) {
      throw ArgumentError.value(value, 'requestTimeout',
          'HTTP 逾時必須大於零且不得超過 10 秒。');
    }
  }

  static String _validateAcceptedContentTypes(String value) {
    if (value.trim().isEmpty || value.contains('\r') || value.contains('\n')) {
      throw ArgumentError.value(value, 'acceptedContentTypes',
          'Accept 標頭不得為空或包含換行字元。');
    }
    return value.trim();
  }

  Future<http.Response> get(Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    if (_closed) throw StateError('網路服務已關閉。');
    final deadline = timeout ?? this.timeout;
    validateTimeout(deadline);
    final pending = _PendingRequest(_permits.acquire());
    _active.add(pending);
    var succeeded = false;
    try {
      // Attach handlers before waiting for a permit: cancelling an enqueued
      // request must settle immediately and must never send it later. One
      // deadline covers queueing and the entire streamed response body.
      final response = await Future.any<http.Response>([
        _sendWhenPermitted(uri, headers ?? const {}, pending),
        pending.abort.future.then<http.Response>((_) =>
            throw http.RequestAbortedException(uri)),
      ])
          .timeout(deadline, onTimeout: () {
            pending.cancel();
            throw TimeoutException('HTTP 請求超過期限。', deadline);
          });
      if (_closed) throw StateError('網路服務已關閉。');
      succeeded = true;
      return response;
    } finally {
      _active.remove(pending);
      // A normal completed response must keep its pooled connection usable.
      // Only an incomplete/failed request needs a cancellation signal.
      if (!succeeded) pending.cancel();
      pending.permit.release();
    }
  }

  Future<http.Response> _sendWhenPermitted(Uri uri,
      Map<String, String> headers, _PendingRequest pending) async {
    await pending.permit.ready;
    if (_closed || pending.abort.isCompleted || !pending.permit.isActive) {
      throw http.RequestAbortedException(uri);
    }
    final request = http.AbortableRequest('GET', uri,
        abortTrigger: pending.abort.future);
    request.headers.addAll(headers);
    // Standard headers cannot be lost on retries or individual service calls.
    request.headers.addAll(requestHeaders);
    // A service may explicitly negotiate plain text; per-call headers cannot
    // override that choice or weaken the browser User-Agent/language defaults.
    request.headers['Accept'] = _acceptedContentTypes;
    return _client.send(request)
        .then<http.Response>(http.Response.fromStream);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final pending in _active) { pending.cancel(); }
    _active.clear();
    if (_ownsClient) _client.close();
  }
}

class _PendingRequest {
  _PendingRequest(this.permit);
  final _HttpPermit permit;
  final abort = Completer<void>();

  void cancel() {
    if (!abort.isCompleted) abort.complete();
    // Remove queued work immediately; already granted work first receives its
    // abort signal. Idempotent release also makes timeout/finally/close races safe.
    permit.release();
  }
}

/// FIFO permits are scoped to one Dart isolate, shared by every HTTP wrapper.
/// No permit is retained by a cancelled queue entry or a failed body stream.
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
    // Wake cancelled waiters so their observed future can exit without HTTP.
    if (!permit._ready.isCompleted) permit._ready.complete();
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
