# 完整覆蓋原始碼與真實行情健康門禁

2026-10-15，使用者已選擇「驗證真實行情與計算正確即可建置，允許推薦為零」。這取代先前至少一檔推薦才建置的規則；ADR、EMA、突破、停損與 0.5% 風控條件保持不變，沒有訊號不會建立買進建議。

請將覆蓋包的 `.github/`、`lib/`、`test/`、`scripts/` 合併到現有含 `pubspec.yaml` 的專案根目錄，覆蓋同名完整檔案。GitHub 分支為 `fix/refresh-live-gate-20261014`；需要一起提交工作流、整合測試、RS 引擎／資料模型和新增報告驗證器，僅換其中一檔不足以切換整套門禁。

CI 先執行 Python 驗證器測試及 Flutter RS／策略／風控單元測試，再以真 HTTP 驗證兩指數與必要五檔股票、獨立核對 ADR／EMA／RS，接著驗證 schema 2 報告，全部通過才建置 APK。`candidates: []` 可通過；必要資料缺漏、指標錯誤、逾時或失敗報告仍阻擋建置。只保留日誌與 APK 兩個 artifact。

本文件下列區塊是完整來源供手動複製；不需要補丁安裝器，也不執行舊版 apply_market_scan 腳本。本環境沒有 Flutter，尚未驗證這次 Dart 聯網測試或 APK 成功。

## lib/services/network_request.dart

```dart
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
  }) : _client = client ?? http.Client(),
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
  final Duration timeout;
  /// Immutable instance alias for callers that inspect the default headers.
  final Map<String, String> defaultHeaders = requestHeaders;
  final Set<_PendingRequest> _active = {};
  bool _closed = false;

  static void validateTimeout(Duration value) {
    if (value <= Duration.zero || value > maximumTimeout) {
      throw ArgumentError.value(value, 'requestTimeout',
          'HTTP 逾時必須大於零且不得超過 10 秒。');
    }
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
```

## .github/workflows/build_apk.yml

```yaml
name: Build Android APK with Verification Gate

'on':
  push:
    branches: [main, master, fix/refresh-live-gate-20261014]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  verify-and-build:
    runs-on: ubuntu-latest
    timeout-minutes: 45

    steps:
      - name: 檢出專案代碼
        uses: actions/checkout@v4

      - name: 定位專案目錄
        id: locate-project
        shell: bash
        run: |
          set -euo pipefail
          if [[ -f pubspec.yaml ]]; then
            PROJECT_DIR='.'
          elif [[ -f martin_luk_app/pubspec.yaml ]]; then
            PROJECT_DIR='martin_luk_app'
          else
            echo '::error::找不到 Flutter 專案的 pubspec.yaml'
            exit 1
          fi
          echo "project_dir=$PROJECT_DIR" >> "$GITHUB_OUTPUT"

      - name: 初始化驗證紀錄
        working-directory: ${{ steps.locate-project.outputs.project_dir }}
        run: |
          mkdir -p test_logs
          printf '%s\n' 'CI 開始；真實行情門禁尚未執行。' > test_logs/verification.log

      - name: 設定 Java 環境 (JDK 17)
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: 安裝 Flutter SDK (Stable)
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: 升級 Gradle Wrapper 至 8.14
        working-directory: ${{ steps.locate-project.outputs.project_dir }}
        shell: bash
        run: |
          set -euo pipefail
          WRAPPER_FILE='android/gradle/wrapper/gradle-wrapper.properties'
          if [[ ! -f "$WRAPPER_FILE" ]]; then
            echo '::error::缺少 gradle-wrapper.properties'
            exit 1
          fi
          if ! grep -Eq '^distributionUrl=.*gradle-8\.14-(all|bin)\.zip$' "$WRAPPER_FILE"; then
            if grep -Eq '^distributionSha256Sum=' "$WRAPPER_FILE"; then
              echo '::error::Wrapper 有 SHA256 校驗值，升級 Gradle 時須一併更新對應校驗值。'
              exit 1
            fi
            sed -i -E 's#(gradle-)[0-9.]+-(all|bin)\.zip#\18.14-\2.zip#' "$WRAPPER_FILE"
          fi
          grep -E '^distributionUrl=.*gradle-8\.14-(all|bin)\.zip$' "$WRAPPER_FILE" | tee -a test_logs/verification.log

      - name: 下載依賴套件
        working-directory: ${{ steps.locate-project.outputs.project_dir }}
        shell: bash
        run: |
          set -euo pipefail
          flutter pub get 2>&1 | tee -a test_logs/verification.log

      - name: 驗證風控、RS 與門禁報告規則
        working-directory: ${{ steps.locate-project.outputs.project_dir }}
        shell: bash
        run: |
          set -euo pipefail
          python3 -m unittest discover -s scripts/tests -p 'test_live_scan_evidence.py' -v 2>&1 | tee -a test_logs/verification.log
          flutter test test/rs_alignment_test.dart test/live_strategy_engine_test.dart test/live_risk_helpers_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded 2>&1 | tee -a test_logs/verification.log

      - name: 執行真實行情與指標門禁測試（允許零推薦）
        id: run-gate-test
        working-directory: ${{ steps.locate-project.outputs.project_dir }}
        shell: bash
        run: |
          set -euo pipefail
          if [[ ! -f test/integration_scan_test.dart ]]; then
            echo '::error::缺少 test/integration_scan_test.dart，請先提交測試檔。' | tee -a test_logs/verification.log
            exit 1
          fi
          mkdir -p build
          rm -f build/live-scan-evidence.json
          flutter test test/integration_scan_test.dart --dart-define=RUN_LIVE_SCAN_TEST=true --timeout=90s --dart-define=USE_MOCK_DATA=false --reporter=expanded 2>&1 | tee -a test_logs/verification.log
          python3 scripts/validate_live_scan_evidence.py build/live-scan-evidence.json 2>&1 | tee -a test_logs/verification.log

      - name: 保存實測紀錄
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: martin-luk-live-scan-evidence
          path: '**/test_logs/verification.log'
          if-no-files-found: warn
          retention-days: 7

      - name: 編譯正式版 Release APK
        if: ${{ success() && steps.run-gate-test.outcome == 'success' }}
        working-directory: ${{ steps.locate-project.outputs.project_dir }}
        run: flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation

      - name: 上傳 APK 成品
        uses: actions/upload-artifact@v4
        with:
          name: martin-luk-app-release
          path: '**/build/app/outputs/flutter-apk/*.apk'
          if-no-files-found: error
          retention-days: 7
```

## pubspec.yaml

```yaml
name: martin_luk_app
description: 台股與美股連網行情、客戶端動能掃描與嚴格風控 Android App。
publish_to: none
version: 1.3.0+4
environment:
  sdk: '>=3.7.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  http: ^1.5.0
  intl: ^0.20.2
  shared_preferences: ^2.5.2
  flutter_local_notifications: ^18.0.1
  timezone: ^0.10.0
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0
flutter:
  uses-material-design: true
  assets:
    - stocks_master.json
    - stocks_master_sources.json
  fonts:
    - family: MartinPreviewSans
      fonts:
        - asset: assets/fonts/MartinPreviewSans.otf
```

## lib/services/candidate_repository.dart

```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/stock_candidate.dart';
import 'network_request.dart';

class CandidateSnapshot {
  CandidateSnapshot({
    required List<StockCandidate> candidates,
    required this.fetchedAt,
    required List<String> warnings,
    required this.source,
    required this.universeCount,
    required this.stale,
    List<String> missingSymbols = const [],
    this.evaluatedCount,
    this.scanPoolSize,
    this.adrMatchCount,
    this.universeIsComplete = true,
    this.universeAsOf,
    this.scanCompletedAt,
    this.isFallback = false,
    this.attemptedAt,
  })  : candidates = List<StockCandidate>.unmodifiable(candidates),
        warnings = List<String>.unmodifiable(warnings),
        missingSymbols = List<String>.unmodifiable(missingSymbols);

  /// A diagnostic terminal state, never a successful scan or a quote cache.
  /// Zero means the universe has not yet been loaded; no prices are invented.
  factory CandidateSnapshot.fallback({
    required StockMarket marketType,
    required DateTime updatedAt,
    int universeCount = 0,
    int scanPoolSize = 0,
    String reason = '市場評估未完成，請檢查連線後重試。',
  }) => CandidateSnapshot(
        candidates: const [], fetchedAt: updatedAt.toUtc(),
        attemptedAt: updatedAt.toUtc(),
        warnings: [reason],
        source: '${marketType == StockMarket.tw ? '台股' : '美股'}市場評估未完成',
        universeCount: universeCount, scanPoolSize: scanPoolSize,
        evaluatedCount: 0, adrMatchCount: 0,
        universeIsComplete: false, stale: true, isFallback: true,
      );

  final List<StockCandidate> candidates;
  final DateTime fetchedAt;
  final List<String> warnings;
  final String source;
  final int universeCount;
  final bool stale;
  final List<String> missingSymbols;
  final int? evaluatedCount;
  /// Actual foreground pool, distinct from full market membership.
  final int? scanPoolSize;
  /// Successfully evaluated stocks meeting the configured ADR threshold.
  final int? adrMatchCount;
  final bool universeIsComplete;
  final DateTime? universeAsOf;
  final DateTime? scanCompletedAt;
  /// This timestamp records the failed attempt, not a verified market quote.
  final DateTime? attemptedAt;
  final bool isFallback;

  DateTime get generatedAt => fetchedAt;
  bool get isStale => stale;
}

abstract interface class CandidateRepository {
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  });
}

/// A user-readable error. API failures never silently switch to fake data.
class RepositoryException implements Exception {
  const RepositoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RealCandidateRepository implements CandidateRepository {
  RealCandidateRepository({required String baseUrl, http.Client? client,
      Duration requestTimeout = NetworkRequest.defaultTimeout})
      : _baseUri = _parseBaseUrl(baseUrl),
        _network = NetworkRequest(client: client, timeout: requestTimeout);

  final Uri _baseUri;
  final NetworkRequest _network;

  @override
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    _validateThreshold(adrThreshold);
    final endpoint = _baseUri.replace(
      path: '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/v1/candidates',
      queryParameters: {
        'market': market.name,
        'adr_threshold': adrThreshold.toString(),
      },
    );
    try {
      final response = await _network.get(endpoint,
          headers: {'Accept': 'application/json'});
      if (response.statusCode != 200) {
        throw RepositoryException('掃描 API 回應 HTTP ${response.statusCode}，請檢查後端狀態。');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('回應必須為 JSON 物件。');
      }
      return _parseSnapshot(decoded, market);
    } on RepositoryException {
      rethrow;
    } on TimeoutException {
      throw const RepositoryException('掃描 API 連線逾時，請稍後重試。');
    } on http.ClientException {
      throw const RepositoryException('無法連線掃描 API，請檢查網址與網路連線。');
    } on FormatException catch (error) {
      throw RepositoryException('掃描 API 資料格式錯誤：${error.message}');
    } catch (error) {
      throw RepositoryException('無法讀取掃描結果：${error.runtimeType}。');
    }
  }

  void close() {
    _network.close();
  }
}

CandidateSnapshot _parseSnapshot(Map<String, dynamic> json, StockMarket market) {
  if (json['market'] != market.name) {
    throw const FormatException('回應市場與要求市場不符。');
  }
  final source = json['source'];
  final count = json['universe_count'];
  final stale = json['stale'];
  final warnings = json['warnings'];
  final rows = json['candidates'];
  if (source is! String || source.trim().isEmpty ||
      count is! int || count < 0 || stale is! bool || warnings is! List ||
      warnings.any((warning) => warning is! String) || rows is! List) {
    throw const FormatException('來源、股票池數量、快取狀態或候選清單格式無效。');
  }
  if (RegExp(r'mock|demo|fictit|假|虛構|示範|離線', caseSensitive: false).hasMatch(source)) {
    throw const FormatException('正式掃描 API 回傳了示範來源，已拒絕載入。');
  }
  // Envelope failures invalidate the response; a bad individual stock does
  // not invalidate independently verified rows from the same response.
  final generatedAt = parseApiTimestamp(json['generated_at'], 'generated_at');
  final universeAsOf = json['universe_as_of'] == null ? null :
      parseApiTimestamp(json['universe_as_of'], 'universe_as_of');
  final evaluated = json['evaluated_count'];
  final scanPoolSize = json['scan_pool_size'];
  final adrMatchCount = json['adr_match_count'];
  final complete = json['universe_is_complete'];
  if ((evaluated != null && (evaluated is! int || evaluated < 0 || evaluated > count)) ||
      (scanPoolSize != null && (scanPoolSize is! int || scanPoolSize < 0 ||
          scanPoolSize > count || (evaluated is int && evaluated > scanPoolSize))) ||
      (adrMatchCount != null && (adrMatchCount is! int || adrMatchCount < 0 ||
          adrMatchCount > (evaluated is int ? evaluated : count))) ||
      (complete != null && complete is! bool)) {
    throw const FormatException('已評估數量或完整股票池旗標格式無效。');
  }
  final missing = json['missing_symbols'];
  if (missing != null && (missing is! List ||
      missing.any((item) => item is! String || item.trim().isEmpty))) {
    throw const FormatException('missing_symbols 必須為非空字串陣列。');
  }
  final candidates = <String, StockCandidate>{};
  final seenSymbols = <String>{};
  final failedSymbols = <String>{};
  final rowWarnings = <String>[];
  var rejectedRows = 0;
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final rawSymbol = row is Map<String, dynamic> ? row['symbol'] : null;
    final symbol = rawSymbol is String && rawSymbol.trim().isNotEmpty
        ? rawSymbol.trim() : null;
    try {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('個股資料必須為 JSON 物件。');
      }
      if (symbol != null && !seenSymbols.add(symbol)) {
        // A duplicate is ambiguous. Remove every copy of this stock, retaining
        // unrelated symbols instead of choosing whichever copy arrived first.
        if (candidates.remove(symbol) != null) rejectedRows++;
        throw const FormatException('重複股票代碼，該股票所有候選已排除。');
      }
      final candidate = StockCandidate.fromJson(row);
      final validSymbol = (market == StockMarket.tw ? RegExp(r'^\d{4}\.TW$') :
          RegExp(r'^[A-Z][A-Z0-9-]{0,14}$')).hasMatch(candidate.symbol);
      if (candidate.market != market || !validSymbol) {
        throw const FormatException('個股市場或標準股票代碼與要求不符。');
      }
      final latestAllowed = generatedAt.add(const Duration(minutes: 1));
      if (candidate.dataTimestamp.isAfter(latestAllowed) ||
          (candidate.signalTimestamp?.isAfter(latestAllowed) ?? false)) {
        throw const FormatException('個股行情或訊號時間晚於掃描回應時間。');
      }
      candidates[candidate.symbol] = candidate;
    } catch (error) {
      rejectedRows++;
      if (symbol != null && failedSymbols.length < 1000) {
        failedSymbols.add(_boundedCandidateMessage(symbol, 40));
      }
      if (rowWarnings.length < 20) {
        final label = symbol == null ? '第 ${index + 1} 筆候選' : symbol;
        final reason = error is FormatException ? error.message : error.runtimeType.toString();
        rowWarnings.add('${_boundedCandidateMessage(label, 40)} 已排除：'
            '${_boundedCandidateMessage(reason.toString(), 160)}');
      }
    }
  }
  if (count < candidates.length ||
      (evaluated is int && evaluated < candidates.length)) {
    throw const FormatException('股票池或已評估數量小於有效候選股票數量。');
  }
  if (rows.isNotEmpty && candidates.isEmpty) {
    // A valid genuinely empty scan is allowed. A nonempty corrupt response
    // must fail so the controller retains its previous timestamped snapshot.
    throw FormatException('非空候選清單全部無法驗證：${rowWarnings.join('；')}');
  }
  final combinedWarnings = <String>[
    ...warnings.cast<String>().take(100)
        .map((warning) => _boundedCandidateMessage(warning, 240)),
    if (rejectedRows > 0) '已隔離 $rejectedRows 筆無效候選，其他有效股票仍可查看。',
    ...rowWarnings,
    if (rejectedRows > rowWarnings.length)
      '另有 ${rejectedRows - rowWarnings.length} 筆無效候選；詳細警告最多顯示 20 筆。',
  ];
  return CandidateSnapshot(
    candidates: candidates.values.toList(),
    fetchedAt: generatedAt,
    warnings: combinedWarnings,
    source: source,
    universeCount: count,
    stale: stale,
    evaluatedCount: evaluated is int ? evaluated : null,
    scanPoolSize: scanPoolSize is int ? scanPoolSize : null,
    adrMatchCount: adrMatchCount is int ? adrMatchCount : null,
    universeIsComplete: complete != false,
    universeAsOf: universeAsOf,
    scanCompletedAt: generatedAt,
    missingSymbols: <String>{
      if (missing is List) ...missing.cast<String>().take(1000)
          .map((symbol) => _boundedCandidateMessage(symbol, 40)),
      ...failedSymbols.where((symbol) => !candidates.containsKey(symbol)),
    }.take(1000).toList(),
  );
}

String _boundedCandidateMessage(String value, int maximum) =>
    value.length <= maximum ? value : '${value.substring(0, maximum)}…';

Uri _parseBaseUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty || uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
    throw const RepositoryException('API 網址必須為有效的 HTTP / HTTPS 網址。');
  }
  return uri;
}

void _validateThreshold(double value) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, 'adrThreshold', 'ADR 門檻必須為有限非負數。');
  }
}

/// Fixed, clearly labeled fictitious quotes allow every screen to work offline.
/// Stock identities are real for familiarity; quotes, ranks and signals are not.
class MockCandidateRepository implements CandidateRepository {
  @override
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    _validateThreshold(adrThreshold);
    final candidates = _mockCandidates(market)
        .where((candidate) => candidate.adrPercent >= adrThreshold)
        .toList();
    return CandidateSnapshot(
      candidates: candidates,
      fetchedAt: _demoTime,
      warnings: const [
        '離線示範：報價、ADR、RS 與訊號全部為固定假資料，並非即時掃描。',
        '資料僅含範例股票，未掃描完整 TWSE 或 S&P 500 股票池。',
      ],
      source: '離線示範',
      universeCount: 8,
      evaluatedCount: 8,
      universeIsComplete: false,
      stale: false,
    );
  }
}

final _demoTime = DateTime.utc(2026, 10, 13, 6);

List<StockCandidate> _mockCandidates(StockMarket market) {
  // Prices use the market currency. No USD/TWD conversion is performed.
  final specs = market == StockMarket.tw
      ? <_MockSpec>[
          const _MockSpec('2330.TW', '台積電', '半導體', 1120, 5.3, 99, 1, true, 'PDH 突破', 2.0),
          const _MockSpec('2317.TW', '鴻海', '電子製造', 220, 4.1, 95, 2, true, 'ORH 突破・Episodic Pivot', 2.5),
          const _MockSpec('2454.TW', '聯發科', 'IC 設計', 1390, 4.9, 93, 3, true, '均線密集收斂', null),
          const _MockSpec('2382.TW', '廣達', '電腦週邊', 320, 6.1, 90, 4, true, 'PDH 突破', 1.5),
          const _MockSpec('3017.TW', '奇鋐', '散熱', 650, 6.8, 88, 5, false, 'ORH 突破', 3.0),
          const _MockSpec('1519.TW', '華城', '電機機械', 710, 7.2, 86, 6, false, 'PDH 突破', 2.0),
          const _MockSpec('2308.TW', '台達電', '電子零組件', 420, 4.0, 82, 7, true, '均線密集收斂', null),
          const _MockSpec('2376.TW', '技嘉', '電腦週邊', 295, 5.6, 80, 8, false, 'ORH 突破', 2.5),
        ]
      : <_MockSpec>[
          const _MockSpec('NVDA', 'NVIDIA', '資訊科技', 140, 7.1, 99, 1, true, 'PDH 突破', 2.0),
          const _MockSpec('TSLA', 'Tesla', '非必需消費品', 270, 8.2, 96, 2, true, 'ORH 突破・Episodic Pivot', 2.5),
          const _MockSpec('AMD', 'Advanced Micro Devices', '資訊科技', 165, 6.9, 93, 3, true, '均線密集收斂', null),
          const _MockSpec('META', 'Meta Platforms', '通訊服務', 610, 5.6, 90, 4, true, 'PDH 突破', 1.5),
          const _MockSpec('AVGO', 'Broadcom', '資訊科技', 188, 6.2, 88, 5, true, 'ORH 突破', 3.0),
          const _MockSpec('PLTR', 'Palantir Technologies', '資訊科技', 45, 8.8, 85, 6, false, 'PDH 突破', 2.0),
          const _MockSpec('NFLX', 'Netflix', '通訊服務', 720, 5.3, 83, 7, true, '均線密集收斂', null),
          const _MockSpec('MU', 'Micron Technology', '資訊科技', 106, 6.5, 80, 8, false, 'ORH 突破', 2.5),
        ];
  return specs.map((spec) {
    final stop = spec.stopPercent == null
        ? null
        : double.parse((spec.price * (1 - spec.stopPercent! / 100)).toStringAsFixed(4));
    return StockCandidate(
      id: '${market.name}:${spec.symbol}',
      symbol: spec.symbol,
      name: spec.name,
      sector: spec.sector,
      market: market,
      adrPercent: spec.adr,
      rsScore: spec.rs,
      rsRank: spec.rank,
      patterns: [spec.pattern],
      entryPrice: spec.price,
      stopPrice: stop,
      triggerPrice: spec.price,
      triggerType: spec.pattern.contains('PDH') ? 'PDH' : spec.pattern.contains('ORH') ? 'ORH' : null,
      stopSource: stop == null ? null : 'day_low',
      dayLow: stop,
      isLargeLiquid: spec.large,
      status: stop == null ? 'watchlist' : 'confirmed',
      dataTimestamp: _demoTime,
      signalTimestamp: stop == null ? null : _demoTime,
      notes: const ['假資料示範；不可據此認定當前報價或真實突破。', '風險預算未包含跳空、滑價與交易成本。'],
      dailyCloses: List<double>.generate(
        40,
        (index) => double.parse((spec.price * (0.83 + index * 0.004 + (index % 5 - 2) * 0.003)).toStringAsFixed(2)),
      ),
    );
  }).toList();
}

class _MockSpec {
  const _MockSpec(this.symbol, this.name, this.sector, this.price, this.adr,
      this.rs, this.rank, this.large, this.pattern, this.stopPercent);
  final String symbol;
  final String name;
  final String sector;
  final double price;
  final double adr;
  final double rs;
  final int rank;
  final bool large;
  final String pattern;
  final double? stopPercent;
}
```

## lib/services/portfolio_repository.dart

```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/portfolio_position.dart';
import '../models/stock_candidate.dart';
import 'network_request.dart';

class PortfolioQuoteSnapshot {
  PortfolioQuoteSnapshot({required Map<String, PortfolioQuote> quotes,
    required Map<String, String> errors, required this.source,
    List<String> warnings = const []})
      : quotes = Map.unmodifiable(quotes), errors = Map.unmodifiable(errors),
        warnings = List.unmodifiable(warnings);
  final Map<String, PortfolioQuote> quotes;
  final Map<String, String> errors;
  final String source;
  final List<String> warnings;
}

abstract interface class PortfolioRepository {
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false});
  void close();
}

class RealPortfolioRepository implements PortfolioRepository {
  RealPortfolioRepository({required String baseUrl, http.Client? client,
      Duration requestTimeout = NetworkRequest.defaultTimeout})
      : _baseUri = Uri.parse(baseUrl),
        _network = NetworkRequest(client: client, timeout: requestTimeout) {
    if (!['http', 'https'].contains(_baseUri.scheme) || _baseUri.host.isEmpty ||
        _baseUri.userInfo.isNotEmpty || _baseUri.hasQuery || _baseUri.hasFragment) {
      throw ArgumentError('行情 API 網址格式無效。');
    }
  }
  final Uri _baseUri;
  final NetworkRequest _network;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false}) async {
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    final sources = <String>{};
    final warnings = <String>[];
    // The backend permits at most 50 symbols per request. Keep successes from
    // other chunks if a single request fails, and identify every missing quote.
    for (var start = 0; start < symbols.length; start += 50) {
      final batch = symbols.skip(start).take(50).toList();
      try {
        final snapshot = await _fetchBatch(market, batch);
        quotes.addAll(snapshot.quotes);
        errors.addAll(snapshot.errors);
        sources.add(snapshot.source);
        warnings.addAll(snapshot.warnings.take(20 - warnings.length));
      } catch (error) {
        for (final symbol in batch) {
          errors[symbol] = _boundedQuoteMessage('行情批次取得失敗：$error');
        }
      }
    }
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
      source: sources.isEmpty ? 'API 行情尚不可用' : sources.join('／'),
      warnings: warnings);
  }

  Future<PortfolioQuoteSnapshot> _fetchBatch(StockMarket market, List<String> symbols) async {
    if (symbols.isEmpty) {
      return PortfolioQuoteSnapshot(quotes: {}, errors: {}, source: '無持股');
    }
    final endpoint = _baseUri.replace(
      path: '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/v1/quotes',
      queryParameters: {'market': market.name, 'symbols': symbols.join(','), 'demo': 'false'},
    );
    try {
      final response = await _network.get(endpoint,
          headers: {'Accept': 'application/json'});
      if (response.statusCode != 200) throw StateError('行情 API HTTP ${response.statusCode}');
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic> || data['market'] != market.name ||
          data['quotes'] is! List || data['errors'] is! Map || data['source'] is! String) {
        throw const FormatException('行情回應格式無效。');
      }
      final generatedAt = parseApiTimestamp(data['generated_at'], 'generated_at');
      final source = (data['source'] as String).trim();
      if (source.isEmpty || _isDemoSource(source)) {
        throw const FormatException('實際行情 API 回傳了示範來源或空白來源。');
      }
      for (final flag in ['is_cached', 'is_stale', 'stale']) {
        if (data.containsKey(flag) && data[flag] is! bool) {
          throw FormatException('$flag 回應旗標必須為布林值。');
        }
      }
      final quotes = <String, PortfolioQuote>{};
      final errors = <String, String>{};
      final warnings = <String>[];
      final requested = symbols.toSet();
      final seenSymbols = <String>{};
      final rows = data['quotes'] as List;
      void warn(String message) {
        if (warnings.length < 20) warnings.add(_boundedQuoteMessage(message));
      }
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final rawSymbol = row is Map<String, dynamic> ? row['symbol'] : null;
        final symbol = rawSymbol is String ? rawSymbol.trim() : null;
        try {
          if (row is! Map<String, dynamic>) {
            throw const FormatException('行情必須為 JSON 物件。');
          }
          if (symbol != null && requested.contains(symbol) && !seenSymbols.add(symbol)) {
            quotes.remove(symbol);
            throw const FormatException('重複股票行情；該代碼所有回應已排除。');
          }
          for (final flag in ['is_cached', 'is_stale']) {
            if (row.containsKey(flag) && row[flag] is! bool) {
              throw FormatException('$flag 個股旗標必須為布林值。');
            }
          }
          if (row['cache_warning'] != null && row['cache_warning'] is! String) {
            throw const FormatException('個股快取警告必須為字串。');
          }
          final quote = PortfolioQuote.fromJson(row);
          if (quote.market != market || !requested.contains(quote.symbol) ||
              _isDemoSource(quote.source)) {
            throw const FormatException('行情來自不同市場、未要求的股票或示範來源。');
          }
          final latestAllowed = generatedAt.add(const Duration(minutes: 1));
          if (quote.quoteTimestamp.isAfter(latestAllowed) ||
              (quote.fetchedAt?.isAfter(latestAllowed) ?? false)) {
            throw const FormatException('個股報價時間晚於行情回應時間。');
          }
          // Any explicit cached/stale marker freezes observation history. The
          // original provider quote/close timestamps are preserved unchanged.
          final stale = quote.isStale || data['stale'] == true || data['is_stale'] == true;
          final cached = quote.isCached || data['is_cached'] == true || stale ||
              (quote.cacheWarning?.trim().isNotEmpty ?? false);
          quotes[quote.symbol] = PortfolioQuote(
            symbol: quote.symbol, name: quote.name, market: quote.market,
            currentPrice: quote.currentPrice, ema9: quote.ema9,
            ema21: quote.ema21, ema50: quote.ema50, lastClose: quote.lastClose,
            closeConfirmed: quote.closeConfirmed, quoteTimestamp: quote.quoteTimestamp,
            closeTimestamp: quote.closeTimestamp, source: quote.source,
            isLargeLiquid: quote.isLargeLiquid, isCached: cached, isStale: stale,
            cacheWarning: quote.cacheWarning ?? (cached ? 'API 標示為快取行情；最高 R 與停損保持不變。' : null),
            fetchedAt: quote.fetchedAt,
          );
        } catch (error) {
          final reason = error is FormatException ? error.message.toString() : error.runtimeType.toString();
          final label = symbol?.isNotEmpty == true ? symbol! : '第 ${index + 1} 筆行情';
          final message = _boundedQuoteMessage('$label 行情已排除：$reason');
          warn(message);
          if (symbol != null && requested.contains(symbol)) errors[symbol] = message;
        }
      }
      for (final entry in (data['errors'] as Map).entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || !requested.contains(key)) {
          warn('已忽略未要求股票或無代碼的 API 錯誤訊息。');
          continue;
        }
        if (value is! String || value.trim().isEmpty) {
          quotes.remove(key);
          errors[key] = 'API 回傳的個股錯誤訊息格式無效；該股保留上次快取。';
          continue;
        }
        if (quotes.remove(key) != null) {
          errors[key] = _boundedQuoteMessage('同一股票同時回傳行情與錯誤：$value；行情已排除。');
          warn('$key 行情與錯誤互相矛盾，該股保留上次快取。');
        } else {
          errors.putIfAbsent(key, () => _boundedQuoteMessage(value));
        }
      }
      for (final symbol in symbols) {
        if (!quotes.containsKey(symbol)) errors.putIfAbsent(symbol, () => 'API 未提供可驗證行情');
      }
      if (rows.isNotEmpty && quotes.isEmpty) {
        throw FormatException('非空行情清單全部無法驗證：'
            '${errors.values.take(3).join('；')}');
      }
      return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
          source: source, warnings: warnings);
    } on TimeoutException {
      throw StateError('持股行情連線逾時，請稍後重試。');
    } on http.ClientException {
      throw StateError('無法連線持股行情 API，請檢查網址與網路。');
    }
  }

  @override
  void close() { _network.close(); }
}

bool _isDemoSource(String value) =>
    RegExp(r'mock|demo|fictit|假|虛構|示範|離線', caseSensitive: false).hasMatch(value);

String _boundedQuoteMessage(String value) =>
    value.length <= 240 ? value : '${value.substring(0, 240)}…';

/// Fixed fictitious daily snapshots. Unknown symbols require manual demo input.
class MockPortfolioRepository implements PortfolioRepository {
  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false}) async {
    final known = {for (final quote in mockPortfolioQuotes()) quote.key: quote};
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    for (final symbol in symbols) {
      final quote = known['${market.name}:$symbol'];
      if (quote == null) {
        errors[symbol] = '無此股票的固定假行情；請使用「調整示範行情」自行輸入。';
      } else {
        quotes[symbol] = quote;
      }
    }
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors, source: '離線虛構行情');
  }
  @override
  void close() {}
}

List<PortfolioPosition> demoPortfolioPositions() => [
  PortfolioPosition(id: 'demo-tw-2330', symbol: '2330.TW', name: '台積電',
    market: StockMarket.tw, entryPrice: 1000, shares: 200, initialStop: 980),
  PortfolioPosition(id: 'demo-tw-3017', symbol: '3017.TW', name: '奇鋐',
    market: StockMarket.tw, entryPrice: 650, shares: 100, initialStop: 637),
  PortfolioPosition(id: 'demo-us-nvda', symbol: 'NVDA', name: 'NVIDIA',
    market: StockMarket.us, entryPrice: 100, shares: 80, initialStop: 98),
  PortfolioPosition(id: 'demo-us-tsla', symbol: 'TSLA', name: 'Tesla',
    market: StockMarket.us, entryPrice: 250, shares: 40, initialStop: 245),
];

List<PortfolioQuote> mockPortfolioQuotes() {
  final time = DateTime.utc(2026, 10, 13, 6);
  final closeTime = DateTime.utc(2026, 10, 12, 20);
  PortfolioQuote quote(String symbol, String name, StockMarket market,
      double price, double ema9, double ema21, double ema50,
      double close, bool large) => PortfolioQuote(
    symbol: symbol, name: name, market: market, currentPrice: price,
    ema9: ema9, ema21: ema21, ema50: ema50, lastClose: close,
    closeConfirmed: true, quoteTimestamp: time,
    closeTimestamp: market == StockMarket.tw ? DateTime.utc(2026, 10, 12, 5, 30) : closeTime,
    source: '離線虛構行情（並非最新市價）', isLargeLiquid: large,
  );
  return [
    quote('2330.TW', '台積電', StockMarket.tw, 1060, 1040, 1020, 990, 1050, true),
    quote('3017.TW', '奇鋐', StockMarket.tw, 640, 645, 630, 610, 640, false),
    quote('NVDA', 'NVIDIA', StockMarket.us, 110, 107, 104, 100, 109, true),
    quote('TSLA', 'Tesla', StockMarket.us, 248, 247, 240, 230, 249, true),
  ];
}
```

## lib/services/stock_universe_service.dart

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'network_request.dart';

typedef DateTimeFunction = DateTime Function();

/// A universe is metadata, not market prices or a recommendation. A partial
/// local dictionary must never be presented as the latest full constituent list.
class UniverseSnapshot {
  UniverseSnapshot({
    required List<StockItem> stocks,
    required this.asOf,
    required this.source,
    required this.isComplete,
    List<String> warnings = const [],
    this.isCached = false,
  })  : stocks = List.unmodifiable(stocks),
        warnings = List.unmodifiable(warnings);

  final List<StockItem> stocks;
  final DateTime asOf;
  final String source;
  final bool isComplete;
  final List<String> warnings;
  final bool isCached;

  int get totalCount => stocks.length;
}

/// One request loads a complete provider list, while alias/name lookups reuse
/// the bundled master dictionary. No metadata HTTP is sent per search keystroke.
///
/// This service fetches public HTTPS endpoints without an API secret. These
/// endpoints may change, reject requests or lack browser CORS permission; a
/// failure produces a clearly identified real metadata cache, never fake data.
class StockUniverseService {
  StockUniverseService({
    http.Client? client,
    SharedPreferences? preferences,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTimeFunction? now,
    this.requestTimeout = NetworkRequest.defaultTimeout,
    this.storageTimeout = NetworkRequest.defaultStorageTimeout,
  })  : _network = NetworkRequest(client: client, timeout: requestTimeout),
        _preferences = preferences,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now {
    if (storageTimeout <= Duration.zero ||
        storageTimeout > NetworkRequest.storageTimeout) {
      throw ArgumentError.value(storageTimeout, 'storageTimeout',
          '本機快取等待必須大於零且不得超過 5 秒。');
    }
  }

  static final Uri usEndpoint = Uri.parse(
    'https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv',
  );
  static final Uri twEndpoint = Uri.parse(
    'https://openapi.twse.com.tw/v1/opendata/t187ap03_L',
  );
  static const Duration cacheLifetime = Duration(hours: 24);
  static const Duration maximumStaleAge = Duration(days: 30);
  final Duration requestTimeout;
  final Duration storageTimeout;
  final NetworkRequest _network;
  final DateTimeFunction _now;
  SharedPreferences? _preferences;
  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<Map<String, StockItem>>? _master;
  final Map<StockMarket, Future<UniverseSnapshot>> _inFlight = {};
  bool _closed = false;

  static String cacheKey(StockMarket market) =>
      'martin_luk.universe.v1.${market.name}';

  Future<UniverseSnapshot> load(
    StockMarket market, {
    bool forceRefresh = false,
  }) async {
    if (_closed) throw StateError('股票池服務已關閉。');
    final pending = _inFlight[market];
    if (pending != null) return pending;
    final operation = _load(market, forceRefresh: forceRefresh);
    _inFlight[market] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[market], operation)) _inFlight.remove(market);
    }
  }

  Future<UniverseSnapshot> _load(
    StockMarket market, {
    required bool forceRefresh,
  }) async {
    final now = _now().toUtc();
    final warnings = <String>[];
    final preferences = await _getPreferences(warnings);
    final cached = _readCache(preferences, market, now, warnings);
    if (!forceRefresh && cached != null &&
        now.difference(cached.asOf) <= cacheLifetime) {
      return _cachedCopy(cached, warnings);
    }

    // A missing alias asset does not prevent live universe retrieval. Missing
    // aliases only affect bilingual display and can be retried on another load.
    Map<String, StockItem> master = const {};
    try {
      master = await (_master ??= _loadMaster()).timeout(storageTimeout);
    } catch (_) {
      _master = null;
      warnings.add('本機中文別名字典無法讀取；連網清單仍使用資料源名稱。');
    }

    try {
      final response = await _network.get(
        market == StockMarket.us ? usEndpoint : twEndpoint,
        headers: const {'Accept': 'application/json,text/csv;q=0.9,*/*;q=0.8'},
      );
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}');
      }
      final body = utf8.decode(response.bodyBytes);
      final stocks = market == StockMarket.us
          ? _parseUs(body, master)
          : _parseTw(body, master);
      if (stocks.isEmpty) {
        throw const FormatException('股票池資料源沒有可用普通股。');
      }
      // Membership count fluctuates, including multiple S&P share classes.
      // Broad sanity bounds detect a truncated response, not index membership.
      final complete = market == StockMarket.us
          ? stocks.length >= 450 && stocks.length <= 600
          : stocks.length >= 700 && stocks.length <= 2000;
      if (!complete) {
        warnings.add('資料源只回傳 ${stocks.length} 檔，低於完整股票池合理範圍；掃描覆蓋不足。');
      }
      final snapshot = UniverseSnapshot(
        stocks: stocks,
        asOf: now,
        source: market == StockMarket.us
            ? 'S&P 500 constituents (datasets GitHub)'
            : 'TWSE OpenAPI listed ordinary-stock issuers',
        isComplete: complete,
        warnings: warnings,
      );
      if (preferences != null) {
        try {
          final written = await preferences.setString(
            cacheKey(market), jsonEncode(_encode(snapshot, market)),
          ).timeout(storageTimeout);
          if (!written) throw StateError('快取儲存失敗。');
        } catch (_) {
          return UniverseSnapshot(
            stocks: snapshot.stocks,
            asOf: snapshot.asOf,
            source: snapshot.source,
            isComplete: snapshot.isComplete,
            warnings: [...snapshot.warnings, '最新股票池已取得，但無法儲存本機快取。'],
          );
        }
      }
      return snapshot;
    } catch (error) {
      warnings.add('股票池更新失敗（${_errorLabel(error)}）；沒有使用示範行情。');
      if (cached != null) {
        warnings.add('使用 ${cached.asOf.toIso8601String()} 的股票池快取，成分可能已變更。');
        return _cachedCopy(cached, warnings);
      }
      final fallback = master.values.where((item) => item.market == market).toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
      if (fallback.isEmpty) {
        throw StateError('無法取得股票池，且沒有可用本機元資料；請連網後重試。');
      }
      return UniverseSnapshot(
        stocks: fallback,
        // Build-time dictionary date is intentionally distinct from retrieval
        // time: opening the app does not refresh constituent membership.
        asOf: DateTime.utc(2026, 10, 13),
        source: 'bundled stock metadata dictionary (partial, unverified membership)',
        isComplete: false,
        isCached: true,
        warnings: [
          ...warnings,
          '僅使用內建 ${fallback.length} 檔搜尋字典；它不是目前完整 S&P 500／TWSE 股票池，成分日期未驗證。',
        ],
      );
    }
  }

  Future<SharedPreferences?> _getPreferences(List<String> warnings) async {
    try {
      return _preferences ??= await _preferencesLoader().timeout(storageTimeout);
    } catch (_) {
      warnings.add('本機儲存不可用，股票池快取暫停。');
      return null;
    }
  }

  UniverseSnapshot? _readCache(
    SharedPreferences? preferences,
    StockMarket market,
    DateTime now,
    List<String> warnings,
  ) {
    if (preferences == null) return null;
    try {
      final raw = preferences.getString(cacheKey(market));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1 ||
          decoded['market'] != market.name || decoded['source'] is! String ||
          decoded['is_complete'] is! bool || decoded['stocks'] is! List) {
        throw const FormatException('股票池快取結構無效。');
      }
      final asOf = parseApiTimestamp(decoded['as_of'], 'as_of');
      final age = now.difference(asOf);
      if (age.isNegative || age > maximumStaleAge) {
        warnings.add('股票池快取日期無效或已超過 30 天；不以它當作現行成分。');
        return null;
      }
      final seen = <String>{};
      final stocks = (decoded['stocks'] as List).map((row) {
        if (row is! Map<String, dynamic>) {
          throw const FormatException('股票池快取紀錄無效。');
        }
        final stock = StockItem.fromJson(row);
        if (stock.market != market || !seen.add(stock.key)) {
          throw const FormatException('股票池快取含跨市場或重複紀錄。');
        }
        return stock;
      }).toList();
      if (stocks.isEmpty) throw const FormatException('股票池快取不得為空。');
      final storedWarnings = decoded['warnings'];
      if (storedWarnings is! List || storedWarnings.any((entry) => entry is! String)) {
        throw const FormatException('股票池快取提示無效。');
      }
      return UniverseSnapshot(
        stocks: stocks,
        asOf: asOf,
        source: decoded['source'] as String,
        isComplete: decoded['is_complete'] as bool,
        warnings: storedWarnings.cast<String>(),
        isCached: true,
      );
    } catch (_) {
      warnings.add('股票池快取損毀；重新取得連網清單。');
      return null;
    }
  }

  static Map<String, dynamic> _encode(UniverseSnapshot snapshot, StockMarket market) => {
    'version': 1,
    'market': market.name,
    'as_of': snapshot.asOf.toUtc().toIso8601String(),
    'source': snapshot.source,
    'is_complete': snapshot.isComplete,
    'warnings': snapshot.warnings,
    'stocks': snapshot.stocks.map((stock) => stock.toJson()).toList(),
  };

  static UniverseSnapshot _cachedCopy(UniverseSnapshot snapshot, List<String> warnings) =>
      UniverseSnapshot(
        stocks: snapshot.stocks,
        asOf: snapshot.asOf,
        source: snapshot.source,
        isComplete: snapshot.isComplete,
        isCached: true,
        warnings: {...snapshot.warnings, ...warnings}.toList(),
      );

  static Future<Map<String, StockItem>> _loadMaster() async {
    final decoded = jsonDecode(await rootBundle.loadString('stocks_master.json'));
    if (decoded is! List) throw const FormatException('股票字典必須為陣列。');
    final index = <String, StockItem>{};
    for (final row in decoded) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('股票字典紀錄無效。');
      }
      final stock = StockItem.fromJson(row);
      if (index.containsKey(stock.key)) {
        throw const FormatException('股票字典有重複股票。');
      }
      index[stock.key] = stock;
    }
    return index;
  }

  static List<StockItem> _parseUs(String body, Map<String, StockItem> master) {
    final rows = _csv(body);
    if (rows.isEmpty) throw const FormatException('S&P 500 CSV 為空。');
    final headers = rows.first.map((field) => field.trim().toLowerCase()).toList();
    final symbolColumn = headers.indexOf('symbol');
    final nameColumn = headers.indexOf('name');
    if (symbolColumn < 0 || nameColumn < 0) {
      throw const FormatException('S&P 500 CSV 缺少 Symbol／Name 欄位。');
    }
    final seen = <String>{};
    final stocks = <StockItem>[];
    for (final row in rows.skip(1)) {
      if (row.every((field) => field.trim().isEmpty)) continue;
      if (row.length != headers.length) {
        throw const FormatException('S&P 500 CSV 欄位數不一致。');
      }
      final symbol = row[symbolColumn].trim().toUpperCase().replaceAll('.', '-');
      final name = row[nameColumn].trim();
      if (!RegExp(r'^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$').hasMatch(symbol) || name.isEmpty) {
        throw const FormatException('S&P 500 CSV 含無效代碼或名稱。');
      }
      if (!seen.add(symbol)) throw const FormatException('S&P 500 CSV 含重複代碼。');
      final known = master['us:$symbol'];
      stocks.add(StockItem(
        market: StockMarket.us,
        symbol: symbol,
        code: symbol,
        nameZh: known?.nameZh ?? '',
        nameFullZh: known?.nameFullZh ?? '',
        nameEn: name,
        abbrEn: known?.abbrEn ?? '',
        aliases: known?.aliases ?? const [],
        shortCodes: known?.shortCodes ?? const [],
      ));
    }
    return stocks..sort((a, b) => a.symbol.compareTo(b.symbol));
  }

  static List<StockItem> _parseTw(String body, Map<String, StockItem> master) {
    final decoded = jsonDecode(body);
    if (decoded is! List) throw const FormatException('TWSE 股票池必須為 JSON 陣列。');
    final stocks = <StockItem>[];
    final seen = <String>{};
    for (final row in decoded) {
      if (row is! Map<String, dynamic> || !row.containsKey('公司代號')) {
        throw const FormatException('TWSE 股票池缺少公司代號。');
      }
      final code = _field(row, ['公司代號']);
      // Listed issuers' ordinary common shares use four digits beginning with
      // 1–9. A 0-prefix identifies a fund/ETF rather than an ordinary issuer.
      if (!RegExp(r'^[1-9]\d{3}$').hasMatch(code)) continue;
      final name = _field(row, ['公司簡稱', '公司名稱']);
      final fullName = _field(row, ['公司名稱', '公司簡稱']);
      final industry = _field(row, ['產業別']);
      final classification = row.entries
          .where((entry) => RegExp(r'股票種類|證券種類|證券別|security.?type|category', caseSensitive: false)
              .hasMatch(entry.key))
          .map((entry) => entry.value.toString()).join(' ');
      if (industry == '91' || RegExp(r'存託憑證|特別股|TDR|preferred', caseSensitive: false)
          .hasMatch('$name $fullName $classification')) continue;
      if (name.isEmpty || !seen.add(code)) {
        throw const FormatException('TWSE 股票池含空白名稱或重複代碼。');
      }
      final symbol = '$code.TW';
      final known = master['tw:$symbol'];
      final sourceEnglish = _field(row, ['英文全名', '英文名稱']);
      final sourceAbbr = _field(row, ['英文簡稱']);
      stocks.add(StockItem(
        market: StockMarket.tw,
        symbol: symbol,
        code: code,
        nameZh: name,
        nameFullZh: fullName,
        nameEn: sourceEnglish.isNotEmpty ? sourceEnglish : known?.nameEn ?? '',
        abbrEn: sourceAbbr.isNotEmpty ? sourceAbbr : known?.abbrEn ?? '',
        aliases: {...?known?.aliases, if (known != null && known.nameZh != name) known.nameZh}.toList(),
        shortCodes: known?.shortCodes ?? const [],
      ));
    }
    return stocks..sort((a, b) => a.symbol.compareTo(b.symbol));
  }

  static String _field(Map<String, dynamic> row, List<String> names) {
    for (final name in names) {
      final value = row[name];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return value.toString();
    }
    return '';
  }

  /// RFC 4180-style quotes, escaped quotes, embedded commas/newlines and BOM.
  static List<List<String>> _csv(String raw) {
    final input = raw.startsWith('\ufeff') ? raw.substring(1) : raw;
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;
    var quoteClosed = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (quoted) {
        if (char == '"') {
          if (index + 1 < input.length && input[index + 1] == '"') {
            field.write('"');
            index++;
          } else {
            quoted = false;
            quoteClosed = true;
          }
        } else {
          field.write(char);
        }
      } else if (char == ',' || char == '\n' || char == '\r') {
        row.add(field.toString());
        field = StringBuffer();
        quoteClosed = false;
        if (char != ',') {
          rows.add(row);
          row = <String>[];
          if (char == '\r' && index + 1 < input.length && input[index + 1] == '\n') index++;
        }
      } else if (char == '"' && field.isEmpty && !quoteClosed) {
        quoted = true;
      } else {
        if (char == '"' || quoteClosed) throw const FormatException('CSV 引號結構無效。');
        field.write(char);
      }
    }
    if (quoted) throw const FormatException('CSV 引號未閉合。');
    if (field.isNotEmpty || row.isNotEmpty || quoteClosed) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  static String _errorLabel(Object error) {
    if (error is TimeoutException) return '連線逾時';
    if (error is FormatException) return '資料格式無效';
    if (error is http.ClientException && error.message.startsWith('HTTP ')) return error.message;
    return '網路或資料源不可用';
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _network.close();
  }
}
```

## test/network_request_test.dart

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:martin_luk_app/services/network_request.dart';

import 'support/controllable_http_client.dart';

void main() {
  final uri = Uri.https('example.test', '/quotes');

  test('standard browser headers are enforced for all common GET services', () async {
    final client = ControllableHttpClient((request) async {
      expect(request.headers['user-agent'], NetworkRequest.requestHeaders['User-Agent']);
      expect(request.headers['accept'], 'application/json');
      expect(request.headers['accept-language'], 'en-US,en;q=0.9');
      expect(request.headers['x-trace'], 'holdings');
      return streamedText('ok');
    });
    final network = NetworkRequest(client: client);
    addTearDown(network.close);
    final response = await network.get(uri, headers: {
      'User-Agent': 'Dart client', 'Accept': 'text/plain',
      'Accept-Language': 'fr', 'X-Trace': 'holdings',
    });
    expect(response.body, 'ok');
  });

  test('default is eight seconds and explicit timeouts cannot exceed ten seconds', () {
    final client = ControllableHttpClient((_) async => streamedText('ok'));
    for (final timeout in [Duration.zero, const Duration(milliseconds: -1),
      const Duration(seconds: 11)]) {
      expect(() => NetworkRequest(client: client, timeout: timeout),
          throwsArgumentError);
    }
    final standard = NetworkRequest(client: client);
    final extended = NetworkRequest(client: client,
        timeout: const Duration(seconds: 10));
    addTearDown(standard.close);
    addTearDown(extended.close);
    expect(standard.timeout, const Duration(seconds: 8));
    expect(extended.timeout, const Duration(seconds: 10));
    expect(NetworkRequest.defaultTimeout, const Duration(seconds: 8));
    expect(NetworkRequest.maximumTimeout, const Duration(seconds: 10));
    expect(NetworkRequest.storageTimeout, const Duration(seconds: 5));
    expect(NetworkRequest.maximumConcurrentRequests, 5);
  });

  test('null headers use browser defaults and per-call invalid timeouts never send', () async {
    final client = ControllableHttpClient((request) async {
      expect(request.headers['user-agent'], NetworkRequest.requestHeaders['User-Agent']);
      expect(request.headers['accept'], 'application/json');
      return streamedText('ok');
    });
    final network = NetworkRequest(client: client);
    addTearDown(network.close);
    expect((await network.get(uri, headers: null)).body, 'ok');
    await expectLater(network.get(uri, timeout: Duration.zero), throwsArgumentError);
    await expectLater(network.get(uri, timeout: const Duration(seconds: 11)),
        throwsArgumentError);
    expect(client.requests, hasLength(1));
    expect(network.defaultHeaders['Accept-Language'], 'en-US,en;q=0.9');
  });

  test('different transports share five permits until each response body finishes', () async {
    final bodies = <Completer<List<int>>>[];
    final waves = {for (final count in [5, 10, 12]) count: Completer<void>()};
    var sent = 0, active = 0, maximumActive = 0;
    Future<http.StreamedResponse> handle(http.BaseRequest request) async {
      active++;
      if (active > maximumActive) maximumActive = active;
      final body = Completer<List<int>>();
      bodies.add(body);
      sent++;
      waves[sent]?.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future.then((bytes) {
        active--;
        return bytes;
      })), 200);
    }

    final firstClient = ControllableHttpClient(handle);
    final secondClient = ControllableHttpClient(handle);
    final first = NetworkRequest(client: firstClient);
    final second = NetworkRequest(client: secondClient);
    addTearDown(first.close);
    addTearDown(second.close);
    final requests = List.generate(12, (index) => (index.isEven ? first : second)
        .get(uri.replace(path: '/quotes/$index')));
    for (final count in [5, 10, 12]) {
      await waves[count]!.future.timeout(const Duration(seconds: 2));
      expect(sent, count);
      expect(active, count == 12 ? 2 : 5,
          reason: 'Received headers do not release a permit for a stalled body.');
      for (final body in List<Completer<List<int>>>.of(bodies)) {
        if (!body.isCompleted) body.complete('fresh'.codeUnits);
      }
    }
    final responses = await Future.wait(requests).timeout(const Duration(seconds: 2));
    expect(responses.every((response) => response.body == 'fresh'), isTrue);
    expect(maximumActive, 5);
    expect(active, 0);
    expect(firstClient.closeCalls, 0);
    expect(secondClient.closeCalls, 0);
  });

  test('a queued request times out without sending HTTP and a later retry succeeds', () async {
    final bodies = <Completer<List<int>>>[];
    final full = Completer<void>();
    final holderClient = ControllableHttpClient((request) async {
      final body = Completer<List<int>>();
      bodies.add(body);
      if (bodies.length == NetworkRequest.maximumConcurrentRequests) full.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future), 200);
    });
    final retryClient = ControllableHttpClient((_) async => streamedText('retry'));
    final holder = NetworkRequest(client: holderClient);
    final retry = NetworkRequest(client: retryClient,
        timeout: const Duration(milliseconds: 20));
    addTearDown(holder.close);
    addTearDown(retry.close);
    final held = List.generate(NetworkRequest.maximumConcurrentRequests,
        (index) => holder.get(uri.replace(path: '/held/$index')));
    await full.future.timeout(const Duration(seconds: 2));
    await expectLater(retry.get(uri), throwsA(isA<TimeoutException>()));
    expect(retryClient.requests, isEmpty,
        reason: 'The eight-second budget includes FIFO permit queueing.');
    for (final body in bodies) { body.complete('held'.codeUnits); }
    await Future.wait(held).timeout(const Duration(seconds: 2));
    expect(retryClient.requests, isEmpty,
        reason: 'A timed-out queue entry must never be sent after a slot opens.');
    expect((await retry.get(uri)).body, 'retry');
    expect(retryClient.requests.length, 1);
  });

  test('closing a queued transport cancels its queue entry without taking another slot', () async {
    final bodies = <Completer<List<int>>>[];
    final full = Completer<void>();
    final holderClient = ControllableHttpClient((request) async {
      final body = Completer<List<int>>();
      bodies.add(body);
      if (bodies.length == NetworkRequest.maximumConcurrentRequests) full.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future), 200);
    });
    final queuedClient = ControllableHttpClient((_) async => streamedText('unexpected'));
    final holder = NetworkRequest(client: holderClient);
    final queued = NetworkRequest(client: queuedClient);
    addTearDown(holder.close);
    addTearDown(queued.close);
    final held = List.generate(NetworkRequest.maximumConcurrentRequests,
        (index) => holder.get(uri.replace(path: '/held/$index')));
    await full.future.timeout(const Duration(seconds: 2));
    final cancelled = queued.get(uri);
    final checked = expectLater(cancelled, throwsA(isA<http.RequestAbortedException>()));
    queued.close();
    await checked.timeout(const Duration(seconds: 1));
    expect(queuedClient.requests, isEmpty);
    for (final body in bodies) { body.complete('held'.codeUnits); }
    await Future.wait(held).timeout(const Duration(seconds: 2));
    expect(queuedClient.requests, isEmpty);
    expect(queuedClient.closeCalls, 0);
  });

  test('a hanging connection is aborted and the next request can succeed', () async {
    var aborts = 0;
    final never = Completer<http.StreamedResponse>();
    final client = ControllableHttpClient((request) async {
      if (aborts > 0) return streamedText('fresh');
      expect(request, isA<http.AbortableRequest>());
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborts++;
        if (!never.isCompleted) {
          never.completeError(http.RequestAbortedException(request.url));
        }
      });
      return never.future;
    });
    final transport = NetworkRequest(client: client,
        timeout: const Duration(milliseconds: 10));
    await expectLater(transport.get(uri), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(aborts, 1);
    expect((await transport.get(uri)).body, 'fresh');
    transport.close();
    expect(client.closeCalls, 0, reason: 'Caller-owned client remains reusable.');
  });

  test('headers arriving successfully cannot leave a hanging response body', () async {
    final never = Completer<List<int>>();
    var aborted = false;
    final client = ControllableHttpClient((request) async {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
        if (!never.isCompleted) never.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(never.future), 200);
    });
    final transport = NetworkRequest(client: client,
        timeout: const Duration(milliseconds: 10));
    await expectLater(transport.get(uri), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
    transport.close();
  });

  test('disposing aborts active work without closing an injected client', () async {
    final waiting = Completer<http.StreamedResponse>();
    final started = Completer<void>();
    var aborted = false;
    final client = ControllableHttpClient((request) {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
        if (!waiting.isCompleted) {
          waiting.completeError(http.RequestAbortedException(request.url));
        }
      });
      started.complete();
      return waiting.future;
    });
    final transport = NetworkRequest(client: client);
    final result = transport.get(uri);
    final expectation = expectLater(result,
        throwsA(isA<http.RequestAbortedException>()));
    await started.future;
    transport.close();
    await expectation;
    expect(aborted, isTrue);
    expect(client.closeCalls, 0);
    await expectLater(transport.get(uri), throwsStateError);
  });

  test('a late response from a timed-out client cannot change the returned result', () async {
    final late = Completer<http.StreamedResponse>();
    var calls = 0;
    final client = ControllableHttpClient((_) => ++calls == 1
        ? late.future : Future.value(streamedText('current')));
    final transport = NetworkRequest(client: client,
        timeout: const Duration(milliseconds: 10));
    await expectLater(transport.get(uri), throwsA(isA<TimeoutException>()));
    expect((await transport.get(uri)).body, 'current');
    late.complete(streamedText('obsolete'));
    await Future<void>.delayed(Duration.zero);
    expect((await transport.get(uri)).body, 'current');
    transport.close();
  });
}
```

## test/integration_scan_test.dart

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_config.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

/// Real HTTPS health gate; not a deterministic replacement for unit tests.
///
/// flutter test test/integration_scan_test.dart \
///   --dart-define=RUN_LIVE_SCAN_TEST=true --dart-define=USE_MOCK_DATA=false
///
/// Both real benchmarks and all five required stocks must pass independent
/// ADR/EMA/RS checks. Zero qualified entries is a valid market outcome; data,
/// calculation and deadline failures still fail this gate. No market data or
/// entry is fabricated, and the entry strategy's thresholds remain unchanged.
const _requiredSymbols = ['NVDA', 'AAPL', 'TSLA', '2330.TW', '2603.TW'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Initialize the storage test adapter only after Flutter's binding exists.
  // This replaces platform persistence, not the real Yahoo HTTP client.
  SharedPreferences.setMockInitialValues({});
  const runLive = bool.fromEnvironment('RUN_LIVE_SCAN_TEST', defaultValue: false);
  test('real TW/US market data and independent indicator health gate', () async {
    final elapsed = Stopwatch()..start();
    final evidence = <String, dynamic>{
      'schema_version': 2,
      'verification_mode': 'real_market_health',
      'use_mock_data': AppConfig.useMockData,
      'status': 'running',
      'started_at_utc': DateTime.now().toUtc().toIso8601String(),
      'provider': 'Yahoo Finance HTTPS chart; actual HTTP client',
      'scope': 'five required TW/US health probes, not a complete-universe recommendation scan',
      'maximum_concurrent_stock_tasks': 5,
      'inter_chunk_delay_ms': 100,
      'whole_run_deadline_seconds': 15,
      'required_symbols': _requiredSymbols,
      'benchmarks_verified': false,
      'required_symbols_verified': false,
      'indicators_verified': false,
      'candidate_count': 0,
      'recommendation_status': 'not_evaluated',
      'observations': <Map<String, dynamic>>[],
      'errors': <String, String>{},
      'candidates': <Map<String, dynamic>>[],
    };
    final output = File('build/live-scan-evidence.json');
    output.parent.createSync(recursive: true);
    _writeEvidence(output, evidence);
    final previousOverrides = HttpOverrides.current;
    MarketDataApi? api;
    final run = _LiveRun(elapsed);
    Object? failure;
    StackTrace? failureStack;
    try {
      expect(AppConfig.useMockData, isFalse,
          reason: 'Live gate requires USE_MOCK_DATA=false.');
      // Only persistent platform storage is isolated. There is no MockClient,
      // injected response, stored price, cached-success fixture or API relay.
      HttpOverrides.global = null; // Remove Flutter test binding's HTTP-400 override.
      final preferences = await run.wait(SharedPreferences.getInstance());
      api = MarketDataApi(preferences: preferences);
      await run.wait(_scan(api, run, evidence));
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Seal first: abandoned futures cannot mutate the report or publish PASS.
      run.cancel();
      api?.close();
      HttpOverrides.global = previousOverrides;
    }
    if (elapsed.elapsed > const Duration(seconds: 15)) {
      failure ??= StateError('Real scan exceeded the strict 15-second deadline.');
      failureStack ??= StackTrace.current;
    }
    _recordFilterSummary(evidence,
        evidence['observations'] as List<Map<String, dynamic>>);
    evidence['finished_at_utc'] = DateTime.now().toUtc().toIso8601String();
    evidence['elapsed_ms'] = elapsed.elapsedMilliseconds;
    evidence['status'] = failure == null ? 'passed' : 'failed';
    if (failure != null) evidence['failure'] = failure.toString();
    _writeEvidence(output, evidence);
    // Include writing the report, disposal and override restoration in the
    // whole-run deadline; a late artifact cannot be reported as a passed gate.
    elapsed.stop();
    if (elapsed.elapsed > const Duration(seconds: 15) && failure == null) {
      failure = StateError('Live scan/report cleanup exceeded 15 seconds.');
      failureStack = StackTrace.current;
      evidence['status'] = 'failed';
      evidence['failure'] = failure.toString();
      evidence['elapsed_ms'] = elapsed.elapsedMilliseconds;
      _writeEvidence(output, evidence);
    }
    stdout.writeln(jsonEncode(evidence));
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    stdout.writeln('[TEST PASSED] Real TW/US data and ADR/EMA/RS verified; '
        'qualified recommendations: ${evidence['candidate_count']}. '
        '${evidence['candidate_count'] == 0 ? 'No current qualified entry; no trade is recommended.' : jsonEncode(evidence['candidates'])}');
  }, skip: runLive ? false :
      'Explicit RUN_LIVE_SCAN_TEST=true is required; no live gate runs in offline unit tests.',
    timeout: const Timeout(Duration(seconds: 20)));
}

class _LiveRun {
  _LiveRun(this.elapsed);
  final Stopwatch elapsed;
  bool _cancelled = false;

  // Reserve 250 ms for synchronous HTTP disposal and writing diagnostics.
  Duration get remaining => const Duration(milliseconds: 14750) - elapsed.elapsed;
  bool get active => !_cancelled && remaining > Duration.zero;
  void cancel() { _cancelled = true; }
  void check() {
    if (!active) throw TimeoutException('Real market scan deadline reached.');
  }
  Future<T> wait<T>(Future<T> operation) {
    if (!active) {
      // Arguments may already have started an asynchronous operation. Observe
      // its completion even when the run expired immediately before this call.
      operation.ignore();
      check();
    }
    return operation.timeout(remaining);
  }
}

void _writeEvidence(File output, Map<String, dynamic> evidence) {
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
}

Future<void> _scan(MarketDataApi api, _LiveRun run,
    Map<String, dynamic> evidence) async {
  const engine = LiveStrategyEngine();
  final observations = evidence['observations'] as List<Map<String, dynamic>>;
  final errors = evidence['errors'] as Map<String, String>;
  final evaluations = <LiveEvaluation>[];
  final stocks = <String, StockItem>{};
  final decoded = jsonDecode(await run.wait(rootBundle.loadString('stocks_master.json')));
  if (decoded is! List) throw const FormatException('Stock dictionary is not an array.');
  for (final row in decoded) {
    final stock = StockItem.fromJson(row as Map<String, dynamic>);
    stocks[stock.symbol] = stock;
  }
  final benchmarks = <StockMarket, MarketChart>{};
  await run.wait(Future.wait(StockMarket.values.map((market) async {
    final chart = await run.wait(api.fetchBenchmark(market, forceRefresh: true));
    run.check();
    _assertRealDaily(chart, market);
    benchmarks[market] = chart;
    observations.add(_dailyEvidence(chart, engine, kind: 'benchmark'));
  })));
  expect(benchmarks.length, 2, reason: 'Both actual TWII and GSPC are required.');

  // This gate verifies actual data and calculations for a fixed sample. It
  // does not assert that a qualified trade exists, nor replace the App's scan.
  const symbols = _requiredSymbols;
  evidence['probe_symbols'] = symbols;
  for (final symbol in symbols) {
    expect(stocks.containsKey(symbol), isTrue,
        reason: 'A real dictionary identity is required for $symbol.');
  }
  Future<void> probe(String symbol) async {
    final stock = stocks[symbol]!;
    Map<String, dynamic>? currentObservation;
    try {
      final daily = await run.wait(api.fetchDaily(symbol, stock.market, forceRefresh: true));
      run.check();
      _assertRealDaily(daily, stock.market);
      final observation = _dailyEvidence(daily, engine, kind: 'stock');
      currentObservation = observation;
      observations.add(observation);
      final adr = observation['adr_20_percent'] as double;
      MarketChart? intraday;
      String? intradayError;
      if (adr >= stock.market.defaultAdr) {
        try {
          final MarketChart fetchedIntraday = await run.wait<MarketChart>(
            api.fetchIntraday(symbol, stock.market, forceRefresh: true),
          );
          run.check();
          expect(fetchedIntraday.isCached, isFalse);
          expect(fetchedIntraday.isStale, isFalse);
          observation['intraday_quote_at_utc'] =
              fetchedIntraday.quoteTimestamp.toIso8601String();
          observation['quote_in_regular_session'] =
              fetchedIntraday.quoteIsInRegularSession;
          observation['quote_fresh_15m'] =
              fetchedIntraday.isQuoteFresh(DateTime.now().toUtc());
          intraday = fetchedIntraday;
        } catch (error) {
          if (!run.active) return;
          intradayError = error.toString();
          observation['intraday_error'] = intradayError;
        }
      }
      run.check();
      final evaluation = engine.evaluate(stock: stock,
          data: ChartBundle(daily: daily, intraday: intraday, intradayError: intradayError),
          benchmark: benchmarks[stock.market]!, now: DateTime.now().toUtc());
      observation['patterns'] = evaluation.patterns;
      observation['rs_raw_excess_percent'] = evaluation.momentum;
      observation['rs_alignment_notes'] = evaluation.notes
          .where((note) => note.startsWith('RS 計算截至') || note.contains('日 K 落後'))
          .toList();
      observation['has_confirmed_observed_stop'] = evaluation.stop != null;
      _recordEvaluationEvidence(observation, evaluation, benchmarks[stock.market]!,
          DateTime.now().toUtc());
      evaluations.add(evaluation);
    } catch (error) {
      if (run.active) {
        errors[symbol] = error.toString();
        final failedObservation = currentObservation ?? <String, dynamic>{
          'kind': 'stock', 'symbol': symbol, 'market': stock.market.name,
        };
        failedObservation['evaluation_verified'] = false;
        failedObservation['evaluation_error'] = error.toString();
        failedObservation['all_rejection_reasons'] = ['DATA_OR_CALCULATION_ERROR'];
        if (currentObservation == null) observations.add(failedObservation);
      }
    }
  }

  for (var start = 0; start < symbols.length && run.active; start += 5) {
    final chunk = symbols.skip(start).take(5);
    await run.wait(Future.wait(chunk.map(probe)));
    final requiredComplete = _requiredSymbols.every((symbol) =>
        evaluations.any((row) => row.stock.symbol == symbol));
    if (requiredComplete) {
      evidence['stopped_after_required_health_checks'] = true;
      break;
    }
    if (start + 5 < symbols.length) {
      await run.wait(Future<void>.delayed(const Duration(milliseconds: 100)));
    }
  }
  run.check();
  for (final symbol in _requiredSymbols) {
    expect(evaluations.any((row) => row.stock.symbol == symbol), isTrue,
        reason: 'Required real quote/ADR/EMA/RS evaluation failed for $symbol: ${errors[symbol]}');
  }
  final qualified = <Map<String, dynamic>>[];
  // Each market ranks its own observed sample; USD and TWD are never combined.
  for (final market in StockMarket.values) {
    final ranked = engine.rank(evaluations.where((row) => row.stock.market == market).toList());
    for (final candidate in ranked) {
      final evaluation = evaluations.firstWhere((row) => row.stock.symbol == candidate.symbol);
      if (!_qualifies(evaluation) || !candidate.isConfirmed ||
          !candidate.hasValidStopRange) continue;
      _assertBreakoutEvidence(evaluation, candidate);
      final capital = market.defaultEquity;
      final plan = calculatePositionSize(capital: capital,
          entryPrice: candidate.entryPrice, stopLossPrice: candidate.stopPrice!,
          isMegaCap: candidate.isLargeLiquid);
      final targets = calculateExitTargets(candidate.entryPrice, candidate.stopPrice!);
      expect(plan.shares, greaterThan(0));
      expect(plan.riskAmount, lessThanOrEqualTo(capital * .005 + 1e-8));
      expect(plan.positionPercent,
          lessThanOrEqualTo((candidate.isLargeLiquid ? 35 : 25) + 1e-8));
      expect(plan.riskBudget, capital * .005);
      for (final r in [3, 5, 10]) {
        expect(plan.targetPrice(r), closeTo(targets.targetPrice(r), 1e-8));
        expect(targets.targetPrice(r), closeTo(candidate.entryPrice +
            r * (candidate.entryPrice - candidate.stopPrice!), 1e-8));
      }
      qualified.add({
        ...candidate.toJson(),
        'account_capital': capital, 'account_currency': market.currency,
        'risk_budget': plan.riskBudget, 'actual_stop_risk': plan.riskAmount,
        'shares': plan.shares, 'position_percent': plan.positionPercent,
        'target_3r': targets.targetPrice(3), 'target_5r': targets.targetPrice(5),
        'target_10r': targets.targetPrice(10),
        'intraday_source': evaluation.data.intraday!.source,
        'intraday_is_cached': false, 'intraday_is_stale': false,
      });
    }
  }
  evidence['candidates'] = qualified;
  evidence['evaluated_count'] = evaluations.length;
  evidence['candidate_count'] = qualified.length;
  evidence['recommendation_status'] = qualified.isEmpty
      ? 'no_qualified_entry' : 'qualified_entries';
  _recordFilterSummary(evidence, observations);
  run.check();
  // Set verification flags only after both benchmark checks, every required
  // symbol's independent indicator checks and any actual entry assertions.
  evidence['benchmarks_verified'] = true;
  evidence['required_symbols_verified'] = true;
  evidence['indicators_verified'] = true;
}

bool _qualifies(LiveEvaluation row) {
  final stop = row.stop;
  if (stop == null || row.adr < row.stock.market.defaultAdr ||
      !row.patterns.contains('EMA 9/21/50 收斂') ||
      !row.patterns.contains('${row.triggerType} 突破')) return false;
  final risk = (row.trigger - stop) / row.trigger * 100;
  return risk >= 1.5 && risk <= 3;
}

void _assertRealDaily(MarketChart chart, StockMarket market) {
  expect(chart.market, market);
  expect(chart.currency, market.currency);
  expect(chart.isCached, isFalse);
  expect(chart.isStale, isFalse);
  expect(chart.cacheWarning, isNull);
  expect(chart.latestPrice.isFinite, isTrue);
  expect(chart.latestPrice, greaterThan(0));
  expect(chart.completedDailyBars.length, greaterThanOrEqualTo(61));
  expect(chart.source, contains('Yahoo Finance'));
  expect(RegExp(r'mock|fictitious|demo|示範|假', caseSensitive: false)
      .hasMatch(chart.source), isFalse);
  final now = DateTime.now().toUtc();
  expect(chart.quoteTimestamp.isAfter(now), isFalse);
  expect(now.difference(chart.quoteTimestamp), lessThan(const Duration(days: 7)),
      reason: 'Latest available daily quote must not be an obsolete observation.');
}

Map<String, dynamic> _dailyEvidence(MarketChart chart, LiveStrategyEngine engine,
    {required String kind}) {
  final bars = chart.completedDailyBars;
  final closes = bars.map((bar) => bar.close).toList();
  final adr = engine.adrPercent(bars);
  final manualAdr = bars.skip(bars.length - 20)
      .fold<double>(0, (sum, bar) => sum + (bar.high - bar.low) / bar.low * 100) / 20;
  expect(adr.isFinite, isTrue);
  expect(adr, greaterThanOrEqualTo(0));
  expect(adr, closeTo(manualAdr, 1e-9));
  final ema9 = engine.ema(closes, 9), ema21 = engine.ema(closes, 21), ema50 = engine.ema(closes, 50);
  final independentEmas = [for (final period in [9, 21, 50]) _independentEma(closes, period)];
  final actualEmas = [ema9, ema21, ema50];
  for (var index = 0; index < actualEmas.length; index++) {
    final ema = actualEmas[index];
    expect(ema.isFinite, isTrue);
    expect(ema, greaterThan(0));
    expect(ema, closeTo(independentEmas[index], math.max(1.0, ema.abs()) * 1e-10),
        reason: 'EMA ${[9, 21, 50][index]} differs from the independent weighted-sum formula.');
  }
  return {
    'kind': kind, 'symbol': chart.symbol, 'market': chart.market.name,
    'currency': chart.currency, 'provider_price': chart.latestPrice,
    'provider_quote_at_utc': chart.quoteTimestamp.toIso8601String(),
    'request_finished_at_utc': chart.fetchedAt.toIso8601String(),
    'completed_daily_bars': bars.length, 'adr_20_percent': adr,
    'adr_threshold': chart.market.defaultAdr,
    'adr_pass': adr >= chart.market.defaultAdr,
    'daily_indicators_verified': true,
    'independent_adr_20_percent': manualAdr,
    'last_raw_session_date': chart.localSessionDate(chart.bars.last.timestamp)
        .toIso8601String().substring(0, 10),
    'last_completed_session_date': chart.localSessionDate(bars.last.timestamp)
        .toIso8601String().substring(0, 10),
    'regular_session_start_utc': chart.regularSessionStart?.toIso8601String(),
    'regular_session_end_utc': chart.regularSessionEnd?.toIso8601String(),
    'ema_9': ema9, 'ema_21': ema21, 'ema_50': ema50,
    'independent_ema_9': independentEmas[0],
    'independent_ema_21': independentEmas[1],
    'independent_ema_50': independentEmas[2],
    'source': chart.source, 'is_cached': chart.isCached, 'is_stale': chart.isStale,
  };
}

/// Closed-form weighted sum, separate from the production iterative EMA.
double _independentEma(List<double> closes, int period) {
  final alpha = 2 / (period + 1);
  final decay = 1 - alpha;
  final seed = closes.take(period).fold<double>(0, (sum, close) => sum + close) / period;
  var result = seed * math.pow(decay, closes.length - period).toDouble();
  for (var index = period; index < closes.length; index++) {
    result += alpha * closes[index] * math.pow(decay, closes.length - index - 1).toDouble();
  }
  return result;
}

Map<String, dynamic> _independentRs(MarketChart stock, MarketChart benchmark) {
  String date(MarketChart chart, PriceBar bar) =>
      chart.localSessionDate(bar.timestamp).toIso8601String().substring(0, 10);
  final stockPrices = {for (final bar in stock.completedDailyBars) date(stock, bar): bar.close};
  final indexPrices = {for (final bar in benchmark.completedDailyBars) date(benchmark, bar): bar.close};
  final common = stockPrices.keys.where(indexPrices.containsKey).toList()..sort();
  expect(common.length, greaterThanOrEqualTo(61));
  final latest = common.last;
  double returnOf(Map<String, double> prices, int period) =>
      (prices[latest]! - prices[common[common.length - 1 - period]]!) /
      prices[common[common.length - 1 - period]]!;
  final score = ((returnOf(stockPrices, 20) - returnOf(indexPrices, 20)) +
      (returnOf(stockPrices, 60) - returnOf(indexPrices, 60))) * 50;
  return {
    'rs_as_of_session_date': latest,
    'rs_common_completed_sessions': common.length,
    'rs_stock_tail_sessions': stockPrices.keys.where((key) => key.compareTo(latest) > 0).length,
    'rs_benchmark_tail_sessions': indexPrices.keys.where((key) => key.compareTo(latest) > 0).length,
    'independent_rs_raw_excess_percent': score,
  };
}

List<PriceBar> _completedRegularBars(MarketChart chart) =>
    chart.regularSessionBars.where((bar) =>
        !bar.closeTimestamp.isAfter(chart.quoteTimestamp)).toList();

void _recordEvaluationEvidence(Map<String, dynamic> observation,
    LiveEvaluation evaluation, MarketChart benchmark, DateTime now) {
  final daily = evaluation.data.daily;
  final independentRs = _independentRs(daily, benchmark);
  expect(evaluation.momentum,
      closeTo(independentRs['independent_rs_raw_excess_percent'] as double, 1e-8),
      reason: 'RS differs from independent 20/60-day common-date return calculations.');
  observation.addAll(independentRs);
  final bars = daily.completedDailyBars;
  final prior = bars.last, earlier = bars[bars.length - 2];
  final closes = bars.map((bar) => bar.close).toList();
  final emas = [evaluation.ema9, evaluation.ema21, evaluation.ema50];
  final std7 = _standardDeviation(closes.sublist(closes.length - 7));
  final std20 = _standardDeviation(closes.sublist(closes.length - 20));
  final averageRange = bars.skip(bars.length - 20)
      .fold<double>(0, (sum, bar) => sum + bar.high - bar.low) / 20;
  final intraday = evaluation.data.intraday;
  // The closure receives a non-null chart parameter; never capture a nullable
  // local whose promotion could be invalidated by future edits.
  final regular = intraday == null ? <PriceBar>[] : _completedRegularBars(intraday);
  final first = regular.isEmpty ? null : regular.first;
  final sessionStart = intraday?.regularSessionStart;
  final sessionEnd = intraday?.regularSessionEnd;
  MarketChart? marketSessionChart;
  String? marketSessionSource;
  for (final entry in {'intraday': intraday, 'daily': daily, 'benchmark': benchmark}.entries) {
    final chart = entry.value;
    if (chart != null && chart.regularSessionStart != null && chart.regularSessionEnd != null) {
      marketSessionChart = chart;
      marketSessionSource = entry.key;
      break;
    }
  }
  final marketSessionStart = marketSessionChart?.regularSessionStart;
  final marketSessionEnd = marketSessionChart?.regularSessionEnd;
  final sessionMinutes = sessionStart != null && sessionEnd != null
      ? sessionEnd.difference(sessionStart).inMinutes : 0;
  final elapsedMinutes = sessionStart != null && regular.isNotEmpty
      ? regular.last.closeTimestamp.difference(sessionStart).inMinutes : 0;
  final averageVolume = bars.skip(bars.length - 20)
      .fold<double>(0, (sum, bar) => sum + bar.volume) / 20;
  final expectedVolume = sessionMinutes > 0 ? averageVolume * elapsedMinutes / sessionMinutes : 0.0;
  final observedVolume = regular.fold<double>(0, (sum, bar) => sum + bar.volume);
  final stop = evaluation.stop;
  final risk = stop == null ? null : (evaluation.trigger - stop) / evaluation.trigger * 100;
  final adrPass = evaluation.adr >= evaluation.stock.market.defaultAdr;
  final emaPass = evaluation.patterns.contains('EMA 9/21/50 收斂');
  final fresh = intraday?.isQuoteFresh(now) ?? false;
  final quoteInSession = intraday?.quoteIsInRegularSession ?? false;
  final reasons = <String>[];
  if (!adrPass) reasons.add('ADR_BELOW_THRESHOLD');
  if (!emaPass) reasons.add('EMA_NOT_COMPRESSED');
  if (intraday == null) {
    reasons.add(!adrPass ? 'INTRADAY_NOT_REQUESTED_ADR_FILTER' : 'INTRADAY_UNAVAILABLE');
  } else {
    if (!fresh) reasons.add('QUOTE_STALE_OR_CACHED');
    if (!quoteInSession) reasons.add('QUOTE_OUTSIDE_REGULAR_SESSION');
    if (first == null || first.timestamp != sessionStart) reasons.add('OPENING_CANDLE_UNAVAILABLE');
  }
  if (evaluation.notes.any((note) => note.contains('日 K 落後'))) {
    reasons.add('STOCK_DAILY_HISTORY_LAG');
  }
  if (evaluation.confirmation == null) reasons.add('NO_OBSERVED_BREAKOUT');
  if (stop == null) reasons.add('NO_VALID_INITIAL_STOP');
  if (risk != null && (risk < 1.5 || risk > 3)) reasons.add('STOP_DISTANCE_OUTSIDE_1_5_TO_3_PERCENT');
  observation.addAll({
    'evaluation_verified': true, 'rs_verified': true,
    'notes': evaluation.notes, 'ema_compression_pass': emaPass,
    'ema_spread_fraction': (emas.reduce(math.max) - emas.reduce(math.min)) / prior.close,
    'std_7': std7, 'std_20': std20, 'volatility_shrinking': std7 <= std20 * .8,
    'prior_close_above_emas': prior.close >= emas.reduce(math.max),
    'prior_inside_day': prior.high <= earlier.high && prior.low >= earlier.low,
    'prior_narrow_range': prior.high - prior.low <= averageRange * .6,
    'intraday_received': intraday != null,
    'intraday_error': evaluation.data.intradayError,
    'evaluation_time_utc': now.toIso8601String(),
    'intraday_regular_session_start_utc': sessionStart?.toIso8601String(),
    'intraday_regular_session_end_utc': sessionEnd?.toIso8601String(),
    'market_session_start_utc': marketSessionStart?.toIso8601String(),
    'market_session_end_utc': marketSessionEnd?.toIso8601String(),
    'market_session_source': marketSessionSource,
    'market_session_symbol': marketSessionChart?.symbol,
    'market_now_in_regular_session': marketSessionStart == null || marketSessionEnd == null
        ? null : !now.isBefore(marketSessionStart) && now.isBefore(marketSessionEnd),
    'quote_in_regular_session': quoteInSession, 'quote_fresh_15m': fresh,
    'quote_age_seconds': intraday == null ? null : now.difference(intraday.quoteTimestamp).inSeconds,
    'regular_completed_bars': regular.length,
    'opening_candle_complete': first != null && first.timestamp == sessionStart,
    'opening_gap_percent': first == null ? null : (first.open / prior.close - 1) * 100,
    'observed_session_volume': observedVolume, 'expected_session_volume': expectedVolume,
    'session_volume_ratio': expectedVolume > 0 ? observedVolume / expectedVolume : null,
    'trigger_type': evaluation.triggerType, 'trigger_price': evaluation.trigger,
    'stop_price': stop, 'stop_source': evaluation.stopSource,
    'stop_risk_percent': risk, 'strict_stop_range_pass': risk != null && risk >= 1.5 && risk <= 3,
    'signal_time_utc': evaluation.signalTime?.toIso8601String(),
    'signal_age_seconds': evaluation.signalTime == null ? null : now.difference(evaluation.signalTime!).inSeconds,
    'observed_confirmation_price': evaluation.confirmation,
    'latest_available_price': (intraday ?? daily).latestPrice,
    'recommendation_qualified': _qualifies(evaluation),
    'all_rejection_reasons': reasons,
    'primary_rejection_reason': reasons.isEmpty ? null : reasons.first,
  });
}

void _recordFilterSummary(Map<String, dynamic> evidence,
    List<Map<String, dynamic>> observations) {
  final stocks = observations.where((row) => row['kind'] == 'stock').toList();
  int count(String field) => stocks.where((row) => row[field] == true).length;
  final rejections = <String, int>{};
  for (final stock in stocks) {
    final reasons = stock['all_rejection_reasons'];
    if (reasons is List) {
      for (final reason in reasons.whereType<String>().toSet()) {
        rejections.update(reason, (value) => value + 1, ifAbsent: () => 1);
      }
    }
  }
  evidence['rejection_counts'] = rejections;
  evidence['filter_counts'] = {
    'observed_stocks': stocks.length,
    'daily_indicators_verified': count('daily_indicators_verified'),
    'evaluations_verified': count('evaluation_verified'),
    'adr_pass': count('adr_pass'), 'ema_compression_pass': count('ema_compression_pass'),
    'intraday_received': count('intraday_received'),
    'current_market_open': count('market_now_in_regular_session'),
    'market_session_unknown': stocks.where((row) => row['market_now_in_regular_session'] == null).length,
    'fresh_quote': count('quote_fresh_15m'),
    'quote_regular_session': count('quote_in_regular_session'),
    'observed_breakout': count('has_confirmed_observed_stop'),
    'strict_stop_range_pass': count('strict_stop_range_pass'),
    'qualified': count('recommendation_qualified'),
  };
}

void _assertBreakoutEvidence(LiveEvaluation evaluation, StockCandidate candidate) {
  final intraday = evaluation.data.intraday!;
  final daily = evaluation.data.daily.completedDailyBars;
  final closes = daily.map((bar) => bar.close).toList();
  final emas = [evaluation.ema9, evaluation.ema21, evaluation.ema50];
  expect((emas.reduce(math.max) - emas.reduce(math.min)) / daily.last.close,
      lessThanOrEqualTo(.025));
  expect(daily.last.close, greaterThanOrEqualTo(emas.reduce(math.max)));
  expect(_standardDeviation(closes.sublist(closes.length - 7)),
      lessThanOrEqualTo(_standardDeviation(closes.sublist(closes.length - 20)) * .8));
  expect(intraday.quoteIsInRegularSession, isTrue);
  expect(intraday.isQuoteFresh(DateTime.now().toUtc()), isTrue);
  expect(candidate.patterns, contains('${candidate.triggerType} 突破'));
  final regular = intraday.regularSessionBars.where((bar) =>
      !bar.closeTimestamp.isAfter(intraday.quoteTimestamp)).toList();
  expect(regular, isNotEmpty);
  expect(regular.first.timestamp, intraday.regularSessionStart);
  final i = regular.indexWhere((bar) => bar.closeTimestamp == candidate.signalTimestamp);
  expect(i, greaterThanOrEqualTo(0));
  final breakout = regular[i];
  final before = i == 0 ? breakout.open : regular[i - 1].close;
  expect(before, lessThanOrEqualTo(candidate.triggerPrice));
  expect(breakout.close, greaterThan(candidate.triggerPrice));
  expect(candidate.confirmationPrice, breakout.close);
  for (var cursor = 1; cursor <= i; cursor++) {
    expect(regular[cursor].timestamp, regular[cursor - 1].closeTimestamp);
  }
  final observedLow = regular.take(i + 1).map((bar) => bar.low).reduce(math.min);
  expect(candidate.dayLow, observedLow);
  expect(candidate.entryBarLow, breakout.low);
  if (candidate.triggerType == 'PDH') {
    expect(candidate.triggerPrice, evaluation.data.daily.completedDailyBars.last.high);
    final prior = daily.last, earlier = daily[daily.length - 2];
    final averageRange = daily.skip(daily.length - 20)
        .fold<double>(0, (sum, bar) => sum + bar.high - bar.low) / 20;
    expect((prior.high <= earlier.high && prior.low >= earlier.low) ||
        prior.high - prior.low <= averageRange * .6, isTrue,
        reason: 'PDH entry requires a real inside day or a narrow prior range.');
  } else {
    expect(candidate.triggerType, 'ORH');
    expect(i, greaterThan(0));
    expect(candidate.triggerPrice, regular.first.high);
    final previousClose = daily.last.close;
    final averageVolume = daily.skip(daily.length - 20)
        .fold<double>(0, (sum, bar) => sum + bar.volume) / 20;
    final sessionMinutes = intraday.regularSessionEnd!
        .difference(intraday.regularSessionStart!).inMinutes;
    final elapsedMinutes = breakout.closeTimestamp
        .difference(intraday.regularSessionStart!).inMinutes;
    final expectedVolume = averageVolume * elapsedMinutes / sessionMinutes;
    final observedVolume = regular.take(i + 1)
        .fold<double>(0, (sum, bar) => sum + bar.volume);
    expect((regular.first.open / previousClose - 1) * 100,
        greaterThanOrEqualTo(2));
    expect(expectedVolume, greaterThan(0));
    expect(observedVolume, greaterThanOrEqualTo(expectedVolume * 1.5));
  }
  expect(candidate.stopPrice, candidate.stopSource == 'day_low' ? observedLow : breakout.low);
}

double _standardDeviation(List<double> values) {
  final mean = values.fold<double>(0, (sum, value) => sum + value) / values.length;
  final variance = values.fold<double>(0,
      (sum, value) => sum + (value - mean) * (value - mean)) / values.length;
  return math.sqrt(variance);
}
```

## lib/models/market_data.dart

```dart
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import 'stock_candidate.dart';

/// One unadjusted provider OHLCV candle. The timestamp is its start, not the
/// time our phone downloaded it. Prices from a candle must use one price basis.
class PriceBar {
  PriceBar({
    required DateTime timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    this.interval = const Duration(days: 1),
  }) : timestamp = timestamp.toUtc() {
    if ([open, high, low, close].any((value) => !value.isFinite || value <= 0) ||
        !volume.isFinite || volume < 0 || high < low ||
        high < open || high < close || low > open || low > close ||
        interval <= Duration.zero) {
      throw const FormatException('OHLCV 價格、成交量或 K 棒週期無效。');
    }
  }

  final DateTime timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final Duration interval;
  DateTime get closeTimestamp => timestamp.add(interval);
}

/// Actual provider data plus delivery provenance. A successful HTTP request is
/// not evidence that the exchange quote itself is current or a candle closed.
class MarketChart {
  MarketChart({
    required this.symbol,
    required this.market,
    required this.currency,
    required this.exchangeTimezoneName,
    required this.gmtoffset,
    required List<PriceBar> bars,
    required this.latestPrice,
    required DateTime quoteTimestamp,
    required DateTime fetchedAt,
    required this.interval,
    DateTime? regularSessionStart,
    DateTime? regularSessionEnd,
    this.isCached = false,
    this.isStale = false,
    this.cacheWarning,
    this.source = 'Yahoo Finance 公開行情（可能延遲，不保證即時）',
  }) : bars = List.unmodifiable(bars),
       quoteTimestamp = quoteTimestamp.toUtc(),
       fetchedAt = fetchedAt.toUtc(),
       regularSessionStart = regularSessionStart?.toUtc(),
       regularSessionEnd = regularSessionEnd?.toUtc() {
    if (symbol.trim().isEmpty || currency != market.currency ||
        exchangeTimezoneName.isEmpty || !latestPrice.isFinite ||
        latestPrice <= 0 || bars.isEmpty || !['1d', '1m', '5m'].contains(interval) ||
        (this.regularSessionStart == null) != (this.regularSessionEnd == null) ||
        (this.regularSessionStart != null &&
            !this.regularSessionEnd!.isAfter(this.regularSessionStart!))) {
      throw const FormatException('股票、幣別、交易時段或行情資料無效。');
    }
    _location(exchangeTimezoneName);
    for (var index = 1; index < this.bars.length; index++) {
      if (!this.bars[index].timestamp.isAfter(this.bars[index - 1].timestamp)) {
        throw const FormatException('K 棒時間必須嚴格遞增，不得重複。');
      }
    }
  }

  final String symbol;
  final StockMarket market;
  final String currency;
  final String exchangeTimezoneName;
  final int gmtoffset;
  final List<PriceBar> bars;
  final double latestPrice;
  final DateTime quoteTimestamp;
  final DateTime fetchedAt;
  final String interval;
  final DateTime? regularSessionStart;
  final DateTime? regularSessionEnd;
  final bool isCached;
  final bool isStale;
  final String? cacheWarning;
  final String source;

  /// A date-only value in the exchange's IANA timezone, including US DST.
  DateTime localSessionDate(DateTime timestamp) {
    final local = tz.TZDateTime.from(timestamp.toUtc(), _location(exchangeTimezoneName));
    return DateTime.utc(local.year, local.month, local.day);
  }

  /// A current daily candle remains provisional until 15 minutes after the
  /// provider's regular-session end. Older days are finalized. If the provider
  /// omitted session metadata, today's daily bar is conservatively excluded.
  List<PriceBar> get completedDailyBars {
    if (interval != '1d') return const [];
    final today = localSessionDate(fetchedAt);
    final sessionStart = regularSessionStart;
    final sessionEnd = regularSessionEnd;
    final sessionDate = sessionStart == null ? null : localSessionDate(sessionStart);
    return List.unmodifiable(bars.where((bar) {
      final date = localSessionDate(bar.timestamp);
      if (sessionDate != null && date == sessionDate) {
        return sessionEnd != null &&
            !fetchedAt.isBefore(sessionEnd.add(const Duration(minutes: 15))) &&
            !quoteTimestamp.isBefore(sessionEnd.subtract(const Duration(minutes: 1)));
      }
      if (date.isBefore(today)) return true;
      if (date != today || sessionDate == null) return false;
      // Yahoo can roll currentTradingPeriod to tomorrow before changing the
      // daily history. Today's completed candle still needs a consistent close
      // test; simply comparing its date with fetchedAt would discard it.
      // The normal exchange close is conservative on early-close sessions.
      final close = dailyCloseTimestamp(bar);
      return !fetchedAt.isBefore(close.add(const Duration(minutes: 15))) &&
          !quoteTimestamp.isBefore(close.subtract(const Duration(minutes: 1)));
    }));
  }

  /// Extended-hours bars never form the regular opening range.
  List<PriceBar> get regularSessionBars {
    final start = regularSessionStart;
    final end = regularSessionEnd;
    if (interval == '1d' || start == null || end == null) return const [];
    return List.unmodifiable(bars.where((bar) =>
        !bar.timestamp.isBefore(start) && bar.timestamp.isBefore(end)));
  }

  bool get quoteIsInRegularSession => regularSessionStart != null &&
      !quoteTimestamp.isBefore(regularSessionStart!) &&
      quoteTimestamp.isBefore(regularSessionEnd!);

  /// A daily bar starts at the open; adding 24 hours would produce the wrong
  /// close date and US daylight-saving offset. Use the exchange's wall clock.
  DateTime dailyCloseTimestamp(PriceBar bar) {
    final date = localSessionDate(bar.timestamp);
    if (regularSessionStart != null && regularSessionEnd != null &&
        date == localSessionDate(regularSessionStart!)) {
      return regularSessionEnd!;
    }
    return tz.TZDateTime(_location(exchangeTimezoneName),
        date.year, date.month, date.day, market == StockMarket.tw ? 13 : 16,
        market == StockMarket.tw ? 30 : 0).toUtc();
  }

  bool isQuoteFresh(DateTime now, {Duration maxAge = const Duration(minutes: 15)}) {
    final age = now.toUtc().difference(quoteTimestamp);
    return !age.isNegative && age <= maxAge && !isStale && cacheWarning == null;
  }
}

class ChartBundle {
  const ChartBundle({required this.daily, this.intraday, this.intradayError});
  final MarketChart daily;
  final MarketChart? intraday;
  final String? intradayError;
}

bool _zonesInitialized = false;
tz.Location _location(String name) {
  if (!_zonesInitialized) {
    timezone_data.initializeTimeZones();
    _zonesInitialized = true;
  }
  try {
    return tz.getLocation(name);
  } catch (_) {
    throw FormatException('行情供應商提供了未知交易所時區：$name');
  }
}
```

## lib/services/live_strategy_engine.dart

```dart
import 'dart:math' as math;

import '../models/market_data.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'strategy_engine.dart' show PositionPlan;

export 'strategy_engine.dart' show PositionPlan;

/// Pure sizing for a user-supplied entry/stop pair. This function does not
/// establish that a breakout occurred: the market scanner supplies that proof.
/// Only an observed stop 1.5%–3% below entry is accepted; no replacement stop is
/// invented. Risk is exactly 0.5% of capital before fees/slippage/gap losses.
PositionPlan calculatePositionSize({required double capital,
    required double entryPrice, required double stopLossPrice,
    required bool isMegaCap}) => _calculatePositionSize(capital: capital,
      entryPrice: entryPrice, stopLossPrice: stopLossPrice, isMegaCap: isMegaCap);

/// Immutable prices derived from the original entry/stop risk, even if an
/// existing holding subsequently raises its trailing stop to breakeven.
class ExitTargets {
  ExitTargets({required this.oneR, required Map<int, double> targets})
      : targets = Map<int, double>.unmodifiable(targets);
  final double oneR;
  final Map<int, double> targets;
  double targetPrice(int multiple) {
    final price = targets[multiple];
    if (price == null) throw ArgumentError('僅支援 3R、5R、10R 目標。');
    return price;
  }
}

/// Target math accepts any finite positive initial stop below entry. The
/// stricter 1.5%–3% rule belongs to new-position sizing, not historical R math.
ExitTargets calculateExitTargets(double entryPrice, double stopLossPrice) =>
    _calculateExitTargets(entryPrice, stopLossPrice);

/// Calculations consume provider candles only. No synthetic quote, stop or
/// ranking is substituted when history/session metadata is missing.
class LiveStrategyEngine {
  const LiveStrategyEngine();

  static PositionPlan calculatePositionSize({required double capital,
      required double entryPrice, required double stopLossPrice,
      required bool isMegaCap}) => _calculatePositionSize(capital: capital,
        entryPrice: entryPrice, stopLossPrice: stopLossPrice, isMegaCap: isMegaCap);

  static ExitTargets calculateExitTargets(double entryPrice, double stopLossPrice) =>
      _calculateExitTargets(entryPrice, stopLossPrice);

  double adrPercent(List<PriceBar> bars, {int period = 20}) {
    if (period < 1 || bars.length < period) {
      throw const FormatException('ADR 所需完整日 K 不足。');
    }
    return bars.skip(bars.length - period)
        .map((bar) => (bar.high - bar.low) / bar.low * 100)
        .reduce((a, b) => a + b) / period;
  }

  /// SMA seed avoids pretending one initial close is a fully formed EMA.
  double ema(List<double> closes, int period) {
    if (period < 1 || closes.length < period ||
        closes.any((value) => !value.isFinite || value <= 0)) {
      throw const FormatException('EMA 所需完整收盤資料不足或無效。');
    }
    var value = closes.take(period).reduce((a, b) => a + b) / period;
    final alpha = 2 / (period + 1);
    for (final close in closes.skip(period)) {
      value = alpha * close + (1 - alpha) * value;
    }
    return value;
  }

  /// Pair both returns on the same completed exchange dates. A provider may
  /// publish one tail session earlier than its peer; never mix their endpoints.
  /// The callback discloses the actual RS date and excluded tail sessions.
  double relativeMomentum(MarketChart stock, MarketChart benchmark, {
    void Function(DateTime asOf, int stockTail, int benchmarkTail)? onAligned,
  }) {
    if (stock.market != benchmark.market || stock.currency != benchmark.currency ||
        stock.interval != '1d' || benchmark.interval != '1d') {
      throw const FormatException('RS 必須使用同市場、同幣別的日 K。');
    }
    final stockByDate = <DateTime, PriceBar>{
      for (final bar in stock.completedDailyBars)
        stock.localSessionDate(bar.timestamp): bar,
    };
    final benchmarkByDate = <DateTime, PriceBar>{
      for (final bar in benchmark.completedDailyBars)
        benchmark.localSessionDate(bar.timestamp): bar,
    };
    final common = stockByDate.keys.where(benchmarkByDate.containsKey).toList()
      ..sort();
    if (common.length < 61) {
      throw const FormatException('RS 需要股票與指數至少 61 個共同完整交易日。');
    }
    final asOf = common.last;
    final stockDates = stockByDate.keys.toList()..sort();
    final benchmarkDates = benchmarkByDate.keys.toList()..sort();
    final stockTail = stockDates.where((date) => date.isAfter(asOf)).length;
    final benchmarkTail = benchmarkDates.where((date) => date.isAfter(asOf)).length;
    String day(DateTime date) => date.toIso8601String().substring(0, 10);
    final context = '${stock.symbol}=${day(stockDates.last)}，'
        '${benchmark.symbol}=${day(benchmarkDates.last)}，共同截至 ${day(asOf)}';
    // Bound publication lag; a common date alone must not legitimize old data.
    final stockAge = stock.localSessionDate(stock.fetchedAt).difference(asOf);
    final benchmarkAge = benchmark.localSessionDate(benchmark.fetchedAt).difference(asOf);
    if (stockTail > 1 || benchmarkTail > 1 || stockAge.isNegative ||
        benchmarkAge.isNegative || stockAge > const Duration(days: 7) ||
        benchmarkAge > const Duration(days: 7)) {
      throw FormatException('RS 資料落差超過一個已知交易日或共同資料已過期：$context');
    }
    double excess(int sessions) {
      final first = common[common.length - 1 - sessions];
      return (stockByDate[asOf]!.close / stockByDate[first]!.close - 1) -
          (benchmarkByDate[asOf]!.close / benchmarkByDate[first]!.close - 1);
    }
    final score = (excess(20) + excess(60)) / 2 * 100;
    if (!score.isFinite) throw const FormatException('RS 計算結果不是有限數值。');
    onAligned?.call(asOf, stockTail, benchmarkTail);
    return score;
  }

  LiveEvaluation evaluate({required StockItem stock, required ChartBundle data,
      required MarketChart benchmark, required DateTime now}) {
    final bars = data.daily.completedDailyBars;
    final closes = bars.map((bar) => bar.close).toList();
    if (bars.length < 61) {
      throw const FormatException('策略至少需要 61 根完整日 K。');
    }
    final averageRange = bars.skip(bars.length - 20)
        .map((bar) => bar.high - bar.low).reduce((a, b) => a + b) / 20;
    final prior = bars.last;
    final earlier = bars[bars.length - 2];
    final ema9 = ema(closes, 9), ema21 = ema(closes, 21), ema50 = ema(closes, 50);
    final spread = ([ema9, ema21, ema50].reduce(math.max) -
        [ema9, ema21, ema50].reduce(math.min)) / prior.close;
    final shrinking = _std(closes.sublist(closes.length - 7)) <=
        _std(closes.sublist(closes.length - 20)) * .8;
    final compressed = spread <= .025 && shrinking && prior.close >= ema9 &&
        prior.close >= ema21 && prior.close >= ema50;
    final inside = prior.high <= earlier.high && prior.low >= earlier.low;
    final narrow = prior.high - prior.low <= averageRange * .6;
    final notes = <String>[
      '日 EMA 與 ADR 僅使用已完成日 K；Yahoo 公開報價可能延遲。',
      'RS 百分位以本次成功取得且對齊交易日的股票池計算。',
    ];
    var stockDailyBehindBenchmark = false;
    final momentum = relativeMomentum(data.daily, benchmark,
      onAligned: (asOf, stockTail, benchmarkTail) {
        notes.add('RS 計算截至 ${asOf.toIso8601String().substring(0, 10)}；'
            '股票未納入尾端 $stockTail 日，大盤未納入尾端 $benchmarkTail 日。');
        stockDailyBehindBenchmark = benchmarkTail > 0;
        if (stockDailyBehindBenchmark) {
          notes.add('股票完整日 K 落後大盤，僅列觀察；補齊日 K 後才確認新突破。');
        }
      });
    final patterns = <String>[];
    if (compressed) patterns.add('EMA 9/21/50 收斂');
    if (inside) patterns.add('內包日');
    if (narrow) patterns.add('窄幅整理');
    final intraday = data.intraday;
    var trigger = prior.high;
    String? triggerType = 'PDH';
    double? stop, dayLow, entryBarLow, confirmation;
    String? stopSource;
    DateTime? signalTime;
    if (data.intradayError != null) notes.add(data.intradayError!);
    if (data.daily.isStale || intraday?.isStale == true || benchmark.isStale) {
      notes.add('行情為過期快取，僅供觀察，不建立新進場確認。');
    }
    if (intraday != null && intraday.regularSessionStart != null &&
        intraday.quoteTimestamp.isBefore(intraday.regularSessionStart!) &&
        intraday.localSessionDate(intraday.quoteTimestamp) ==
            intraday.localSessionDate(intraday.regularSessionStart!) &&
        intraday.isQuoteFresh(now)) {
      final premarketGap = (intraday.latestPrice / prior.close - 1) * 100;
      if (premarketGap >= 2) {
        patterns.add('盤前跳空 ${premarketGap.toStringAsFixed(2)}%（待開盤量能確認）');
        notes.add('盤前報價僅列跳空觀察；ORH 必須等實際開盤區間完成，PDH 是目前參考界線。');
      }
    }
    if (intraday != null && !stockDailyBehindBenchmark &&
        !benchmark.isStale && !data.daily.isStale && !intraday.isStale &&
        intraday.quoteIsInRegularSession && intraday.isQuoteFresh(now)) {
      final regular = intraday.regularSessionBars.where((bar) =>
          !bar.closeTimestamp.isAfter(intraday.quoteTimestamp)).toList();
      // ORH exists only if the actual first regular-session 5-minute candle is
      // present and complete. A delayed/missing opening candle is not replaced.
      final first = regular.isEmpty ? null : regular.first;
      final openingComplete = first != null &&
          first.timestamp == intraday.regularSessionStart;
      final gap = first == null ? 0.0 : (first.open / prior.close - 1) * 100;
      final averageVolume = bars.skip(bars.length - 20)
          .map((bar) => bar.volume).reduce((a, b) => a + b) / 20;
      final sessionMinutes = intraday.regularSessionEnd == null ? 0 :
          intraday.regularSessionEnd!.difference(intraday.regularSessionStart!).inMinutes;
      final elapsed = regular.isEmpty || intraday.regularSessionStart == null ? 0 :
          regular.last.closeTimestamp.difference(intraday.regularSessionStart!).inMinutes;
      final cumulativeVolume = regular.fold<double>(0, (sum, bar) => sum + bar.volume);
      final expectedVolume = sessionMinutes > 0 ? averageVolume * elapsed / sessionMinutes : 0;
      final exceptionalVolume = expectedVolume > 0 && cumulativeVolume >= expectedVolume * 1.5;
      final ep = openingComplete && gap >= 2 && exceptionalVolume;
      if (gap >= 2) patterns.add('開盤跳空 ${gap.toStringAsFixed(2)}%');
      if (ep) patterns.add('Episodic Pivot 量增');
      final openingHigh = first?.high;
      PriceBar? breakout;
      var volumeThroughBar = 0.0;
      for (var i = 0; i < regular.length; i++) {
        final bar = regular[i];
        if (!openingComplete || (i > 0 &&
            bar.timestamp != regular[i - 1].closeTimestamp)) {
          notes.add('正常交易時段 K 棒缺漏；無法確認完整當日低點，不建立進場單。');
          break;
        }
        volumeThroughBar += bar.volume;
        final minutesThroughBar = bar.closeTimestamp
            .difference(intraday.regularSessionStart!).inMinutes;
        final expectedThroughBar = sessionMinutes > 0 ?
            averageVolume * minutesThroughBar / sessionMinutes : 0;
        final epAtBar = openingComplete && gap >= 2 && expectedThroughBar > 0 &&
            volumeThroughBar >= expectedThroughBar * 1.5;
        final previous = i == 0 ? bar.open : regular[i - 1].close;
        if (epAtBar && i > 0 && openingHigh != null && previous <= openingHigh && bar.close > openingHigh) {
          trigger = openingHigh;
          triggerType = 'ORH';
          breakout = bar;
          break;
        }
        if (!epAtBar && compressed && (inside || narrow) && previous <= prior.high && bar.close > prior.high) {
          trigger = prior.high;
          triggerType = 'PDH';
          breakout = bar;
          break;
        }
      }
      final confirmedBar = breakout;
      if (confirmedBar != null) {
        confirmation = confirmedBar.close;
        entryBarLow = confirmedBar.low;
        dayLow = regular.where((bar) => !bar.timestamp.isAfter(confirmedBar.timestamp))
            .map((bar) => bar.low).reduce(math.min);
        final dayRisk = (trigger - dayLow) / trigger * 100;
        if (dayRisk > 0 && dayRisk <= 5) {
          stop = dayLow;
          stopSource = 'day_low';
        } else if (dayRisk > 5) {
          final tightRisk = (trigger - entryBarLow) / trigger * 100;
          if (tightRisk >= 1.5 && tightRisk <= 3) {
            stop = entryBarLow;
            stopSource = 'entry_bar_low';
          } else {
            notes.add('突破日低點風險超過 5%，實際進場 K 低點不在 1.5–3%；不虛造緊停損。');
          }
        }
        if (stop != null && intraday.latestPrice > stop) {
          signalTime = confirmedBar.closeTimestamp;
          patterns.add('$triggerType 突破');
        } else {
          stop = null;
          stopSource = null;
          notes.add('突破缺乏有效停損或最新報價已觸及停損，僅列觀察。');
        }
      }
    } else {
      notes.add('尚無新鮮且位於正常交易時段的完整盤中 K，突破未確認。');
    }
    if (patterns.isEmpty) patterns.add('ADR / RS 動能觀察');
    return LiveEvaluation(stock: stock, data: data, adr: adrPercent(bars),
      momentum: momentum, ema9: ema9,
      ema21: ema21, ema50: ema50, patterns: patterns, trigger: trigger,
      triggerType: triggerType, stop: stop, stopSource: stopSource,
      dayLow: dayLow, entryBarLow: entryBarLow, confirmation: confirmation,
      signalTime: signalTime, notes: notes);
  }

  /// Rank all successfully evaluated securities before applying ADR filters.
  /// Equal raw momentum receives equal percentile; one observation is 50.
  List<StockCandidate> rank(List<LiveEvaluation> evaluations) {
    final ordered = [...evaluations]..sort((a, b) {
      final score = b.momentum.compareTo(a.momentum);
      return score == 0 ? a.stock.symbol.compareTo(b.stock.symbol) : score;
    });
    return List.generate(ordered.length, (i) {
      final item = ordered[i];
      var first = i, last = i;
      while (first > 0 && ordered[first - 1].momentum == item.momentum) { first--; }
      while (last + 1 < ordered.length && ordered[last + 1].momentum == item.momentum) { last++; }
      final percentile = ordered.length < 2 ? 50.0 :
          (ordered.length - 1 - (first + last) / 2) / (ordered.length - 1) * 100;
      return item.toCandidate(rsScore: percentile, rsRank: first + 1);
    });
  }

  double _std(List<double> values) {
    final mean = values.reduce((a, b) => a + b) / values.length;
    return math.sqrt(values.map((value) => math.pow(value - mean, 2))
        .reduce((a, b) => a + b) / values.length);
  }
}

class LiveEvaluation {
  const LiveEvaluation({required this.stock, required this.data,
    required this.adr, required this.momentum, required this.ema9,
    required this.ema21, required this.ema50, required this.patterns,
    required this.trigger, required this.triggerType, required this.stop,
    required this.stopSource, required this.dayLow, required this.entryBarLow,
    required this.confirmation, required this.signalTime, required this.notes});
  final StockItem stock;
  final ChartBundle data;
  final double adr, momentum, ema9, ema21, ema50, trigger;
  final List<String> patterns, notes;
  final String? triggerType, stopSource;
  final double? stop, dayLow, entryBarLow, confirmation;
  final DateTime? signalTime;

  StockCandidate toCandidate({required double rsScore, required int rsRank}) =>
      StockCandidate(id: '${stock.market.name}:${stock.symbol}', symbol: stock.symbol,
        name: stock.displayName, sector: '來源未提供產業', market: stock.market,
        adrPercent: adr, rsScore: rsScore, rsRank: rsRank, patterns: patterns,
        entryPrice: trigger, triggerPrice: trigger, triggerType: triggerType,
        stopPrice: stop, stopSource: stopSource, dayLow: dayLow,
        entryBarLow: entryBarLow, confirmationPrice: confirmation,
        ema9: ema9, ema21: ema21, ema50: ema50,
        quotePrice: (data.intraday ?? data.daily).latestPrice,
        isLargeLiquid: largeLiquid(stock), status: stop == null ? 'watchlist' : 'confirmed',
        dataTimestamp: (data.intraday ?? data.daily).quoteTimestamp,
        signalTimestamp: signalTime, notes: notes,
        dailyCloses: data.daily.completedDailyBars.map((bar) => bar.close).toList());
}

/// A conservative, explicit allowlist. Membership in S&P 500 alone does not
/// prove the liquidity required for a 35% concentration allowance.
bool largeLiquid(StockItem stock) => stock.market == StockMarket.tw
    ? const {'2330.TW', '2317.TW', '2454.TW', '2308.TW', '2382.TW'}.contains(stock.symbol)
    : const {'AAPL', 'MSFT', 'NVDA', 'AMZN', 'GOOGL', 'GOOG', 'META', 'TSLA', 'AVGO', 'BRK-B'}.contains(stock.symbol);

PositionPlan _calculatePositionSize({required double capital,
    required double entryPrice, required double stopLossPrice,
    required bool isMegaCap}) {
  if (!capital.isFinite || capital <= 0) {
    throw ArgumentError.value(capital, 'capital', '帳戶本金必須為有限正數。');
  }
  _validateRiskPrices(entryPrice, stopLossPrice);
  final balance = _RiskDecimal.fromDouble(capital);
  final entry = _RiskDecimal.fromDouble(entryPrice);
  final stop = _RiskDecimal.fromDouble(stopLossPrice);
  final difference = entry - stop;
  final fraction = difference / entry;
  if (fraction.compareTo(_RiskDecimal.parse('0.015')) < 0 ||
      fraction.compareTo(_RiskDecimal.parse('0.03')) > 0) {
    throw ArgumentError('停損距離必須介於 1.5%–3%；請輸入實際停損，不自動虛造替代價格。');
  }
  final cap = _RiskDecimal.parse(isMegaCap ? '0.35' : '0.25');
  final budget = balance * _RiskDecimal.parse('0.005');
  final byRisk = (budget / difference).floor();
  final byCap = (balance * cap / entry).floor();
  final quantity = byRisk < byCap ? byRisk : byCap;
  if (quantity <= BigInt.zero) {
    throw ArgumentError('本金與風險預算不足以買進一股。');
  }
  if (quantity > BigInt.parse('9007199254740991')) {
    throw ArgumentError('股數超出 Dart VM / Web 可安全表示的整數範圍。');
  }
  final shares = quantity.toInt();
  final size = _RiskDecimal.integer(shares);
  final amount = size * entry;
  final risk = size * difference;
  // Verify using fractions before converting output to display doubles.
  if (risk.compareTo(budget) > 0 || amount.compareTo(balance * cap) > 0) {
    throw StateError('股數未通過單筆風險／持倉上限驗證。');
  }
  final trim = (size * _RiskDecimal.parse('0.12')).floor();
  final trimFraction = _RiskDecimal(trim, BigInt.one) / size;
  final validTrim = trimFraction.compareTo(_RiskDecimal.parse('0.10')) >= 0 &&
      trimFraction.compareTo(_RiskDecimal.parse('0.15')) <= 0;
  final targets = _calculateExitTargets(entryPrice, stopLossPrice);
  return PositionPlan(shares: shares, amount: amount.toDouble(),
    positionPercent: (amount / balance * _RiskDecimal.integer(100)).toDouble(),
    riskBudget: budget.toDouble(), riskAmount: risk.toDouble(),
    riskPerShare: difference.toDouble(),
    stopPercent: (fraction * _RiskDecimal.integer(100)).toDouble(),
    capPercent: (cap * _RiskDecimal.integer(100)).toDouble(),
    targets: targets.targets, trimShares: validTrim ? trim.toInt() : 0);
}

ExitTargets _calculateExitTargets(double entryPrice, double stopLossPrice) {
  _validateRiskPrices(entryPrice, stopLossPrice);
  final entry = _RiskDecimal.fromDouble(entryPrice);
  final difference = entry - _RiskDecimal.fromDouble(stopLossPrice);
  return ExitTargets(oneR: difference.toDouble(), targets: {
    for (final multiple in [3, 5, 10])
      multiple: (entry + difference * _RiskDecimal.integer(multiple)).toDouble(),
  });
}

void _validateRiskPrices(double entry, double stop) {
  if (!entry.isFinite || !stop.isFinite || entry <= 0 || stop <= 0 || stop >= entry) {
    throw ArgumentError('進場／初始停損必須為有限正數，且初始停損必須低於進場價。');
  }
}

/// Decimal double strings are interpreted exactly before division/floor.
/// Isolated from indicator arithmetic: an EMA never sets the sizing rounding.
class _RiskDecimal {
  factory _RiskDecimal(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) throw StateError('除數不得為零。');
    if (denominator.isNegative) { numerator = -numerator; denominator = -denominator; }
    final gcd = numerator.abs().gcd(denominator);
    return _RiskDecimal._(numerator ~/ gcd, denominator ~/ gcd);
  }
  const _RiskDecimal._(this.numerator, this.denominator);
  final BigInt numerator, denominator;
  factory _RiskDecimal.integer(int value) => _RiskDecimal(BigInt.from(value), BigInt.one);
  factory _RiskDecimal.fromDouble(double value) {
    if (!value.isFinite) throw ArgumentError('計算值必須為有限數。');
    return _RiskDecimal.parse(value.toString());
  }
  factory _RiskDecimal.parse(String value) {
    final parts = value.toLowerCase().split('e');
    final exponent = parts.length == 2 ? int.parse(parts[1]) : 0;
    final digits = parts.first.split('.');
    final scale = (digits.length == 2 ? digits[1].length : 0) - exponent;
    final numerator = BigInt.parse(digits.join());
    return scale >= 0 ? _RiskDecimal(numerator, BigInt.from(10).pow(scale)) :
        _RiskDecimal(numerator * BigInt.from(10).pow(-scale), BigInt.one);
  }
  _RiskDecimal operator +(_RiskDecimal other) => _RiskDecimal(
      numerator * other.denominator + other.numerator * denominator,
      denominator * other.denominator);
  _RiskDecimal operator -(_RiskDecimal other) => _RiskDecimal(
      numerator * other.denominator - other.numerator * denominator,
      denominator * other.denominator);
  _RiskDecimal operator *(_RiskDecimal other) =>
      _RiskDecimal(numerator * other.numerator, denominator * other.denominator);
  _RiskDecimal operator /(_RiskDecimal other) =>
      _RiskDecimal(numerator * other.denominator, denominator * other.numerator);
  int compareTo(_RiskDecimal other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
  BigInt floor() {
    final whole = numerator ~/ denominator;
    return numerator.isNegative && numerator.remainder(denominator) != BigInt.zero ?
        whole - BigInt.one : whole;
  }
  double toDouble() {
    if (numerator == BigInt.zero) return 0;
    final exponent = numerator.abs().toString().length - denominator.toString().length;
    final scale = 18 - exponent;
    final scaled = scale >= 0 ? (numerator * BigInt.from(10).pow(scale)) ~/ denominator :
        numerator ~/ (denominator * BigInt.from(10).pow(-scale));
    final result = double.parse('${scaled}e${-scale}');
    if (!result.isFinite || result == 0) throw ArgumentError('計算結果超出可顯示範圍。');
    return result;
  }
}
```

## test/rs_alignment_test.dart

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';

final _now = DateTime.utc(2026, 10, 15, 14);

List<PriceBar> _history({double slope = 1, DateTime? last}) {
  final dates = <DateTime>[];
  var date = last ?? DateTime.utc(2026, 10, 14, 13, 30);
  while (dates.length < 82) {
    if (date.weekday < 6) dates.add(date);
    date = date.subtract(const Duration(days: 1));
  }
  return dates.reversed.toList().asMap().entries.map((row) {
    final close = 100 + row.key * slope;
    return PriceBar(timestamp: row.value, open: close, high: close + 4,
        low: close - 4, close: close, volume: 100000);
  }).toList();
}

MarketChart _chart(List<PriceBar> bars, {String symbol = 'NVDA',
    StockMarket market = StockMarket.us, String interval = '1d',
    DateTime? fetchedAt, DateTime? quoteAt, DateTime? start, DateTime? end,
    bool missingSession = false}) => MarketChart(
  symbol: symbol, market: market, currency: market.currency,
  exchangeTimezoneName: market == StockMarket.tw ? 'Asia/Taipei' : 'America/New_York',
  gmtoffset: market == StockMarket.tw ? 28800 : -14400,
  bars: bars, latestPrice: bars.last.close, interval: interval,
  fetchedAt: fetchedAt ?? _now, quoteTimestamp: quoteAt ?? _now,
  regularSessionStart: missingSession ? null : start ?? DateTime.utc(2026, 10, 15, 13, 30),
  regularSessionEnd: missingSession ? null : end ?? DateTime.utc(2026, 10, 15, 20),
);

void main() {
  const engine = LiveStrategyEngine();

  for (final stockAhead in [true, false]) {
    test('RS uses identical return endpoints when ${stockAhead ? 'stock' : 'benchmark'} is one session ahead', () {
      final stockBars = _history(slope: 2);
      final indexBars = _history(slope: .5);
      final stock = _chart(stockAhead ? stockBars : stockBars.take(81).toList());
      final index = _chart(stockAhead ? indexBars.take(81).toList() : indexBars,
          symbol: '^GSPC');
      DateTime? alignedDate;
      int? stockTail, indexTail;
      final value = engine.relativeMomentum(stock, index,
          onAligned: (date, stockLag, indexLag) {
        alignedDate = date;
        stockTail = stockLag;
        indexTail = indexLag;
      });
      double excess(int sessions) =>
          (stockBars[80].close / stockBars[80 - sessions].close - 1) -
          (indexBars[80].close / indexBars[80 - sessions].close - 1);
      expect(value, closeTo((excess(20) + excess(60)) * 50, 1e-10));
      expect(alignedDate, DateTime.utc(2026, 10, 13));
      expect(stockTail, stockAhead ? 1 : 0);
      expect(indexTail, stockAhead ? 0 : 1);
    });
  }

  test('evaluation discloses common RS date and does not confirm a stale signal', () {
    final stock = StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
        nameZh: '輝達', nameFullZh: '', nameEn: 'NVIDIA', abbrEn: 'Nvidia');
    final result = engine.evaluate(stock: stock,
        data: ChartBundle(daily: _chart(_history(slope: 2))),
        benchmark: _chart(_history().take(81).toList(), symbol: '^GSPC'), now: _now);
    expect(result.notes.any((note) => note.contains('RS') &&
        note.contains('2026-10-13')), isTrue);
    expect(result.stop, isNull);
    expect(result.signalTime, isNull);
  });

  test('more than one trailing known session on either side remains rejected', () {
    final full = _history();
    for (final stockAhead in [true, false]) {
      expect(() => engine.relativeMomentum(
        _chart(stockAhead ? full : full.take(80).toList()),
        _chart(stockAhead ? full.take(80).toList() : full, symbol: '^GSPC')),
        throwsFormatException);
    }
  });

  test('old common date and fewer than 61 complete common sessions are rejected', () {
    final old = _history(last: DateTime.utc(2026, 10, 1, 13, 30));
    expect(() => engine.relativeMomentum(_chart(old), _chart(old, symbol: '^GSPC')),
        throwsFormatException);
    final short = _history().skip(22).toList();
    expect(() => engine.relativeMomentum(_chart(short), _chart(short, symbol: '^GSPC')),
        throwsFormatException);
  });

  test('RS requires daily charts from the same market', () {
    expect(() => engine.relativeMomentum(_chart(_history()),
        _chart(_history(), symbol: '^TWII', market: StockMarket.tw)),
        throwsFormatException);
    expect(() => engine.relativeMomentum(_chart(_history(), interval: '5m'),
        _chart(_history(), symbol: '^GSPC')), throwsFormatException);
  });

  test('rolled session metadata finalizes today only after close plus 15 minutes', () {
    final bars = _history();
    final atClose = DateTime.utc(2026, 10, 14, 20);
    final finalized = _chart(bars, fetchedAt: atClose.add(const Duration(minutes: 15)),
        quoteAt: atClose);
    expect(finalized.completedDailyBars.last.timestamp, bars.last.timestamp);
    final provisional = _chart(bars, fetchedAt: atClose.add(const Duration(minutes: 14)),
        quoteAt: atClose);
    expect(provisional.completedDailyBars.last.timestamp, bars[bars.length - 2].timestamp);
    final staleQuote = _chart(bars, fetchedAt: atClose.add(const Duration(minutes: 15)),
        quoteAt: atClose.subtract(const Duration(hours: 1)));
    expect(staleQuote.completedDailyBars.last.timestamp, bars[bars.length - 2].timestamp);
    final missingMetadata = _chart(bars,
        fetchedAt: atClose.add(const Duration(hours: 1)), quoteAt: atClose,
        missingSession: true);
    expect(missingMetadata.completedDailyBars.last.timestamp,
        bars[bars.length - 2].timestamp);
  });
}
```

## test/live_strategy_engine_test.dart

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';

void main() {
  const engine = LiveStrategyEngine();
  final now = DateTime.utc(2026, 10, 14, 14, 50);
  final stock = StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
    nameZh: '輝達', nameFullZh: '', nameEn: 'NVIDIA Corporation', abbrEn: 'Nvidia');
  List<PriceBar> history({double slope = 0}) {
    final dates = <DateTime>[];
    var date = DateTime.utc(2026, 10, 13, 13, 30);
    while (dates.length < 80) {
      if (date.weekday < 6) dates.add(date);
      date = date.subtract(const Duration(days: 1));
    }
    return dates.reversed.toList().asMap().entries.map((entry) {
      final close = 100 + entry.key * slope;
      return PriceBar(timestamp: entry.value, open: close,
        high: close + (entry.key == 79 ? 1.5 : 4),
        low: close - (entry.key == 79 ? 1.5 : 4), close: close, volume: 100000);
    }).toList();
  }
  MarketChart daily({String symbol = 'NVDA', double slope = 0,
      List<PriceBar>? bars, bool stale = false}) => MarketChart(symbol: symbol,
    market: StockMarket.us, currency: 'USD', exchangeTimezoneName: 'America/New_York',
    gmtoffset: -14400, bars: bars ?? history(slope: slope), latestPrice: 102,
    quoteTimestamp: now, fetchedAt: now, interval: '1d', isStale: stale,
    regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
    regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
  PriceBar minute(int offset, {required double open, required double high,
      required double low, required double close, double volume = 2000}) =>
      PriceBar(timestamp: DateTime.utc(2026, 10, 14, 13, 30).add(Duration(minutes: offset)),
        open: open, high: high, low: low, close: close, volume: volume,
        interval: const Duration(minutes: 5));
  MarketChart intraday(List<PriceBar> bars, {DateTime? quoteTime, bool stale = false}) =>
      MarketChart(symbol: 'NVDA', market: StockMarket.us, currency: 'USD',
        exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
        bars: bars, latestPrice: bars.last.close, quoteTimestamp: quoteTime ?? now,
        fetchedAt: now, interval: '5m', isStale: stale,
        regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
        regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
  LiveEvaluation evaluate(MarketChart? intradayChart, {MarketChart? dailyChart, DateTime? at}) =>
      engine.evaluate(stock: stock, data: ChartBundle(daily: dailyChart ?? daily(),
        intraday: intradayChart), benchmark: daily(symbol: '^GSPC'), now: at ?? now);

  test('ADR is mean of daily (high-low)/low, not ATR', () {
    final bars = [for (var i = 0; i < 20; i++) PriceBar(
      timestamp: DateTime.utc(2026, 1, i + 1), open: 100, high: 110,
      low: 100, close: 105, volume: 1)];
    expect(engine.adrPercent(bars), closeTo(10, 1e-12));
    expect(() => engine.adrPercent(bars.take(19).toList()), throwsFormatException);
  });
  test('EMA uses an SMA seed and rejects incomplete history', () {
    expect(engine.ema([1, 2, 3, 4], 3), closeTo(3, 1e-12));
    expect(() => engine.ema([100], 50), throwsFormatException);
  });
  test('RS aligns 61 common session dates and yields benchmark excess', () {
    expect(engine.relativeMomentum(daily(), daily(symbol: '^GSPC')), 0);
    expect(engine.relativeMomentum(daily(slope: 1), daily(symbol: '^GSPC')), greaterThan(0));
    expect(() => engine.relativeMomentum(daily(bars: history().skip(25).toList()),
      daily(symbol: '^GSPC')), throwsFormatException);
  });
  test('a benchmark more than one known session behind cannot create a ranking', () {
    expect(() => engine.relativeMomentum(daily(), daily(symbol: '^GSPC',
      bars: history().take(78).toList())), throwsFormatException);
  });
  test('completed PDH crossing uses exact high and actual day low', () {
    final result = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(5, open: 100, high: 102, low: 99, close: 102),
    ]));
    expect(result.trigger, 101.5);
    expect(result.stop, 98);
    expect(result.stopSource, 'day_low');
    expect(result.signalTime, DateTime.utc(2026, 10, 14, 13, 40));
    final candidate = result.toCandidate(rsScore: 50, rsRank: 1);
    expect(candidate.isConfirmed, true);
    expect(candidate.quotePrice, 102);
    expect(candidate.ema9, 100);
  });
  test('one-session stock history lag allows RS but cannot confirm a new entry', () {
    final result = evaluate(intraday([
      minute(0, open: 103, high: 104, low: 102, close: 103),
      minute(5, open: 103, high: 105, low: 102.5, close: 105),
    ]), dailyChart: daily(bars: history().take(79).toList()));
    expect(result.momentum.isFinite, isTrue);
    expect(result.stop, isNull);
    expect(result.signalTime, isNull);
    expect(result.notes.any((note) => note.contains('落後')), isTrue);
    expect(result.toCandidate(rsScore: 50, rsRank: 1).isConfirmed, isFalse);
  });
  test('provisional candle above PDH does not confirm crossing', () {
    final result = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(5, open: 100, high: 102, low: 99, close: 102),
    ], quoteTime: DateTime.utc(2026, 10, 14, 13, 37)),
      at: DateTime.utc(2026, 10, 14, 13, 37));
    expect(result.stop, null);
  });
  test('ORH excludes premarket and requires the actual opening candle', () {
    final result = evaluate(intraday([
      minute(-5, open: 106, high: 200, low: 106, close: 110),
      minute(0, open: 103, high: 104, low: 102, close: 103, volume: 40000),
      minute(5, open: 103, high: 106, low: 102.5, close: 105, volume: 40000),
    ]));
    expect(result.triggerType, 'ORH');
    expect(result.trigger, 104);
    expect(result.stop, 102);
    expect(result.patterns, contains('Episodic Pivot 量增'));
    final missingOpening = evaluate(intraday([
      minute(5, open: 103, high: 104, low: 102, close: 103, volume: 40000),
      minute(10, open: 103, high: 106, low: 102.5, close: 105, volume: 40000),
    ]));
    expect(missingOpening.triggerType, 'PDH');
    expect(missingOpening.patterns, isNot(contains('ORH 突破')));
  });
  test('gap without volume cannot manufacture an EP or ORH signal', () {
    final result = evaluate(intraday([
      minute(0, open: 103, high: 104, low: 102, close: 103, volume: 1),
      minute(5, open: 103, high: 106, low: 102.5, close: 105, volume: 1),
    ]));
    expect(result.patterns, isNot(contains('Episodic Pivot 量增')));
    expect(result.stop, null);
  });
  test('volume observed after a crossing cannot backdate an ORH confirmation', () {
    final result = evaluate(intraday([
      minute(0, open: 103, high: 104, low: 102, close: 103, volume: 1),
      minute(5, open: 103, high: 106, low: 102.5, close: 105, volume: 1),
      minute(10, open: 105, high: 108, low: 104, close: 106, volume: 1000000),
    ]));
    expect(result.patterns, contains('Episodic Pivot 量增'));
    expect(result.stop, null);
  });
  test('missing regular candles cannot establish a complete breakout day low', () {
    final result = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(10, open: 100, high: 102, low: 99, close: 102),
    ]));
    expect(result.stop, null);
    expect(result.notes.any((note) => note.contains('K 棒缺漏')), true);
  });
  test('real premarket gap is watch-only until an opening range exists', () {
    final at = DateTime.utc(2026, 10, 14, 12, 50);
    final result = evaluate(intraday([
      minute(-45, open: 102, high: 104, low: 102, close: 103),
    ], quoteTime: at), at: at);
    expect(result.stop, null);
    expect(result.patterns.any((pattern) => pattern.contains('盤前跳空')), true);
    expect(result.patterns, isNot(contains('ORH 突破')));
  });
  test('day risk over 5% uses only an actual qualifying entry bar low', () {
    final tight = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 94, close: 100),
      minute(5, open: 100, high: 103, low: 99, close: 102),
    ]));
    expect(tight.stop, 99);
    expect(tight.stopSource, 'entry_bar_low');
    final invalid = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 94, close: 100),
      minute(5, open: 100, high: 103, low: 96, close: 102),
    ]));
    expect(invalid.stop, null);
    expect(invalid.toCandidate(rsScore: 50, rsRank: 1).isConfirmed, false);
  });
  test('stale quotes and after-hours crossings remain watchlist', () {
    final bars = [minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(5, open: 100, high: 102, low: 99, close: 102)];
    expect(evaluate(intraday(bars, stale: true)).stop, null);
    expect(evaluate(intraday(bars, quoteTime: DateTime.utc(2026, 10, 14, 21))).stop, null);
    expect(evaluate(intraday(bars), dailyChart: daily(stale: true)).stop, null);
  });
  test('percentile ranks are bounded and a single stock is neutral', () {
    final item = evaluate(null);
    expect(engine.rank([item]).single.rsScore, 50);
    expect(engine.rank([item, item]).map((stock) => stock.rsScore), [50, 50]);
  });
}
```

## test/live_repositories_test.dart

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/live_batch_deadline.dart';
import 'package:martin_luk_app/services/live_candidate_repository.dart';
import 'package:martin_luk_app/services/live_portfolio_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 14, 14, 50);
StockItem _stock(String symbol) => StockItem(market: StockMarket.us,
  symbol: symbol, code: symbol, nameZh: '', nameFullZh: '', nameEn: symbol, abbrEn: '');

MarketChart _daily(String symbol, {int count = 80, bool lowAdr = false,
    int sessionOffsetDays = 0, StockMarket market = StockMarket.us}) => MarketChart(symbol: symbol,
  market: market, currency: market.currency,
  exchangeTimezoneName: market == StockMarket.tw ? 'Asia/Taipei' : 'America/New_York',
  gmtoffset: market == StockMarket.tw ? 28800 : -14400, bars: List.generate(count, (index) => PriceBar(
    timestamp: DateTime.utc(2026, 10, 13, 13, 30)
        .subtract(Duration(days: count - 1 - index + sessionOffsetDays)),
    open: 100, high: lowAdr ? 101 : 104, low: lowAdr ? 99 : 96, close: 100, volume: 10000)),
  latestPrice: 100, quoteTimestamp: _now, fetchedAt: _now, interval: '1d',
  regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
  regularSessionEnd: DateTime.utc(2026, 10, 14, 20));

class _Api extends MarketDataApi {
  _Api(SharedPreferences preferences) : super(preferences: preferences, now: () => _now);
  bool fail = false;
  final Map<String, Object> dailyFailures = {};
  final Map<String, Object> intradayFailures = {};
  final Map<String, MarketChart> dailyCharts = {};
  final Map<String, Completer<MarketChart>> dailyGates = {};
  final Map<String, Completer<MarketChart>> intradayGates = {};
  Completer<MarketChart>? benchmarkGate;
  final Stopwatch timing = Stopwatch()..start();
  final Map<String, Duration> dailyStarted = {};
  final Map<String, Duration> intradayFinished = {};
  int dailyCalls = 0, intradayCalls = 0, benchmarkCalls = 0;
  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    dailyCalls++;
    dailyStarted[symbol] = timing.elapsed;
    if (fail) throw StateError('Network unavailable');
    final failure = dailyFailures[symbol];
    if (failure != null) throw failure;
    final gate = dailyGates[symbol];
    if (gate != null) return gate.future;
    return dailyCharts[symbol] ?? _daily(symbol, market: market);
  }
  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async {
    benchmarkCalls++;
    if (fail) throw StateError('Network unavailable');
    final gate = benchmarkGate;
    if (gate != null) return gate.future;
    return _daily(market == StockMarket.tw ? '^TWII' : '^GSPC', market: market);
  }
  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    intradayCalls++;
    if (fail) throw StateError('Network unavailable');
    final failure = intradayFailures[symbol];
    if (failure != null) throw failure;
    final gate = intradayGates[symbol];
    if (gate != null) {
      final chart = await gate.future;
      intradayFinished[symbol] = timing.elapsed;
      return chart;
    }
    final chart = MarketChart(symbol: symbol, market: market, currency: 'USD',
      exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
      bars: [PriceBar(timestamp: DateTime.utc(2026, 10, 14, 13, 30),
        open: 100, high: 101, low: 99, close: 100, volume: 1000,
        interval: const Duration(minutes: 5))], latestPrice: 100,
      quoteTimestamp: _now, fetchedAt: _now, interval: '5m',
      regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
      regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
    intradayFinished[symbol] = timing.elapsed;
    return chart;
  }
}

Future<void> _waitForDailyCalls(_Api api, int expected) async {
  final watch = Stopwatch()..start();
  while (api.dailyCalls < expected) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('Test refresh did not start the expected chunk.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

// Unit-only Yahoo-shaped HTTP payload. This exercises the real parser and
// strategy path without inserting fixture prices into any production service.
Map<String, Object> _chartDocument(String symbol, String interval) {
  int unix(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
  final daily = interval == '1d';
  final times = daily
      ? List.generate(80, (index) => unix(DateTime.utc(2026, 10, 13, 13, 30)
          .subtract(Duration(days: 79 - index))))
      : [unix(DateTime.utc(2026, 10, 14, 13, 30))];
  final count = times.length;
  return {
    'chart': {
      'error': null,
      'result': [{
        'meta': {
          'symbol': symbol, 'currency': 'USD',
          'exchangeTimezoneName': 'America/New_York', 'gmtoffset': -14400,
          'regularMarketPrice': 100, 'regularMarketTime': unix(_now),
          'currentTradingPeriod': {'regular': {
            'start': unix(DateTime.utc(2026, 10, 14, 13, 30)),
            'end': unix(DateTime.utc(2026, 10, 14, 20)),
          }},
        },
        'timestamp': times,
        'indicators': {'quote': [{
          'open': List.filled(count, 100), 'high': List.filled(count, 104),
          'low': List.filled(count, 96), 'close': List.filled(count, 100),
          'volume': List.filled(count, 10000),
        }]},
      }],
    },
  };
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences) : super(preferences: preferences);
  final List<StockItem> rows;
  int calls = 0;
  Completer<UniverseSnapshot>? gate;
  @override
  Future<UniverseSnapshot> load(StockMarket market, {bool forceRefresh = false}) async {
    calls++;
    final pending = gate;
    if (pending != null) return pending.future;
    return UniverseSnapshot(stocks: rows, asOf: _now,
      source: 'Unit-test member fixture', isComplete: false,
      warnings: const ['Partial fixture, not a live complete universe']);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late _Api api;
  late _Universe universe;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    api = _Api(preferences);
    universe = _Universe([_stock('NVDA'), _stock('TSLA')], preferences);
  });

  test('scan reports evaluated coverage and ranks before ADR filtering', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.universeCount, 2);
    expect(snapshot.universeIsComplete, false);
    expect(snapshot.candidates.map((stock) => stock.rsScore), [50, 50]);
    expect(snapshot.candidates.every((stock) => !stock.isConfirmed), true);
    expect(api.dailyCalls, 2);
    expect(api.intradayCalls, 2);
    repository.close(); api.close(); universe.close();
  });
  test('foreground refresh reuses member scan and force refresh rescans', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await repository.fetch(StockMarket.us, adrThreshold: 5);
    await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(universe.calls, 1);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(universe.calls, 2);
    repository.close(); api.close(); universe.close();
  });
  test('HTTP failure retains explicitly stale true-data snapshot', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final first = await repository.fetch(StockMarket.us, adrThreshold: 5);
    api.fail = true;
    final cached = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(cached.stale, true);
    expect(cached.fetchedAt, first.fetchedAt);
    expect(cached.source, contains('真實快取'));
    expect(cached.candidates.map((stock) => stock.symbol), ['NVDA', 'TSLA']);
    repository.close(); api.close(); universe.close();
  });
  test('no cache and no real data reports error instead of demo fallback', () async {
    api.fail = true;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5), throwsA(isA<Exception>()));
    repository.close(); api.close(); universe.close();
  });
  test('portfolio completed EMA quote and stale fallback preserve timestamp', () async {
    final repository = DirectLivePortfolioRepository(api: api,
      preferences: preferences, now: () => _now);
    final first = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    final quote = first.quotes['NVDA']!;
    expect(quote.currentPrice, 100);
    expect(quote.ema9, 100);
    expect(quote.ema21, 100);
    expect(quote.ema50, 100);
    expect(quote.closeConfirmed, true);
    expect(quote.isStale, false);
    api.fail = true;
    final cached = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    expect(cached.quotes['NVDA']!.isStale, true);
    expect(cached.quotes['NVDA']!.isCached, true);
    expect(cached.quotes['NVDA']!.quoteTimestamp, quote.quoteTimestamp);
    expect(cached.errors['NVDA'], contains('保留上次真實快取'));
    repository.close(); api.close();
  });

  test('scan deadline returns partial coverage and does not publish late workers', () async {
    final rows = ['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'].map(_stock).toList();
    universe = _Universe(rows, preferences);
    final gates = {for (final symbol in ['TSLA', 'AMD', 'AAPL', 'META'])
      symbol: Completer<MarketChart>()};
    api.dailyGates.addAll(gates);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 200));
    final firstRequest = repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    final sameRequest = repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(identical(firstRequest, sameRequest), true);
    final partial = await firstRequest.timeout(const Duration(seconds: 2));
    expect(partial.evaluatedCount, 1);
    expect(partial.universeCount, 5);
    expect(partial.missingSymbols.toSet(), gates.keys.toSet());
    expect(partial.warnings.any((warning) => warning.contains('整批掃描期限')), true);
    final partialCache = jsonDecode(preferences.getString('martin-live-scan-v1-us-5.0')!) as Map;
    expect(partialCache['evaluated_count'], 1,
        reason: 'The scan reserves time to persist a partial offline snapshot inside its budget.');

    api.dailyGates.clear();
    final recovered = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(recovered.evaluatedCount, 5);
    expect(recovered.missingSymbols, isEmpty);
    final intradayCalls = api.intradayCalls;
    for (final entry in gates.entries) { entry.value.complete(_daily(entry.key)); }
    await Future<void>.delayed(Duration.zero);
    expect(api.intradayCalls, intradayCalls,
        reason: 'Late daily replies must not schedule another intraday request.');
    final persisted = jsonDecode(preferences.getString('martin-live-scan-v1-us-5.0')!) as Map;
    expect(persisted['evaluated_count'], 5,
        reason: 'The expired batch must not overwrite a successful retry cache.');
    repository.close(); api.close(); universe.close();
  });

  test('universe request is inside deadline and a failed pending entry can retry', () async {
    final gate = Completer<UniverseSnapshot>();
    universe.gate = gate;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 80));
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5)
        .timeout(const Duration(seconds: 2)), throwsA(isA<RepositoryException>()));
    expect(api.benchmarkCalls, 1,
        reason: 'Independent benchmark loading starts while the universe request is pending.');
    universe.gate = null;
    final retry = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(retry.evaluatedCount, 2);
    gate.completeError(StateError('Old universe request failed after retry.'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); api.close(); universe.close();
  });

  test('benchmark deadline preserves genuine cache and next forced refresh recovers', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 150));
    final initial = await repository.fetch(StockMarket.us, adrThreshold: 5);
    final gate = Completer<MarketChart>();
    api.benchmarkGate = gate;
    final stale = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true)
        .timeout(const Duration(seconds: 2));
    expect(stale.stale, true);
    expect(stale.fetchedAt, initial.fetchedAt);
    expect(stale.candidates.length, initial.candidates.length);
    api.benchmarkGate = null;
    final recovered = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(recovered.stale, false);
    gate.complete(_daily('^GSPC'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); api.close(); universe.close();
  });

  test('cold quote-only polling does not unexpectedly launch a full universe scan', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true),
        throwsA(isA<RepositoryException>()));
    expect(universe.calls, 0);
    final initialized = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(initialized.evaluatedCount, 2);
    repository.close(); api.close(); universe.close();
  });

  test('hot quote deadline preserves timestamps and cannot launch late intraday work', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now,
      quoteRefreshBudget: const Duration(milliseconds: 150));
    final initial = await repository.fetch(StockMarket.us, adrThreshold: 5);
    final gates = {for (final symbol in ['NVDA', 'TSLA']) symbol: Completer<MarketChart>()};
    api.dailyGates.addAll(gates);
    final stale = await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true)
        .timeout(const Duration(seconds: 2));
    expect(stale.stale, true);
    expect(stale.fetchedAt, initial.fetchedAt);
    final intradayCalls = api.intradayCalls;
    for (final entry in gates.entries) { entry.value.complete(_daily(entry.key)); }
    await Future<void>.delayed(Duration.zero);
    expect(api.intradayCalls, intradayCalls);
    api.dailyGates.clear();
    final recovered = await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(recovered.stale, false);
    expect(universe.calls, 1);
    repository.close(); api.close(); universe.close();
  });

  test('portfolio whole-batch deadline identifies all missing symbols and retries', () async {
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now, updateBudget: const Duration(milliseconds: 500));
    final gates = {for (final symbol in ['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'])
      symbol: Completer<MarketChart>()};
    api.dailyGates.addAll(gates);
    final request = repository.fetch(StockMarket.us, gates.keys.toList(), forceRefresh: true);
    final sameRequest = repository.fetch(StockMarket.us, gates.keys.toList().reversed.toList(), forceRefresh: true);
    expect(identical(request, sameRequest), true);
    final failed = await request.timeout(const Duration(seconds: 2));
    expect(failed.quotes, isEmpty);
    expect(failed.errors.keys.toSet(), gates.keys.toSet());
    expect(api.dailyCalls, lessThanOrEqualTo(4));
    expect(api.intradayCalls, 0);
    api.dailyGates.clear();
    final recovered = await repository.fetch(StockMarket.us, gates.keys.toList(), forceRefresh: true);
    expect(recovered.quotes.length, 5);
    expect(recovered.errors, isEmpty);
    final intradayCalls = api.intradayCalls;
    for (final entry in gates.entries) { entry.value.complete(_daily(entry.key)); }
    await Future<void>.delayed(Duration.zero);
    expect(api.intradayCalls, intradayCalls);
    repository.close(); api.close();
  });

  test('portfolio timed-out refresh retains stale original quote rather than empty success', () async {
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now, updateBudget: const Duration(milliseconds: 500));
    final initial = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final stale = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    expect(stale.errors['NVDA'], contains('保留上次真實快取'));
    expect(stale.quotes['NVDA']!.isStale, true);
    expect(stale.quotes['NVDA']!.isCached, true);
    expect(stale.quotes['NVDA']!.quoteTimestamp, initial.quotes['NVDA']!.quoteTimestamp);
    expect(stale.quotes['NVDA']!.fetchedAt, initial.quotes['NVDA']!.fetchedAt);
    gate.completeError(StateError('Disconnected after batch was returned.'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); api.close();
  });

  test('disposal ends a blocked batch without closing a borrowed market API', () async {
    api.dailyGates['NVDA'] = Completer<MarketChart>();
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final request = repository.fetch(StockMarket.us, adrThreshold: 5);
    final checked = expectLater(request, throwsA(isA<RepositoryException>()));
    await _waitForDailyCalls(api, 1);
    repository.close();
    await checked.timeout(const Duration(seconds: 2));
    api.dailyGates.clear();
    expect((await api.fetchDaily('NVDA', StockMarket.us)).latestPrice, 100);
    api.close(); universe.close();
  });

  test('sealed deadline consumes an already-created operation that fails later', () async {
    final run = LiveBatchDeadline(const Duration(seconds: 1));
    run.seal();
    final late = Completer<int>();
    await expectLater(run.wait(late.future), throwsA(isA<TimeoutException>()));
    late.completeError(StateError('Late response failure must remain observed.'));
    await Future<void>.delayed(Duration.zero);
  });

  test('scan waits for all four stocks and throttles before the next chunk', () async {
    universe = _Universe(['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'].map(_stock).toList(), preferences);
    final gate = Completer<MarketChart>();
    api.dailyGates['TSLA'] = gate;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, batchSize: 4);
    final request = repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    await _waitForDailyCalls(api, 4);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.dailyCalls, 4,
        reason: 'A fast worker must not start a fifth stock while another chunk member is pending.');
    expect(api.dailyStarted.containsKey('META'), false);
    gate.complete(_daily('TSLA'));
    final snapshot = await request.timeout(const Duration(seconds: 2));
    expect(snapshot.evaluatedCount, 5);
    expect(api.dailyStarted['META']! - api.intradayFinished['TSLA']!,
        greaterThanOrEqualTo(const Duration(milliseconds: 145)),
        reason: 'The default 150 ms delay occurs after every stock in the chunk finishes.');
    repository.close(); api.close(); universe.close();
  });

  test('hot quote refresh uses the same complete-chunk barrier and pause', () async {
    universe = _Universe(['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'].map(_stock).toList(), preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, batchSize: 4);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    api.dailyCalls = 0;
    api.dailyStarted.clear();
    api.intradayFinished.clear();
    // Candidate ranking uses symbol order for equal fixture momentum.
    // TSLA is the fifth ranked symbol; gate a member of the first hot chunk.
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final request = repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    await _waitForDailyCalls(api, 4);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.dailyCalls, 4);
    expect(api.dailyStarted.containsKey('TSLA'), false);
    gate.complete(_daily('NVDA'));
    final snapshot = await request.timeout(const Duration(seconds: 2));
    expect(snapshot.stale, false);
    expect(api.dailyStarted['TSLA']! - api.intradayFinished['NVDA']!,
        greaterThanOrEqualTo(const Duration(milliseconds: 145)));
    repository.close(); api.close(); universe.close();
  });

  test('portfolio waits for the entire chunk and limits it to four symbols', () async {
    final gate = Completer<MarketChart>();
    api.dailyGates['TSLA'] = gate;
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now);
    final request = repository.fetch(StockMarket.us,
        ['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'], forceRefresh: true);
    await _waitForDailyCalls(api, 4);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.dailyCalls, 4);
    expect(api.dailyStarted.containsKey('META'), false);
    gate.complete(_daily('TSLA'));
    final snapshot = await request.timeout(const Duration(seconds: 2));
    expect(snapshot.quotes.length, 5);
    expect(snapshot.errors, isEmpty);
    expect(api.dailyStarted['META']! - api.intradayFinished['TSLA']!,
        greaterThanOrEqualTo(const Duration(milliseconds: 95)));
    repository.close(); api.close();
  });

  test('deadline during the inter-chunk pause returns partial data without another request', () async {
    universe = _Universe(['NVDA', 'TSLA'].map(_stock).toList(), preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now,
      scanBudget: const Duration(milliseconds: 150), batchSize: 1,
      interBatchDelay: const Duration(seconds: 5));
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true)
        .timeout(const Duration(seconds: 1));
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.missingSymbols, ['TSLA']);
    expect(api.dailyCalls, 1);
    expect(api.intradayCalls, 1);
    repository.close(); api.close(); universe.close();
  });

  test('sealing a run cancels a long inter-chunk pause immediately', () async {
    final run = LiveBatchDeadline(const Duration(seconds: 10));
    final waiting = expectLater(run.pause(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()));
    run.seal();
    await waiting.timeout(const Duration(seconds: 1));
  });

  test('invalid chunk sizes cannot create an unbounded or non-progressing scan', () {
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, batchSize: 0), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, batchSize: 6), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, corePoolSize: 0), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, corePoolSize: 31), throwsArgumentError);
    expect(() => DirectLivePortfolioRepository(api: api, preferences: preferences,
      batchSize: 6), throwsArgumentError);
    api.close(); universe.close();
  });

  test('one provider failure and one RS alignment failure leave healthy recommendations intact', () async {
    universe = _Universe(['BAD', 'TSLA', 'NVDA'].map(_stock).toList(), preferences);
    api.dailyFailures['BAD'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    api.dailyCharts['TSLA'] = _daily('TSLA', sessionOffsetDays: 2);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.candidates.map((stock) => stock.symbol), ['NVDA']);
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.missingSymbols.toSet(), {'BAD', 'TSLA'});
    final warning = snapshot.warnings.join('\n');
    expect(warning, contains('BAD：Yahoo chart HTTP 403'));
    expect(warning, contains('TSLA：FormatException: RS 資料落差超過一個已知交易日'));
    repository.close(); api.close(); universe.close();
  });

  test('a later healthy stock is still evaluated after twelve invalid stocks', () async {
    final bad = List.generate(12, (index) => 'BAD$index');
    // This fixture symbol is not in the priority list, so it remains after all
    // twelve failures and exercises continued processing of later chunks.
    universe = _Universe([...bad, 'HEALTHY'].map(_stock).toList(), preferences);
    for (final symbol in bad) {
      api.dailyFailures[symbol] = const FormatException('OHLCV 欄位缺漏');
    }
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.candidates.single.symbol, 'HEALTHY');
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.missingSymbols.length, 12);
    expect(api.dailyCalls, 13);
    expect(snapshot.warnings.join('\n'), contains('其餘 6 檔錯誤摘要已省略'));
    repository.close(); api.close(); universe.close();
  });

  test('all failed stock requests retain provider reasons rather than a generic empty result', () async {
    api.dailyFailures['NVDA'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    api.dailyFailures['TSLA'] = const FormatException('OHLCV 缺漏');
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true),
        throwsA(isA<RepositoryException>()
          .having((error) => error.message, 'provider cause', contains('NVDA：Yahoo chart HTTP 403'))
          .having((error) => error.message, 'format cause', contains('TSLA：FormatException: OHLCV 缺漏'))));
    repository.close(); api.close(); universe.close();
  });

  test('successful low-ADR scan returns a valid empty recommendation without relaxing thresholds', () async {
    api.dailyCharts['NVDA'] = _daily('NVDA', lowAdr: true);
    api.dailyCharts['TSLA'] = _daily('TSLA', lowAdr: true);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.missingSymbols, isEmpty);
    expect(snapshot.stale, false);
    expect(snapshot.warnings.join('\n'), contains('推薦清單為有效的空結果'));
    expect(api.intradayCalls, 0);
    repository.close(); api.close(); universe.close();
  });

  test('core scan limits HTTP work to 30 genuine members and keeps the universe count', () async {
    final rows = [
      ...List.generate(60, (index) => _stock('S$index')),
      _stock('TSLA'), _stock('AAPL'), _stock('NVDA'),
    ];
    universe = _Universe(rows, preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now,
      interBatchDelay: Duration.zero);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5,
      forceRefresh: true);
    expect(snapshot.universeCount, 63);
    expect(snapshot.scanPoolSize, 30);
    expect(snapshot.evaluatedCount, 30);
    expect(snapshot.adrMatchCount, 30);
    expect(api.dailyCalls, 30);
    expect(api.dailyStarted.keys.take(3), ['NVDA', 'AAPL', 'TSLA']);
    expect(api.dailyStarted.keys.every((symbol) => rows.any((row) => row.symbol == symbol)), true);
    expect(snapshot.missingSymbols, isEmpty,
      reason: 'Members outside the intentionally selected core are not provider failures.');
    expect(snapshot.warnings.join('\n'), contains('本次核心精選池 30 檔'));
    expect(snapshot.warnings.join('\n'), contains('未向整個市場同時發送請求'));
    repository.close(); api.close(); universe.close();
  });

  test('TW core selection requests only current TW members and uses Taiwan priorities', () async {
    StockItem tw(String code) => StockItem(market: StockMarket.tw,
      symbol: '$code.TW', code: code, nameZh: code, nameFullZh: '',
      nameEn: '', abbrEn: '');
    final rows = [
      ...List.generate(34, (index) => tw('${4000 + index}')),
      tw('2603'), tw('2330'),
    ];
    universe = _Universe(rows, preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, interBatchDelay: Duration.zero);
    final snapshot = await repository.fetch(StockMarket.tw, adrThreshold: 100,
      forceRefresh: true);
    expect(snapshot.universeCount, 36);
    expect(snapshot.scanPoolSize, 30);
    expect(snapshot.evaluatedCount, 30);
    expect(snapshot.adrMatchCount, 0);
    expect(api.dailyStarted.keys.take(2), ['2330.TW', '2603.TW']);
    expect(api.dailyStarted.containsKey('2454.TW'), false,
      reason: 'Priority symbols absent from actual membership must not be invented.');
    expect(api.dailyCalls, 30);
    expect(api.intradayCalls, 0);
    repository.close(); api.close(); universe.close();
  });

  test('batch progress counts failed symbols as completed and isolates observer errors', () async {
    universe = _Universe([
      _stock('NVDA'), _stock('AAPL'), _stock('TSLA'),
      ...List.generate(9, (index) => _stock('X$index')),
    ], preferences);
    api.dailyFailures['AAPL'] = const MarketDataException('HTTP 429', statusCode: 429);
    api.dailyCharts['TSLA'] = _daily('TSLA', lowAdr: true);
    final progress = <MarketScanProgress>[];
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, interBatchDelay: Duration.zero);
    final snapshot = await repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: (value) {
        progress.add(value);
        if (value.completedCount == 5) throw StateError('Faulty UI observer');
      });
    expect(progress.where((row) => !row.finished && row.completedCount > 0)
        .map((row) => row.completedCount), [5, 10, 12]);
    final finished = progress.last;
    expect(finished.finished, true);
    expect(finished.attemptedCount, 12);
    expect(finished.completedCount, 12);
    expect(finished.evaluatedCount, 11);
    expect(finished.failedCount, 1);
    expect(finished.adrMatchCount, 10);
    expect(finished.fraction, 1);
    expect(finished.label, contains('已掃描 12/12 檔'));
    expect(snapshot.adrMatchCount, 10);
    expect(snapshot.candidates.length, 10);
    expect(snapshot.missingSymbols, ['AAPL']);
    repository.close(); api.close(); universe.close();
  });

  test('disposed progressive scan does not commit or notify after a late response', () async {
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final progress = <MarketScanProgress>[];
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final request = repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: progress.add);
    final checked = expectLater(request, throwsA(isA<RepositoryException>()));
    await _waitForDailyCalls(api, 2);
    repository.close();
    await checked.timeout(const Duration(seconds: 2));
    final countAtClose = progress.length;
    final intradayAtClose = api.intradayCalls;
    gate.complete(_daily('NVDA'));
    await Future<void>.delayed(Duration.zero);
    expect(progress.length, countAtClose);
    expect(api.intradayCalls, intradayAtClose);
    expect(preferences.getString('martin-live-scan-v1-us-5.0'), isNull);
    api.close(); universe.close();
  });

  test('all-failed core scan finishes progress with an error rather than an empty success', () async {
    api.dailyFailures['NVDA'] = const MarketDataException('HTTP 403', statusCode: 403);
    api.dailyFailures['TSLA'] = const FormatException('OHLCV missing');
    final progress = <MarketScanProgress>[];
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await expectLater(repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: progress.add),
      throwsA(isA<RepositoryException>()));
    expect(progress.last.finished, true);
    expect(progress.last.failedCount, 2);
    expect(progress.last.completedCount, 2);
    expect(progress.last.stage, contains('評估失敗'));
    expect(preferences.getString('martin-live-scan-v1-us-5.0'), isNull);
    repository.close(); api.close(); universe.close();
  });

  test('daily evaluation is preserved and a missing intraday quote gives its own cause', () async {
    api.intradayFailures['TSLA'] = const MarketDataException('Intraday HTTP 429', statusCode: 429);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.missingSymbols, isEmpty);
    expect(snapshot.candidates.singleWhere((stock) => stock.symbol == 'TSLA').isConfirmed, false);
    expect(snapshot.warnings.join('\n'), contains('TSLA：Intraday HTTP 429'));
    repository.close(); api.close(); universe.close();
  });

  test('hot quote errors preserve the actual failing symbol and HTTP status', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    api.dailyFailures['TSLA'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(snapshot.stale, true);
    expect(snapshot.candidates.length, 2);
    expect(snapshot.warnings.join('\n'), contains('TSLA：Yahoo chart HTTP 403'));
    repository.close(); api.close(); universe.close();
  });

  test('portfolio invalid EMA and provider data do not discard a healthy quote or mask their causes', () async {
    api.dailyFailures['BAD'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    api.dailyCharts['TSLA'] = _daily('TSLA', count: 30);
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, ['BAD', 'TSLA', 'NVDA'], forceRefresh: true);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.errors['BAD'], contains('HTTP 403'));
    expect(snapshot.errors['BAD'], isNot(contains('逾時')));
    expect(snapshot.errors['TSLA'], contains('EMA'));
    expect(snapshot.errors['TSLA'], isNot(contains('逾時')));
    repository.close(); api.close();
  });

  test('one wrongly typed cache key cannot discard another genuinely cached holding', () async {
    final seed = DirectLivePortfolioRepository(api: api, preferences: preferences, now: () => _now);
    final initial = await seed.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    seed.close();
    await preferences.setInt('martin-live-holding-v1-us-TSLA', 42);
    api.fail = true;
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, ['NVDA', 'TSLA'], forceRefresh: true);
    expect(snapshot.quotes['NVDA']!.isStale, true);
    expect(snapshot.quotes['NVDA']!.quoteTimestamp, initial.quotes['NVDA']!.quoteTimestamp);
    expect(snapshot.errors['NVDA'], contains('保留上次真實快取'));
    expect(snapshot.errors['NVDA'], contains('Network unavailable'));
    expect(snapshot.errors['TSLA'], contains('Network unavailable'));
    expect(snapshot.errors['TSLA'], isNot(contains('逾時')));
    repository.close(); api.close();
  });

  test('cold membership timeout falls back early enough to scan real HTTP parser fixtures', () async {
    final stalled = Completer<http.Response>();
    final membershipClient = MockClient((_) => stalled.future);
    final members = StockUniverseService(client: membershipClient,
      preferences: preferences, now: () => _now,
      requestTimeout: const Duration(milliseconds: 40),
      storageTimeout: const Duration(milliseconds: 100));
    final chartRequests = <String>[];
    final chartClient = MockClient((request) async {
      final symbol = request.url.pathSegments.last;
      final interval = request.url.queryParameters['interval']!;
      chartRequests.add('$symbol:$interval');
      return http.Response(jsonEncode(_chartDocument(symbol, interval)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final realApi = MarketDataApi(client: chartClient, preferences: preferences, now: () => _now);
    final repository = DirectLiveCandidateRepository(api: realApi, universe: members,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 300));
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true)
        .timeout(const Duration(seconds: 2));
    expect(chartRequests, contains('^GSPC:1d'));
    expect(snapshot.evaluatedCount, greaterThan(0));
    expect(snapshot.candidates, isNotEmpty);
    expect(snapshot.candidates.first.adrPercent, closeTo(8.3333333333, .000001));
    expect(snapshot.universeCount, greaterThan(snapshot.evaluatedCount!));
    expect(snapshot.universeIsComplete, false);
    expect(snapshot.warnings.join('\n'), contains('僅使用內建'));
    expect(snapshot.warnings.join('\n'), contains('不是目前完整'));
    expect(snapshot.missingSymbols, isNotEmpty);
    // An eventual membership reply cannot turn the already-published partial
    // snapshot into a fabricated, fully refreshed constituent list.
    stalled.completeError(StateError('Late membership failure after fallback.'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); realApi.close(); members.close();
    chartClient.close(); membershipClient.close();
    api.close(); universe.close();
  });
}
```

## test/live_risk_helpers_test.dart

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';

void main() {
  test('fixed 0.5% risk budget and whole-share floor', () {
    final plan = calculatePositionSize(capital: 50000, entryPrice: 100,
      stopLossPrice: 98, isMegaCap: true);
    expect(plan.riskBudget, 250);
    expect(plan.riskPerShare, 2);
    expect(plan.shares, 125);
    expect(plan.amount, 12500);
    expect(plan.riskAmount, 250);
    expect(plan.stopPercent, 2);
  });
  test('small-cap 25% exposure caps shares below risk-only result', () {
    final mega = calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 98.5, isMegaCap: true);
    final small = calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 98.5, isMegaCap: false);
    expect(mega.capPercent, 35);
    expect(mega.shares, 333);
    expect(mega.positionPercent, lessThanOrEqualTo(35));
    expect(small.capPercent, 25);
    expect(small.shares, 250);
    expect(small.positionPercent, 25);
    expect(small.riskAmount, 375);
    expect(small.riskAmount, lessThanOrEqualTo(small.riskBudget));
  });
  test('1.5% and 3% boundaries are inclusive and not silently tightened', () {
    expect(calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 98.5, isMegaCap: true).stopPercent, 1.5);
    expect(calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 97, isMegaCap: true).stopPercent, 3);
    for (final stop in [98.500001, 96.999999, 94.0]) {
      expect(() => calculatePositionSize(capital: 100000, entryPrice: 100,
        stopLossPrice: stop, isMegaCap: true), throwsArgumentError);
    }
  });
  test('decimal risk boundary does not lose or add a share due to IEEE subtraction', () {
    // Naive 0.25 - 0.245 is 0.005000000000000004, whose risk-only
    // quotient floors to 99. Exact decimal arithmetic correctly returns 100.
    final plan = calculatePositionSize(capital: 100, entryPrice: .25,
      stopLossPrice: .245, isMegaCap: false);
    expect(plan.shares, 100);
    expect(plan.amount, 25);
    expect(plan.riskAmount, .5);
    expect(plan.riskBudget, .5);
    expect(plan.riskPerShare, .005);
    expect(plan.positionPercent, 25);
  });
  test('fractional quantity is floored; target decimals remain canonical', () {
    final plan = calculatePositionSize(capital: 100000, entryPrice: 17.32,
      stopLossPrice: 17, isMegaCap: true);
    expect(plan.shares, 1562);
    expect(plan.riskAmount, 499.84);
    expect(plan.amount, 27053.84);
    expect(plan.targets, {3: 18.28, 5: 18.92, 10: 20.52});
  });
  test('zero, negative and non-finite capital or prices are rejected', () {
    for (final capital in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calculatePositionSize(capital: capital, entryPrice: 100,
        stopLossPrice: 98, isMegaCap: true), throwsArgumentError);
    }
    for (final entry in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calculatePositionSize(capital: 50000, entryPrice: entry,
        stopLossPrice: 98, isMegaCap: true), throwsArgumentError);
    }
    for (final stop in [0.0, -1.0, 100.0, 101.0, double.nan, double.infinity]) {
      expect(() => calculatePositionSize(capital: 50000, entryPrice: 100,
        stopLossPrice: stop, isMegaCap: true), throwsArgumentError);
    }
  });
  test('insufficient capital and unsafe integers are explicit errors', () {
    expect(() => calculatePositionSize(capital: 1, entryPrice: 100,
      stopLossPrice: 98, isMegaCap: true), throwsArgumentError);
    expect(() => calculatePositionSize(capital: 1e20, entryPrice: .1,
      stopLossPrice: .098, isMegaCap: true), throwsArgumentError);
  });
  test('exact 1R and 3R/5R/10R target prices are immutable', () {
    final targets = calculateExitTargets(.1, .098);
    expect(targets.oneR, .002);
    expect(targets.targets, {3: .106, 5: .11, 10: .12});
    expect(targets.targetPrice(3), .106);
    expect(() => targets.targetPrice(2), throwsArgumentError);
    expect(() => targets.targets[3] = 1, throwsUnsupportedError);
  });
  test('target math validates initial risk without imposing new-order bounds', () {
    expect(calculateExitTargets(100, 90).oneR, 10);
    expect(calculateExitTargets(100, 90).targets, {3: 130, 5: 150, 10: 200});
    for (final stop in [0.0, -1.0, 100.0, 101.0, double.nan, double.infinity]) {
      expect(() => calculateExitTargets(100, stop), throwsArgumentError);
    }
    for (final entry in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calculateExitTargets(entry, 98), throwsArgumentError);
    }
  });
  test('static wrappers return the same plans and risk target values', () {
    final top = calculatePositionSize(capital: 50000, entryPrice: 100,
      stopLossPrice: 98, isMegaCap: true);
    final member = LiveStrategyEngine.calculatePositionSize(capital: 50000,
      entryPrice: 100, stopLossPrice: 98, isMegaCap: true);
    expect(member.shares, top.shares);
    expect(member.riskAmount, top.riskAmount);
    expect(member.targets, top.targets);
    expect(LiveStrategyEngine.calculateExitTargets(100, 98).targets,
      calculateExitTargets(100, 98).targets);
  });
}
```

## scripts/validate_live_scan_evidence.py

```python
#!/usr/bin/env python3
"""Validate real-market health evidence before building an APK.

The live Dart test verifies the individual signal and sizing calculations.
This separate, dependency-free gate checks that CI received a successful,
complete, current-version report from that test. A market with no qualifying
entry is healthy and is allowed to build; failed or missing live data is not.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from typing import Any


REQUIRED_SYMBOLS = ("NVDA", "AAPL", "TSLA", "2330.TW", "2603.TW")
REQUIRED_BENCHMARKS = {"^GSPC": ("us", "USD"), "^TWII": ("tw", "TWD")}
_NON_REAL_SOURCE = re.compile(r"mock|fictitious|demo|示範|假", re.IGNORECASE)


class ValidationError(ValueError):
    """The evidence cannot authorize an APK build."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def _number(value: Any, field: str, *, minimum: float | None = None,
            positive: bool = False) -> float:
    # bool is a subclass of int in Python, but is never valid numeric evidence.
    _require(isinstance(value, (int, float)) and not isinstance(value, bool),
             f"{field} 必須是數字。")
    try:
        number = float(value)
    except (OverflowError, ValueError) as error:
        raise ValidationError(f"{field} 必須是有限數字。") from error
    _require(math.isfinite(number), f"{field} 必須是有限數字。")
    if minimum is not None:
        _require(number >= minimum, f"{field} 不可小於 {minimum}。")
    if positive:
        _require(number > 0, f"{field} 必須大於零。")
    return number


def validate_evidence(report: Any) -> int:
    """Return the qualified candidate count, including zero, or raise.

    This function performs no network calls and never substitutes fixture data.
    It accepts only evidence emitted by the schema-v2 real-market health test.
    """
    _require(isinstance(report, dict), "實測報告必須是 JSON object。")
    _require(type(report.get("schema_version")) is int and
             report["schema_version"] == 2,
             "需要 schema_version=2，請同步更新真實行情測試。")
    _require(report.get("verification_mode") == "real_market_health",
             "verification_mode 必須是 real_market_health。")
    _require(report.get("use_mock_data") is False,
             "正式版門禁要求 use_mock_data=false。")
    _require(report.get("status") == "passed", "真實行情測試未通過。")
    _require(not report.get("failure"), "實測報告仍包含 failure。")
    for field in ("benchmarks_verified", "required_symbols_verified",
                  "indicators_verified"):
        _require(report.get(field) is True, f"{field} 尚未驗證成功。")

    required = report.get("required_symbols")
    _require(isinstance(required, list) and
             all(isinstance(symbol, str) for symbol in required) and
             len(required) == len(REQUIRED_SYMBOLS) and
             set(required) == set(REQUIRED_SYMBOLS),
             "required_symbols 必須完整包含 NVDA/AAPL/TSLA/2330.TW/2603.TW。")
    deadline = _number(report.get("whole_run_deadline_seconds"),
                       "whole_run_deadline_seconds", positive=True)
    _require(deadline == 15, "整個實測流程期限必須是 15 秒。")
    elapsed = _number(report.get("elapsed_ms"), "elapsed_ms", minimum=0)
    _require(elapsed <= 15000, "真實行情驗證超過 15 秒期限。")

    errors = report.get("errors")
    _require(isinstance(errors, dict) and
             all(isinstance(key, str) and isinstance(value, str)
                 for key, value in errors.items()),
             "errors 必須是 symbol 到錯誤文字的 map。")
    for symbol in (*REQUIRED_SYMBOLS, *REQUIRED_BENCHMARKS):
        _require(symbol not in errors, f"必需行情 {symbol} 仍有錯誤。")

    observations = report.get("observations")
    _require(isinstance(observations, list), "observations 必須是 list。")
    verified: dict[tuple[str, str], dict[str, Any]] = {}
    for index, observation in enumerate(observations):
        label = f"observations[{index}]"
        _require(isinstance(observation, dict), f"{label} 必須是 object。")
        kind, symbol = observation.get("kind"), observation.get("symbol")
        _require(kind in ("benchmark", "stock"), f"{label}.kind 無效。")
        _require(isinstance(symbol, str) and bool(symbol),
                 f"{label}.symbol 缺漏。")
        label = f"{kind}/{symbol}"
        key = (kind, symbol)
        _require(key not in verified, f"{label} 的實測紀錄重複。")

        market = observation.get("market")
        _require(market in ("us", "tw"), f"{label}.market 無效。")
        _require(observation.get("currency") ==
                 ("USD" if market == "us" else "TWD"),
                 f"{label} 市場與幣別不一致。")
        _require(observation.get("is_cached") is False,
                 f"{label} 不可使用快取冒充實測。")
        _require(observation.get("is_stale") is False,
                 f"{label} 不可使用過期資料。")
        source = observation.get("source")
        _require(isinstance(source, str) and "yahoo" in source.lower() and
                 _NON_REAL_SOURCE.search(source) is None,
                 f"{label} 必須是實際 Yahoo 行情來源。")
        _number(observation.get("provider_price"),
                f"{label}.provider_price", positive=True)
        count = observation.get("completed_daily_bars")
        _require(type(count) is int and count >= 61,
                 f"{label} 需要至少 61 筆完整日 K。")
        _number(observation.get("adr_20_percent"),
                f"{label}.adr_20_percent", minimum=0)
        for field in ("ema_9", "ema_21", "ema_50"):
            _number(observation.get(field), f"{label}.{field}", positive=True)
        # An optional probe can publish valid daily evidence before its RS
        # evaluation fails. Its recorded error must not invalidate the required
        # five successful probes. Never allow this exception for required data.
        optional_rs_failure = (kind == "stock" and
                               symbol not in REQUIRED_SYMBOLS and
                               symbol in errors and
                               "rs_raw_excess_percent" not in observation)
        if kind == "stock" and not optional_rs_failure:
            _number(observation.get("rs_raw_excess_percent"),
                    f"{label}.rs_raw_excess_percent")
        verified[key] = observation

    for symbol in REQUIRED_SYMBOLS:
        observation = verified.get(("stock", symbol))
        _require(observation is not None, f"缺少必需股票 {symbol} 的實測資料。")
        expected_market = "tw" if symbol.endswith(".TW") else "us"
        _require(observation["market"] == expected_market,
                 f"必需股票 {symbol} 的市場錯誤。")
    for symbol, (market, currency) in REQUIRED_BENCHMARKS.items():
        observation = verified.get(("benchmark", symbol))
        _require(observation is not None, f"缺少必需大盤 {symbol} 的實測資料。")
        _require(observation["market"] == market and
                 observation["currency"] == currency,
                 f"必需大盤 {symbol} 的市場或幣別錯誤。")

    candidates = report.get("candidates")
    _require(isinstance(candidates, list), "candidates 必須是 list，可為空。")
    candidate_count = report.get("candidate_count")
    _require(type(candidate_count) is int and candidate_count == len(candidates),
             "candidate_count 與實際 candidates 數量不一致。")
    # Individual entry/stop/sizing assertions belong to the real Dart scan.
    _require(all(isinstance(candidate, dict) for candidate in candidates),
             "每筆推薦必須是 object。")
    expected_status = ("qualified_entries" if candidate_count
                       else "no_qualified_entry")
    _require(report.get("recommendation_status") == expected_status,
             "recommendation_status 與候選數量不一致。")
    return candidate_count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path,
                        help="build/live-scan-evidence.json")
    args = parser.parse_args(argv)
    try:
        with args.evidence.open(encoding="utf-8") as stream:
            report = json.load(stream)
        count = validate_evidence(report)
    except (OSError, UnicodeError, json.JSONDecodeError, ValidationError) as error:
        print(f"[GATE FAILED] {error}", file=sys.stderr)
        return 1
    print(f"[GATE PASSED] 真實行情與指標驗證通過；合格推薦 {count}（可為 0）。")
    if count == 0:
        print("[NO QUALIFIED ENTRY] 目前沒有合格買點，建置仍可繼續；選股門檻維持不變。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

## scripts/tests/test_live_scan_evidence.py

```python
"""Offline tests for the evidence contract, never fixtures for the live scan."""

from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


VALIDATOR_PATH = Path(__file__).resolve().parents[1] / "validate_live_scan_evidence.py"
SPEC = importlib.util.spec_from_file_location("live_scan_evidence", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


def healthy_report() -> dict:
    """A schema fixture for validator tests, not evidence of a live API call."""
    observations = []
    for kind, symbol in (
        ("benchmark", "^GSPC"), ("benchmark", "^TWII"),
        *(("stock", symbol) for symbol in validator.REQUIRED_SYMBOLS),
    ):
        market = "tw" if symbol.endswith(".TW") or symbol == "^TWII" else "us"
        observation = {
            "kind": kind, "symbol": symbol, "market": market,
            "currency": "TWD" if market == "tw" else "USD",
            "provider_price": 100.0, "completed_daily_bars": 100,
            "adr_20_percent": 2.0, "ema_9": 99.0,
            "ema_21": 98.0, "ema_50": 97.0,
            "source": "Yahoo Finance HTTPS chart",
            "is_cached": False, "is_stale": False,
        }
        if kind == "stock":
            observation["rs_raw_excess_percent"] = -1.25
        observations.append(observation)
    return {
        "schema_version": 2, "verification_mode": "real_market_health",
        "use_mock_data": False, "status": "passed",
        "benchmarks_verified": True, "required_symbols_verified": True,
        "indicators_verified": True,
        "required_symbols": list(validator.REQUIRED_SYMBOLS),
        "whole_run_deadline_seconds": 15, "elapsed_ms": 14999,
        "observations": observations, "errors": {},
        "candidates": [], "candidate_count": 0,
        "recommendation_status": "no_qualified_entry",
    }


class EvidenceTests(unittest.TestCase):
    def test_healthy_data_with_no_entry_is_allowed(self) -> None:
        # ADR may fall below entry thresholds and RS may be negative. Those are
        # legitimate market observations, not a data-health failure.
        self.assertEqual(validator.validate_evidence(healthy_report()), 0)

    def test_actual_candidate_count_is_returned(self) -> None:
        report = healthy_report()
        # Candidate internals are checked by Dart, not redefined by Python.
        report.update(candidates=[{"symbol": "NVDA"}], candidate_count=1,
                      recommendation_status="qualified_entries")
        self.assertEqual(validator.validate_evidence(report), 1)

    def test_optional_symbol_failure_does_not_hide_required_success(self) -> None:
        report = healthy_report()
        report["errors"] = {"OPTIONAL": "HTTP 429"}
        self.assertEqual(validator.validate_evidence(report), 0)

    def test_optional_rs_failure_can_leave_partial_daily_evidence(self) -> None:
        report = healthy_report()
        optional = deepcopy(report["observations"][2])
        optional["symbol"] = "OPTIONAL"
        del optional["rs_raw_excess_percent"]
        report["observations"].append(optional)
        report["errors"] = {"OPTIONAL": "insufficient common RS dates"}
        self.assertEqual(validator.validate_evidence(report), 0)
        # A missing RS without an explicit optional-probe error is incomplete
        # evidence rather than an acknowledged, isolated provider failure.
        report["errors"].clear()
        with self.assertRaises(validator.ValidationError):
            validator.validate_evidence(report)

    def test_old_failed_mock_or_unverified_reports_are_rejected(self) -> None:
        for field, value in (
            ("schema_version", 1), ("schema_version", True),
            ("verification_mode", "strict_entry"), ("status", "failed"),
            ("status", "running"), ("use_mock_data", True),
            ("use_mock_data", 0), ("benchmarks_verified", False),
            ("required_symbols_verified", False), ("indicators_verified", 1),
            ("failure", "provider refused connection"),
        ):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report[field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_missing_required_stock_or_benchmark_is_rejected(self) -> None:
        for symbol in (*validator.REQUIRED_SYMBOLS, *validator.REQUIRED_BENCHMARKS):
            with self.subTest(symbol=symbol):
                report = healthy_report()
                report["observations"] = [observation for observation in
                                          report["observations"]
                                          if observation["symbol"] != symbol]
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_required_failure_is_rejected_even_with_matching_observation(self) -> None:
        for symbol in (*validator.REQUIRED_SYMBOLS, *validator.REQUIRED_BENCHMARKS):
            with self.subTest(symbol=symbol):
                report = healthy_report()
                report["errors"][symbol] = "timed out"
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_required_symbol_list_cannot_be_reduced_or_duplicated(self) -> None:
        for symbols in (["NVDA"], ["NVDA"] * 5, "NVDA", [None] * 5):
            with self.subTest(symbols=symbols):
                report = healthy_report()
                report["required_symbols"] = symbols
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_wrong_market_or_currency_is_rejected(self) -> None:
        for field, value in (("currency", "TWD"), ("market", "tw"),
                             ("market", "unknown")):
            with self.subTest(field=field):
                report = healthy_report()
                report["observations"][0][field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_cache_stale_or_fake_source_is_rejected(self) -> None:
        for field, value in (("is_cached", True), ("is_stale", True),
                             ("is_cached", 0), ("is_stale", None),
                             ("source", "local fixture"),
                             ("source", "Yahoo Finance mock")):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report["observations"][0][field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_missing_nonfinite_or_invalid_indicator_is_rejected(self) -> None:
        for field in ("provider_price", "adr_20_percent", "ema_9", "ema_21",
                      "ema_50", "rs_raw_excess_percent"):
            for value in (None, float("nan"), float("inf"), -float("inf"), True):
                with self.subTest(field=field, value=value):
                    report = healthy_report()
                    report["observations"][2][field] = value
                    with self.assertRaises(validator.ValidationError):
                        validator.validate_evidence(report)
        for field, value in (("provider_price", 0), ("ema_9", 0),
                             ("adr_20_percent", -1),
                             ("completed_daily_bars", 60),
                             ("completed_daily_bars", 61.0)):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report["observations"][2][field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_deadline_and_elapsed_time_are_enforced(self) -> None:
        for field, value in (("elapsed_ms", 15001), ("elapsed_ms", -1),
                             ("elapsed_ms", float("nan")),
                             ("elapsed_ms", True), ("elapsed_ms", "100"),
                             ("whole_run_deadline_seconds", 90)):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report[field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)
        report = healthy_report()
        report["elapsed_ms"] = 15000
        self.assertEqual(validator.validate_evidence(report), 0)

    def test_count_and_recommendation_status_must_agree(self) -> None:
        for changes in (
            {"candidate_count": 1}, {"candidate_count": False},
            {"candidates": None}, {"candidates": ["NVDA"], "candidate_count": 1},
            {"recommendation_status": "qualified_entries"},
            {"candidates": [{}], "candidate_count": 1},
        ):
            with self.subTest(changes=changes):
                report = healthy_report()
                report.update(changes)
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_duplicate_observation_is_rejected(self) -> None:
        report = healthy_report()
        report["observations"].append(deepcopy(report["observations"][0]))
        with self.assertRaises(validator.ValidationError):
            validator.validate_evidence(report)

    def test_cli_exit_code_allows_no_entry_but_blocks_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            report = healthy_report()
            output.write_text(json.dumps(report), encoding="utf-8")
            result = subprocess.run([sys.executable, str(VALIDATOR_PATH), str(output)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[GATE PASSED]", result.stdout)
            self.assertIn("[NO QUALIFIED ENTRY]", result.stdout)
            report["status"] = "failed"
            output.write_text(json.dumps(report), encoding="utf-8")
            result = subprocess.run([sys.executable, str(VALIDATOR_PATH), str(output)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("[GATE FAILED]", result.stderr)

    def test_cli_missing_or_invalid_file_fails_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            for content in (None, "{bad json", "null"):
                with self.subTest(content=content):
                    if content is not None:
                        output.write_text(content, encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, str(VALIDATOR_PATH), str(output)],
                        capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("[GATE FAILED]", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
```
