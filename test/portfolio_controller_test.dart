import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'support/mock_preferences.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/exit_advisory_engine.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

class FailingQuotes implements PortfolioRepository {
  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {
    bool forceRefresh = false,
  }) async {
    throw StateError('行情服務無法連線');
  }
  @override
  void close() {}
}

class DeferredQuotes implements PortfolioRepository {
  final response = Completer<PortfolioQuoteSnapshot>();
  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {
    bool forceRefresh = false,
  }) => response.future;
  @override
  void close() {}
}

PortfolioPosition unknown({double entry = 100, double stop = 98}) => PortfolioPosition(
  id: 'own-test', symbol: 'ZZTEST', market: StockMarket.us,
  entryPrice: entry, shares: 50, initialStop: stop);

void main() {
  setUp(seedMockPreferences);

  test('demo seeds both markets; unknown symbol never gets invented latest quotes', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.portfolioPositions.map((p) => p.market).toSet(), StockMarket.values.toSet());
    await controller.savePortfolioPosition(unknown());
    expect(controller.portfolioQuotes['us:ZZTEST'], isNull);
    expect(controller.portfolioErrors['us:ZZTEST'], contains('固定假行情'));
    expect(controller.diagnosisFor(unknown()), isNull);
  });

  test('peak/stop/manual quote survive refresh and restart; a new R basis resets', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await controller.savePortfolioPosition(unknown());
    final now = DateTime.utc(2026, 10, 13, 15);
    await controller.setMockPortfolioQuote(PortfolioQuote(
      symbol: 'ZZTEST', name: '情境測試', market: StockMarket.us,
      currentPrice: 104, ema9: 100, ema21: 98, ema50: 95,
      lastClose: 100, closeConfirmed: true, quoteTimestamp: now,
      closeTimestamp: now, source: 'manual fictitious', isLargeLiquid: false));
    await controller.refreshPortfolio();
    expect(controller.portfolioPositions.firstWhere((p) => p.id == 'own-test').peakR, 2);
    final reloaded = AppController();
    addTearDown(reloaded.dispose);
    await reloaded.initialize(initializeReminders: false);
    final held = reloaded.portfolioPositions.firstWhere((p) => p.id == 'own-test');
    expect(held.peakR, 2);
    expect(held.trailingStop, 100);
    expect(reloaded.portfolioQuotes[held.key]!.currentPrice, 104);
    await reloaded.savePortfolioPosition(unknown(entry: 105, stop: 100));
    final reset = reloaded.portfolioPositions.firstWhere((p) => p.id == 'own-test');
    expect(reset.peakR, 0);
    expect(reset.trailingStop, 100);
    expect(reloaded.diagnosisFor(reset)?.action, ExitAction.hold);
  });

  test('duplicate symbol cannot bypass exposure; delete persists without reseeding', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await expectLater(controller.savePortfolioPosition(PortfolioPosition(
      id: 'duplicate', symbol: 'NVDA', market: StockMarket.us,
      entryPrice: 100, shares: 50, initialStop: 98)), throwsArgumentError);
    for (final holding in controller.portfolioPositions) {
      await controller.deletePortfolioPosition(holding.id);
    }
    final reloaded = AppController();
    addTearDown(reloaded.dispose);
    await reloaded.initialize(initializeReminders: false);
    expect(reloaded.portfolioPositions, isEmpty);
  });

  test('API quote failure retains holding and never falls back to demo', () async {
    final controller = AppController(portfolioRepositoryFactory: (_) => FailingQuotes());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.portfolioPositions.length, 4);
    expect(controller.portfolioQuotes, isEmpty);
    expect(controller.portfolioErrors.length, 4);
    expect(controller.portfolioErrors.values.every((message) => message.contains('無法連線')), isTrue);
    expect(controller.portfolioLoading, isFalse);
  });

  test('mock observation cannot arm a live stop; source history restores separately', () async {
    final controller = AppController(
      repositoryFactory: (_) => MockCandidateRepository(),
      portfolioRepositoryFactory: (settings) => settings.useMockData
        ? MockPortfolioRepository() : FailingQuotes(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final demo = controller.portfolioPositions.firstWhere((p) => p.symbol == 'NVDA');
    expect(demo.peakR, 5);
    expect(demo.trailingStop, 100);
    await controller.updateSettings(controller.settings.copyWith(useMockData: false));
    final live = controller.portfolioPositions.firstWhere((p) => p.id == demo.id);
    expect(live.peakR, 0);
    expect(live.trailingStop, 98);
    expect(controller.portfolioQuotes, isEmpty);
    final reloaded = AppController(
      repositoryFactory: (_) => MockCandidateRepository(),
      portfolioRepositoryFactory: (_) => FailingQuotes(),
    );
    addTearDown(reloaded.dispose);
    await reloaded.initialize(initializeReminders: false);
    expect(reloaded.portfolioPositions.firstWhere((p) => p.id == demo.id).trailingStop, 98);
    await controller.updateSettings(controller.settings.copyWith(useMockData: true));
    expect(controller.portfolioPositions.firstWhere((p) => p.id == demo.id).peakR, 5);
    expect(controller.portfolioPositions.firstWhere((p) => p.id == demo.id).trailingStop, 100);
  });

  test('source switch invalidates a pending mock fetch before persistence awaits', () async {
    final deferred = DeferredQuotes();
    var defer = false;
    final controller = AppController(
      repositoryFactory: (_) => MockCandidateRepository(),
      portfolioRepositoryFactory: (settings) => !settings.useMockData ? FailingQuotes() :
        defer ? deferred : MockPortfolioRepository(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    defer = true;
    final old = controller.refreshPortfolio();
    final changed = controller.updateSettings(controller.settings.copyWith(useMockData: false));
    // updateSettings applies invalidation synchronously, before its first await.
    expect(controller.settings.useMockData, isFalse);
    expect(controller.portfolioQuotes, isEmpty);
    expect(controller.portfolioPositions.firstWhere((p) => p.symbol == 'NVDA').peakR, 0);
    final fake = await MockPortfolioRepository().fetch(StockMarket.tw, ['2330.TW', '3017.TW']);
    deferred.response.complete(fake);
    await old;
    await changed;
    expect(controller.portfolioQuotes, isEmpty);
    expect(controller.portfolioPositions.firstWhere((p) => p.symbol == 'NVDA').trailingStop, 98);
  });

  test('editing initial risk clears all source observations', () async {
    final controller = AppController(
      repositoryFactory: (_) => MockCandidateRepository(),
      portfolioRepositoryFactory: (settings) => settings.useMockData
        ? MockPortfolioRepository() : FailingQuotes(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await controller.updateSettings(controller.settings.copyWith(useMockData: false));
    final previous = controller.portfolioPositions.firstWhere((p) => p.symbol == 'NVDA');
    await controller.savePortfolioPosition(PortfolioPosition(
      id: previous.id, symbol: previous.symbol, market: previous.market,
      entryPrice: 112, shares: previous.shares, initialStop: 109));
    await controller.updateSettings(controller.settings.copyWith(useMockData: true));
    final edited = controller.portfolioPositions.firstWhere((p) => p.id == previous.id);
    expect(edited.peakR, 0);
    expect(edited.trailingStop, 109);
  });
}
