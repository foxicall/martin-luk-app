import 'dart:async';

/// A wall-clock limit for a complete refresh, including storage and metadata.
/// A provider clock can remain fixed in tests, so network budgets deliberately
/// use [Stopwatch] rather than the timestamp supplied by a market API.
class LiveBatchDeadline {
  LiveBatchDeadline(Duration budget, {Duration reserve = Duration.zero})
      : _budget = budget, _reserve = reserve {
    if (budget <= Duration.zero) {
      throw ArgumentError.value(budget, 'budget', '更新期限必須大於零。');
    }
    if (reserve < Duration.zero || reserve >= budget) {
      throw ArgumentError.value(reserve, 'reserve', '快取預留時間必須小於整批期限。');
    }
    _watch.start();
  }

  final Stopwatch _watch = Stopwatch();
  Duration _budget;
  Duration _reserve;
  bool _open = true;
  final Completer<void> _sealed = Completer<void>();

  Duration get remaining {
    final value = _budget - _watch.elapsed;
    return value > Duration.zero ? value : Duration.zero;
  }

  Duration get _workRemaining {
    final value = remaining - _reserve;
    return value > Duration.zero ? value : Duration.zero;
  }

  bool get active => _open && _workRemaining > Duration.zero;
  bool get expired => remaining == Duration.zero;

  /// Switching to the short quote-refresh path retains the elapsed time from
  /// the initial cache read instead of granting a second, additive deadline.
  void capTo(Duration budget) {
    if (budget <= Duration.zero) throw ArgumentError.value(budget, 'budget');
    if (budget < _budget) {
      _budget = budget;
      if (_reserve > budget ~/ 10) _reserve = budget ~/ 10;
    }
  }

  Future<T> wait<T>(Future<T> operation, {Duration? maximum}) {
    if (!active) {
      // Dart evaluates the Future argument before entering this method. A
      // repository may have started it just as the budget expired; consume any
      // later failure so abandoning the batch never creates an unhandled error.
      unawaited(operation.then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
      return Future<T>.error(TimeoutException('本次更新已達整批期限。'));
    }
    final left = _workRemaining;
    final limit = maximum != null && maximum < left ? maximum : left;
    final result = Completer<T>();
    Timer? timer;
    void fail(Object error, StackTrace stack) {
      if (result.isCompleted) return;
      timer?.cancel();
      result.completeError(error, stack);
    }
    timer = Timer(limit, () => fail(
        TimeoutException('本次更新已達整批期限。'), StackTrace.current));
    unawaited(operation.then<void>((value) {
      if (result.isCompleted) return;
      timer?.cancel();
      result.complete(value);
    }, onError: fail));
    unawaited(_sealed.future.then<void>((_) => fail(
        TimeoutException('本次更新已取消。'), StackTrace.current)));
    return result.future;
  }

  /// Yield between complete stock chunks, while allowing disposal or the
  /// overall deadline to cancel both the pause and its Timer immediately.
  Future<void> pause(Duration interval) {
    if (interval < Duration.zero) throw ArgumentError.value(interval, 'interval');
    if (!active) return Future<void>.error(TimeoutException('本次更新已取消或逾時。'));
    if (interval == Duration.zero) return Future<void>.value();
    final ready = Completer<void>();
    final timer = Timer(interval, () { ready.complete(); });
    return wait(ready.future).whenComplete(() { timer.cancel(); });
  }

  /// Seal the run before publishing a snapshot. A timed-out, detached worker
  /// must check [active] after every await before starting another request or
  /// changing quotes, counters, snapshots, or persistent cache.
  void seal() {
    _open = false;
    // Keep measuring during synchronous ranking and the final best-effort
    // cache commit; sealing workers must not grant extra storage time.
    if (!_sealed.isCompleted) _sealed.complete();
  }
}
