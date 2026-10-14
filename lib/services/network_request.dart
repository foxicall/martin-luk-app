import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

/// Deadline includes permit queueing, headers and the full response body.
/// Closing this wrapper does not close an injected, caller-owned client.
class NetworkRequest {
  NetworkRequest({
    http.Client? client,
    this.timeout = maximumTimeout,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    validateTimeout(timeout);
  }

  static const maximumTimeout = Duration(seconds: 8);
  static const storageTimeout = Duration(seconds: 2);
  static const maximumConcurrentRequests = 5;

  static final _permits = _HttpPermitPool(
    maximumConcurrentRequests,
  );

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Set<_PendingRequest> _active = {};

  bool _closed = false;

  static void validateTimeout(Duration value) {
    if (value <= Duration.zero || value > maximumTimeout) {
      throw ArgumentError.value(
        value,
        'requestTimeout',
        'HTTP 逾時必須大於零且不得超過 8 秒。',
      );
    }
  }

  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async {
    if (_closed) {
      throw StateError('網路服務已關閉。');
    }

    final deadline = timeout ?? this.timeout;
    validateTimeout(deadline);

    final pending = _PendingRequest(
      _permits.acquire(),
    );

    _active.add(pending);
    var succeeded = false;

    try {
      final response = await Future.any<http.Response>([
        _sendWhenPermitted(uri, headers, pending),
        pending.abort.future.then<http.Response>(
          (_) => throw http.RequestAbortedException(uri),
        ),
      ]).timeout(
        deadline,
        onTimeout: () {
          pending.cancel();
          throw TimeoutException(
            'HTTP 請求超過期限。',
            deadline,
          );
        },
      );

      if (_closed) {
        throw StateError('網路服務已關閉。');
      }

      succeeded = true;
      return response;
    } finally {
      _active.remove(pending);

      // Keep a successful pooled connection usable.
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

    return _client.send(request).then<http.Response>(
      http.Response.fromStream,
    );
  }

  void close() {
    if (_closed) {
      return;
    }

    _closed = true;

    for (final pending in _active) {
      pending.cancel();
    }

    _active.clear();

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

/// FIFO pool shared across NetworkRequest instances in the same isolate.
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
    if (permit._released) {
      return;
    }

    permit._released = true;

    if (permit._granted) {
      _used--;
    } else {
      _queue.remove(permit);
    }

    // Wake cancelled queue entries so their observed futures terminate.
    if (!permit._ready.isCompleted) {
      permit._ready.complete();
    }

    _drain();
  }

  void _drain() {
    while (_used < limit && _queue.isNotEmpty) {
      final permit = _queue.removeFirst();

      if (permit._released) {
        continue;
      }

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

  void release() {
    _pool._release(this);
  }
}
