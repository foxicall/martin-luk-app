import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

class DeferredRepository implements CandidateRepository {
  final requests = <StockMarket, Completer<CandidateSnapshot>>{};

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {required double adrThreshold}) {
    final request = Completer<CandidateSnapshot>();
    requests[market] = request;
    return request.future;
  }
}

class FailingRepository implements CandidateRepository {
  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {required double adrThreshold}) async {
    throw const RepositoryException('測試：API 不可用');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('mock market pages, threshold, sorts and distinct currency equities', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.market, StockMarket.tw);
    expect(controller.snapshot?.source, '離線示範');
    expect(controller.pageCount, 2);
    expect(controller.visibleCandidates.length, 6);
    controller.setPage(1);
    expect(controller.visibleCandidates.length, 2);
    controller.setSort(CandidateSort.adr);
    expect(controller.page, 0);
    final highest = controller.visibleCandidates.first.adrPercent;
    expect(controller.visibleCandidates.every((row) => row.adrPercent <= highest), isTrue);
    await controller.setEquity(StockMarket.tw, 2000000);
    await controller.setMarket(StockMarket.us);
    expect(controller.equity, 50000);
    await controller.setMarket(StockMarket.tw);
    expect(controller.equity, 2000000);
    await controller.updateSettings(controller.settings.copyWith(twAdrThreshold: 6));
    expect(controller.visibleCandidates.every((row) => row.adrPercent >= 6), isTrue);
  });

  test('older completed request cannot overwrite a newer market snapshot', () async {
    final repository = DeferredRepository();
    final controller = AppController(repositoryFactory: (_) => repository);
    addTearDown(controller.dispose);
    final first = controller.refresh();
    final second = controller.setMarket(StockMarket.us);
    final mock = MockCandidateRepository();
    repository.requests[StockMarket.us]!.complete(await mock.fetch(StockMarket.us, adrThreshold: 5));
    await second;
    repository.requests[StockMarket.tw]!.complete(await mock.fetch(StockMarket.tw, adrThreshold: 3.5));
    await first;
    expect(controller.market, StockMarket.us);
    expect(controller.snapshot!.candidates.every((row) => row.market == StockMarket.us), isTrue);
    expect(controller.loading, isFalse);
  });

  test('live failure is visible and never becomes an offline result', () async {
    final controller = AppController(repositoryFactory: (_) => FailingRepository());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot, isNull);
    expect(controller.error, contains('API 不可用'));
    expect(controller.visibleCandidates, isEmpty);
  });

  test('invalid equity fails and retains the earlier balance', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await expectLater(controller.setEquity(StockMarket.tw, double.nan), throwsArgumentError);
    expect(controller.equity, 1000000);
  });
}
