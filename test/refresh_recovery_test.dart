import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ScanCall {
  _ScanCall(this.market, this.force, this.quotesOnly);
  final StockMarket market;
  final bool force;
  final bool quotesOnly;
}

class _Scans implements CandidateRepository {
  final calls = <_ScanCall>[];
  Completer<CandidateSnapshot>? deferred;
  Object? failure;
  CandidateSnapshot? supplied;
  String source = 'Yahoo Finance fixture';

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls.add(_ScanCall(market, forceRefresh, refreshQuotesOnly));
    final error = failure;
    if (error != null) throw error;
    if (deferred != null) return deferred!.future;
    return supplied ?? _snapshot(source);
  }
}

class _Quotes implements PortfolioRepository {
  final calls = <bool>[];
  final markets = <StockMarket>[];
  Completer<PortfolioQuoteSnapshot>? deferred;
  Object? failure;
  StockMarket? failureMarket;
  final supplied = <StockMarket, PortfolioQuoteSnapshot>{};
  double price = 101;
  StockMarket? deferredMarket;
  int closes = 0;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols,
      {bool forceRefresh = false}) async {
    calls.add(forceRefresh);
    markets.add(market);
    final error = failure;
    if (error != null && (failureMarket == null || failureMarket == market)) throw error;
    if (deferred != null && (deferredMarket == null || deferredMarket == market)) {
      return deferred!.future;
    }
    return supplied[market] ?? _quotes(market, symbols, price: price);
  }

  @override
  void close() => closes++;
}

CandidateSnapshot _snapshot(String source) => CandidateSnapshot(
  candidates: [], fetchedAt: DateTime.utc(2026, 10, 14, 15), warnings: [],
  source: source, universeCount: 500, stale: false,
);

PortfolioQuoteSnapshot _quotes(StockMarket market, List<String> symbols,
    {double price = 101}) => PortfolioQuoteSnapshot(quotes: {
  for (final symbol in symbols) symbol: PortfolioQuote(
    symbol: symbol, name: symbol, market: market,
    currentPrice: price, ema9: 100, ema21: 99, ema50: 95,
    lastClose: 101, closeConfirmed: true,
    quoteTimestamp: DateTime.utc(2026, 10, 14, 15),
    closeTimestamp: DateTime.utc(2026, 10, 13, 20),
    source: 'Yahoo Finance fixture', isLargeLiquid: true,
  ),
}, errors: {}, source: 'Yahoo Finance fixture');

PortfolioPosition _holding({bool taiwan = false}) => PortfolioPosition(
  id: taiwan ? 'own-2330' : 'own-nvda',
  symbol: taiwan ? '2330.TW' : 'NVDA',
  market: taiwan ? StockMarket.tw : StockMarket.us,
  entryPrice: 100, shares: 80, initialStop: 98,
);

StockCandidate _candidate(String symbol, {StockMarket market = StockMarket.tw,
    double stop = 98}) => StockCandidate(
  id: '${market.name}:$symbol', symbol: symbol, name: symbol, sector: '半導體',
  market: market, adrPercent: 6, rsScore: 90, rsRank: 1,
  patterns: ['PDH 突破', '均線密集收斂'], entryPrice: 100, stopPrice: stop,
  dayLow: stop, triggerType: 'PDH', isLargeLiquid: true, status: 'confirmed',
  dataTimestamp: DateTime.utc(2026, 10, 14, 15),
  signalTimestamp: DateTime.utc(2026, 10, 14, 15),
  ema9: 99, ema21: 98.9, ema50: 98.8,
);

CandidateSnapshot _candidateSnapshot(List<StockCandidate> candidates,
    {String source = 'Yahoo Finance fixture'}) => CandidateSnapshot(
  candidates: candidates, fetchedAt: DateTime.utc(2026, 10, 14, 15), warnings: [],
  source: source, universeCount: 500, evaluatedCount: 500, stale: false,
);

void _store({List<PortfolioPosition> holdings = const []}) {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(const AppSettings().toJson()),
    'martin_luk_portfolio_v1': jsonEncode({
      'positions': holdings.map((holding) => holding.toJson()).toList(),
      'observations': <String, Object>{},
    }),
  });
}

AppController _controller(_Scans scans, {_Quotes? quotes,
    RepositoryFactory? repositoryFactory,
    PortfolioRepositoryFactory? portfolioRepositoryFactory,
    DateTime Function()? now,
    Duration updateTimeout = const Duration(milliseconds: 50),
    PreferenceWriter? preferenceWriter}) => AppController(
  repositoryFactory: repositoryFactory ?? (_) => scans,
  portfolioRepositoryFactory: portfolioRepositoryFactory ?? (_) => quotes ?? _Quotes(),
  pollingInterval: const Duration(hours: 1),
  scanUpdateTimeout: updateTimeout,
  portfolioUpdateTimeout: updateTimeout,
  storageTimeout: const Duration(milliseconds: 30),
  preferenceWriter: preferenceWriter,
  now: now ?? () => DateTime.utc(2026, 10, 14, 15),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_store);

  test('invalid candidate rows do not discard valid stocks or relax their stop', () async {
    final good = _candidate('2330.TW');
    final scans = _Scans()..supplied = _candidateSnapshot([
      good, _candidate('NVDA', market: StockMarket.us), good,
      _candidate('2603.TW', stop: 80),
    ]);
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot!.candidates.map((stock) => stock.symbol), ['2330.TW']);
    expect(controller.snapshot!.candidates.single.stopPrice, 98);
    expect(controller.snapshot!.candidates.single.status, 'confirmed');
    expect(controller.snapshot!.warnings.where((warning) => warning.contains('已排除')).length, 3);
    expect(controller.snapshot!.missingSymbols, containsAll(['NVDA', '2603.TW']));
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
  });

  test('all-invalid scan retains verified cache but a successful empty scan clears it', () async {
    final scans = _Scans()..supplied = _candidateSnapshot([_candidate('2330.TW')]);
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final originalTime = controller.snapshot!.generatedAt;
    scans.supplied = _candidateSnapshot([_candidate('2603.TW', stop: 80)]);
    await controller.refresh();
    expect(controller.snapshot!.candidates.single.symbol, '2330.TW');
    expect(controller.snapshot!.generatedAt, originalTime);
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.error, contains('全部無效'));
    scans.supplied = _candidateSnapshot([]);
    await controller.refresh();
    expect(controller.snapshot!.candidates, isEmpty);
    expect(controller.snapshot!.stale, isFalse);
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
  });

  test('production rejects demo scan source without replacing healthy cache', () async {
    final scans = _Scans()..supplied = _candidateSnapshot([_candidate('2330.TW')]);
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.supplied = _candidateSnapshot([_candidate('2603.TW')], source: '離線示範');
    await controller.refresh();
    expect(controller.snapshot!.source, 'Yahoo Finance fixture');
    expect(controller.snapshot!.candidates.single.symbol, '2330.TW');
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.error, contains('來源'));
  });

  test('zero evaluated stocks is a source failure rather than a successful empty scan', () async {
    final scans = _Scans()..supplied = _candidateSnapshot([_candidate('2330.TW')]);
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.supplied = CandidateSnapshot(candidates: [],
        fetchedAt: DateTime.utc(2026, 10, 14, 15), warnings: [],
        source: 'Yahoo Finance fixture', universeCount: 500,
        evaluatedCount: 0, stale: false, missingSymbols: ['2330.TW']);
    await controller.refresh();
    expect(controller.snapshot!.candidates.single.symbol, '2330.TW');
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.error, contains('未成功評估任何股票'));
    expect(controller.loading, isFalse);
  });

  test('one failed market retains its cache while the other observes fresh 2R', () async {
    _store(holdings: [_holding(taiwan: true), _holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes
      ..failure = StateError('TW HTTP 503')
      ..failureMarket = StockMarket.tw
      ..price = 104;
    await controller.refreshPortfolio();
    expect(controller.portfolioQuotes['tw:2330.TW']!.currentPrice, 101);
    expect(controller.isPortfolioQuoteCached('tw:2330.TW'), isTrue);
    expect(controller.portfolioErrors['tw:2330.TW'], contains('TW HTTP 503'));
    expect(controller.portfolioQuotes['us:NVDA']!.currentPrice, 104);
    expect(controller.isPortfolioQuoteCached('us:NVDA'), isFalse);
    expect(controller.portfolioPositions.firstWhere((holding) => holding.market == StockMarket.us).peakR, 2);
    expect(controller.portfolioLoading, isFalse);
  });

  test('one mismatched quote preserves that cache and accepts healthy sibling', () async {
    final tesla = PortfolioPosition(id: 'own-tsla', symbol: 'TSLA',
        market: StockMarket.us, entryPrice: 100, shares: 80, initialStop: 98);
    _store(holdings: [_holding(), tesla]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final healthy = _quotes(StockMarket.us, ['TSLA'], price: 104).quotes['TSLA']!;
    quotes.supplied[StockMarket.us] = PortfolioQuoteSnapshot(
        quotes: {'NVDA': healthy, 'TSLA': healthy}, errors: {}, source: 'Yahoo Finance fixture');
    await controller.refreshPortfolio();
    expect(controller.portfolioQuotes['us:NVDA']!.currentPrice, 101);
    expect(controller.isPortfolioQuoteCached('us:NVDA'), isTrue);
    expect(controller.portfolioErrors['us:NVDA'], contains('代碼'));
    expect(controller.portfolioQuotes['us:TSLA']!.currentPrice, 104);
    expect(controller.portfolioErrors.containsKey('us:TSLA'), isFalse);
    expect(controller.portfolioPositions.firstWhere((holding) => holding.symbol == 'TSLA').peakR, 2);
    expect(controller.portfolioLoading, isFalse);
  });

  test('one unrepresentable diagnosis cannot abort a healthy holding observation', () async {
    final tesla = PortfolioPosition(id: 'own-tsla', symbol: 'TSLA',
        market: StockMarket.us, entryPrice: 100, shares: 80, initialStop: 98);
    _store(holdings: [_holding(), tesla]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes.supplied[StockMarket.us] = PortfolioQuoteSnapshot(quotes: {
      'NVDA': _quotes(StockMarket.us, ['NVDA'], price: 1e308).quotes['NVDA']!,
      'TSLA': _quotes(StockMarket.us, ['TSLA'], price: 104).quotes['TSLA']!,
    }, errors: {}, source: 'Yahoo Finance fixture');
    await controller.refreshPortfolio();
    expect(controller.portfolioErrors['us:NVDA'], contains('診斷失敗'));
    expect(controller.portfolioPositions.firstWhere((holding) => holding.symbol == 'NVDA').peakR, 0.5);
    expect(controller.portfolioPositions.firstWhere((holding) => holding.symbol == 'TSLA').peakR, 2);
    expect(controller.portfolioLoading, isFalse);
  });

  test('partial source warnings are bounded and deduplicated without aging healthy quotes', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final healthy = _quotes(StockMarket.us, ['NVDA'], price: 104);
    quotes.supplied[StockMarket.us] = PortfolioQuoteSnapshot(
      quotes: healthy.quotes, errors: {}, source: healthy.source,
      warnings: ['跳過未知股票 ZZZ', '跳過未知股票 ZZZ',
        ...List.generate(20, (index) => '$index：${List.filled(400, '測').join()}')],
    );
    await controller.refreshPortfolio();
    final notice = controller.portfolioNotice!;
    expect(notice.split('跳過未知股票 ZZZ').length - 1, 1);
    expect(notice.split('\n').length, 8);
    expect(notice.length, lessThan(2200));
    expect(controller.portfolioErrors, isEmpty);
    expect(controller.isPortfolioQuoteCached('us:NVDA'), isFalse);
    expect(controller.portfolioPositions.single.peakR, 2);
  });

  test('hung scan times out, clears loading, retains cache and permits retry', () async {
    final scans = _Scans();
    var factories = 0;
    final controller = _controller(scans, repositoryFactory: (_) {
      factories++;
      return scans;
    });
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final original = controller.snapshot!.generatedAt;
    scans.deferred = Completer<CandidateSnapshot>();
    await controller.refresh().timeout(const Duration(seconds: 1));
    expect(controller.loading, isFalse);
    expect(controller.error, contains('逾時'));
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.snapshot!.generatedAt, original);
    final expired = scans.deferred!;
    scans..deferred = null..source = 'Yahoo Finance retry';
    await controller.refresh();
    expect(factories, 2);
    expect(controller.error, isNull);
    expect(controller.snapshot!.source, 'Yahoo Finance retry');
    expired.complete(_snapshot('late expired response'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot!.source, 'Yahoo Finance retry');
  });

  test('scan owns its future before a listener can re-enter refresh', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = Completer<CandidateSnapshot>();
    final before = scans.calls.length;
    Future<void>? reentrant;
    controller.addListener(() {
      if (controller.loading && reentrant == null) {
        reentrant = controller.refresh(forceRefresh: false);
      }
    });
    final running = controller.refresh(forceRefresh: false);
    expect(identical(running, reentrant), isTrue);
    expect(scans.calls.length, before + 1);
    scans.deferred!.complete(_snapshot('Yahoo Finance fixture'));
    await running;
    expect(controller.loading, isFalse);
  });

  test('many forced pulls coalesce into exactly one forced follow-up', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = Completer<CandidateSnapshot>();
    final before = scans.calls.length;
    final background = controller.refresh(forceRefresh: false);
    final pulls = List.generate(8, (_) => controller.refresh());
    expect(pulls.every((future) => identical(future, pulls.first)), isTrue);
    final deferred = scans.deferred!;
    scans.deferred = null;
    deferred.complete(_snapshot('Yahoo Finance fixture'));
    await Future.wait([background, ...pulls]);
    expect(scans.calls.length, before + 2);
    expect(scans.calls.last.force, isTrue);
    expect(controller.loading, isFalse);
  });

  test('forced scan queue includes the poll wait in its caller deadline', () async {
    final scans = _Scans();
    final controller = _controller(scans,
        updateTimeout: const Duration(milliseconds: 200));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final first = Completer<CandidateSnapshot>();
    scans.deferred = first;
    final background = controller.refresh(forceRefresh: false);
    final forced = controller.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    final repeated = controller.refresh();
    expect(identical(forced, repeated), isTrue);
    final forcedStarted = Completer<CandidateSnapshot>();
    scans.deferred = forcedStarted;
    first.complete(_snapshot('Yahoo Finance fixture'));
    // Only 130ms remain from the original pull. A fresh 200ms allowance for
    // the queued child would miss this bound and keep the spinner alive.
    await Future.wait([background, forced, repeated])
        .timeout(const Duration(milliseconds: 170));
    expect(controller.loading, isFalse);
    expect(controller.error, contains('逾時'));
    scans.deferred = null;
    await controller.refresh();
    expect(controller.error, isNull);
    forcedStarted.completeError(StateError('late expired forced response'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isNull);
  });

  test('market switch settles old pull and ignores its late error', () async {
    final tw = _Scans();
    final us = _Scans()..source = 'Yahoo Finance US';
    var factories = 0;
    final controller = _controller(tw, repositoryFactory: (_) =>
        ++factories == 1 ? tw : us);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    tw.deferred = Completer<CandidateSnapshot>();
    final old = controller.refresh(forceRefresh: false);
    final queued = controller.refresh();
    await controller.setMarket(StockMarket.us);
    await Future.wait([old, queued]).timeout(const Duration(seconds: 1));
    expect(controller.market, StockMarket.us);
    expect(controller.snapshot!.source, 'Yahoo Finance US');
    tw.deferred!.completeError(StateError('late HTTP error'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.source, 'Yahoo Finance US');
    expect(controller.error, isNull);
  });

  test('hung holding batch times out, retires repository and retries', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    var factories = 0;
    final controller = _controller(scans, portfolioRepositoryFactory: (_) {
      factories++;
      return quotes;
    });
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes.deferred = Completer<PortfolioQuoteSnapshot>();
    await controller.refreshPortfolio().timeout(const Duration(seconds: 1));
    expect(controller.portfolioLoading, isFalse);
    expect(controller.portfolioErrors['us:NVDA'], contains('TimeoutException'));
    expect(controller.isPortfolioQuoteCached('us:NVDA'), isTrue);
    expect(quotes.closes, 1);
    final expired = quotes.deferred!;
    quotes..deferred = null..price = 104;
    await controller.refreshPortfolio();
    expect(factories, 2);
    expect(controller.portfolioQuotes['us:NVDA']!.currentPrice, 104);
    expect(controller.portfolioPositions.single.peakR, 2);
    expired.complete(_quotes(StockMarket.us, ['NVDA'], price: 140));
    await Future<void>.delayed(Duration.zero);
    expect(controller.portfolioQuotes['us:NVDA']!.currentPrice, 104);
    expect(controller.portfolioPositions.single.peakR, 2);
  });

  test('portfolio timeout is one budget for both markets', () async {
    _store(holdings: [_holding(taiwan: true), _holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes.deferred = Completer<PortfolioQuoteSnapshot>();
    final before = quotes.calls.length;
    await controller.refreshPortfolio();
    expect(quotes.calls.length, before + 1);
    expect(controller.portfolioErrors.keys, containsAll(['tw:2330.TW', 'us:NVDA']));
    expect(controller.portfolioLoading, isFalse);
  });

  test('first market observed 2R survives a later market deadline', () async {
    _store(holdings: [_holding(taiwan: true), _holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes
      ..price = 104
      ..deferredMarket = StockMarket.us
      ..deferred = Completer<PortfolioQuoteSnapshot>();
    await controller.refreshPortfolio();
    final holding = controller.portfolioPositions.firstWhere(
        (position) => position.market == StockMarket.tw);
    expect(holding.peakR, 2);
    expect(holding.trailingStop, holding.entryPrice);
    expect(controller.isPortfolioQuoteCached(holding.key), isFalse);
    expect(controller.portfolioErrors['us:NVDA'], contains('TimeoutException'));
    expect(controller.portfolioLoading, isFalse);
  });

  test('source switch during cache persistence cannot commit old notices or peaks', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final oldWrite = Completer<bool>();
    var hang = false;
    var blocked = false;
    final controller = _controller(scans, quotes: quotes,
        preferenceWriter: (key, value) {
          if (hang && !blocked && key == 'martin_luk_portfolio_v1') {
            blocked = true;
            return oldWrite.future;
          }
          return Future<bool>.value(true);
        });
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    hang = true;
    quotes.price = 110;
    final old = controller.refreshPortfolio();
    await Future<void>.delayed(Duration.zero);
    expect(blocked, isTrue);
    quotes.price = 101;
    await controller.updateSettings(controller.settings.copyWith(useMockData: true));
    await old;
    expect(controller.settings.useMockData, isTrue);
    expect(controller.portfolioPositions.single.peakR, 0.5);
    expect(controller.portfolioPositions.single.trailingStop, 98);
    oldWrite.completeError(StateError('expired source disk failure'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.portfolioPositions.single.peakR, 0.5);
    expect(controller.portfolioNotice, isNot(contains('expired source disk failure')));
    expect(controller.portfolioLoading, isFalse);
  });

  test('reentrant portfolio listener sees the same installed owner', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes.deferred = Completer<PortfolioQuoteSnapshot>();
    final before = quotes.calls.length;
    Future<void>? reentrant;
    controller.addListener(() {
      if (controller.portfolioLoading && reentrant == null) {
        reentrant = controller.refreshPortfolio(forceRefresh: false);
      }
    });
    final running = controller.refreshPortfolio(forceRefresh: false);
    expect(identical(running, reentrant), isTrue);
    expect(quotes.calls.length, before + 1);
    quotes.deferred!.complete(_quotes(StockMarket.us, ['NVDA']));
    await running;
    expect(controller.portfolioLoading, isFalse);
  });

  test('holding forced pulls share one follow-up', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes.deferred = Completer<PortfolioQuoteSnapshot>();
    final before = quotes.calls.length;
    final background = controller.refreshPortfolio(forceRefresh: false);
    final pulls = List.generate(8, (_) => controller.refreshPortfolio());
    expect(pulls.every((future) => identical(future, pulls.first)), isTrue);
    final deferred = quotes.deferred!;
    quotes.deferred = null;
    deferred.complete(_quotes(StockMarket.us, ['NVDA']));
    await Future.wait([background, ...pulls]);
    expect(quotes.calls.length, before + 2);
    expect(quotes.calls.last, isTrue);
    expect(controller.portfolioLoading, isFalse);
  });

  test('forced holding queue cannot reset its caller deadline', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes,
        updateTimeout: const Duration(milliseconds: 200));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final first = Completer<PortfolioQuoteSnapshot>();
    quotes.deferred = first;
    final background = controller.refreshPortfolio(forceRefresh: false);
    final forced = controller.refreshPortfolio();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    final repeated = controller.refreshPortfolio();
    expect(identical(forced, repeated), isTrue);
    final forcedStarted = Completer<PortfolioQuoteSnapshot>();
    quotes.deferred = forcedStarted;
    first.complete(_quotes(StockMarket.us, ['NVDA']));
    await Future.wait([background, forced, repeated])
        .timeout(const Duration(milliseconds: 170));
    expect(controller.portfolioLoading, isFalse);
    expect(controller.portfolioErrors['us:NVDA'], contains('TimeoutException'));
    quotes.deferred = null;
    await controller.refreshPortfolio();
    expect(controller.portfolioErrors, isEmpty);
    forcedStarted.completeError(StateError('late expired forced quote'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.portfolioErrors, isEmpty);
  });

  test('default hot-quote and holding indicators settle within eight seconds', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = AppController(repositoryFactory: (_) => scans,
        portfolioRepositoryFactory: (_) => quotes,
        now: () => DateTime.utc(2026, 10, 14, 15));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = Completer<CandidateSnapshot>();
    quotes.deferred = Completer<PortfolioQuoteSnapshot>();
    final elapsed = Stopwatch()..start();
    final futures = [controller.refresh(forceRefresh: false, refreshQuotesOnly: true),
      controller.refresh(refreshQuotesOnly: true),
      controller.refreshPortfolio(forceRefresh: false), controller.refreshPortfolio()];
    // The one-second allowance accommodates timer scheduling on CI; the
    // production timers themselves are eight seconds, including queued pulls.
    await Future.wait(futures).timeout(const Duration(seconds: 9));
    elapsed.stop();
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 9)));
    expect(controller.loading, isFalse);
    expect(controller.portfolioLoading, isFalse);
    scans.deferred = null;
    quotes.deferred = null;
    await Future.wait([controller.refresh(refreshQuotesOnly: true), controller.refreshPortfolio()]);
    expect(controller.error, isNull);
    expect(controller.portfolioErrors, isEmpty);
  });

  test('a failed initial scan automatically recovers with a bounded full poll', () async {
    final scans = _Scans()..failure = StateError('offline first launch');
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.snapshot!.candidates, isEmpty);
    scans.failure = null;
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(scans.calls.last.quotesOnly, isFalse);
    expect(scans.calls.last.force, isFalse);
    expect(controller.snapshot!.source, 'Yahoo Finance fixture');
    expect(controller.error, isNull);
    expect(controller.polling, isFalse);
    await controller.pollNow();
    expect(scans.calls.last.quotesOnly, isTrue);
  });

  test('poll uses hot quotes until the full scan reaches fifteen minutes', () async {
    final scans = _Scans();
    var clock = DateTime.utc(2026, 10, 14, 15);
    final controller = _controller(scans, now: () => clock);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(scans.calls.last.quotesOnly, isTrue);
    clock = clock.add(const Duration(minutes: 15));
    await controller.pollNow();
    expect(scans.calls.last.quotesOnly, isFalse);
    expect(scans.calls.last.force, isFalse);
    expect(controller.polling, isFalse);
    expect(controller.loading, isFalse);
  });

  test('a failed poll releases all flags and the next poll succeeds', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.failure = StateError('HTTP 503');
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.polling, isFalse);
    expect(controller.loading, isFalse);
    expect(controller.error, contains('HTTP 503'));
    final before = scans.calls.length;
    scans..failure = null..source = 'Yahoo Finance recovered poll';
    await controller.pollNow();
    expect(scans.calls.length, before + 1);
    expect(controller.polling, isFalse);
    expect(controller.error, isNull);
    expect(controller.snapshot!.source, 'Yahoo Finance recovered poll');
  });

  test('never-completing preferences cannot strand a holding refresh', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    var hang = false;
    final controller = _controller(scans, quotes: quotes,
        preferenceWriter: (key, value) => hang && key == 'martin_luk_portfolio_v1'
            ? Completer<bool>().future : Future<bool>.value(true));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    hang = true;
    quotes.price = 104;
    await controller.refreshPortfolio().timeout(const Duration(seconds: 1));
    expect(controller.portfolioLoading, isFalse);
    expect(controller.portfolioNotice, contains('儲存失敗'));
    expect(controller.portfolioPositions.single.peakR, 2);
    hang = false;
    quotes.price = 106;
    await controller.refreshPortfolio();
    expect(controller.portfolioLoading, isFalse);
    expect(controller.portfolioPositions.single.peakR, 3);
  });

  test('dispose settles active and queued updates without waiting for HTTP', () async {
    _store(holdings: [_holding()]);
    final scans = _Scans();
    final quotes = _Quotes();
    final controller = _controller(scans, quotes: quotes);
    await controller.initialize(initializeReminders: false);
    scans.deferred = Completer<CandidateSnapshot>();
    quotes.deferred = Completer<PortfolioQuoteSnapshot>();
    final futures = [controller.refresh(forceRefresh: false), controller.refresh(),
      controller.refreshPortfolio(forceRefresh: false), controller.refreshPortfolio()];
    final scanCount = scans.calls.length;
    final quoteCount = quotes.calls.length;
    controller.dispose();
    await Future.wait(futures).timeout(const Duration(seconds: 1));
    expect(controller.loading, isFalse);
    expect(controller.portfolioLoading, isFalse);
    expect(controller.polling, isFalse);
    scans.deferred!.completeError(StateError('closed HTTP client'));
    quotes.deferred!.completeError(StateError('closed quote client'));
    await Future<void>.delayed(Duration.zero);
    expect(scans.calls.length, scanCount);
    expect(quotes.calls.length, quoteCount);
    expect(quotes.closes, 1);
  });
}
