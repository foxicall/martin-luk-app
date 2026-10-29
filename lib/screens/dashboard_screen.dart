import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../models/stock_candidate.dart';
import '../models/hybrid_protocol.dart';
import '../models/stock_item.dart';
import '../services/candidate_repository.dart';
import '../services/strategy_engine.dart';
import '../widgets/stock_search_field.dart';
import 'calculator_screen.dart';
import 'portfolio_screen.dart';
import 'settings_screen.dart';

/// Market overview. All snapshots retain their source and timestamps; an API
/// failure is displayed explicitly and never relabelled as live mock prices.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  AppController get controller => widget.controller;
  StockItem? _selection;
  bool _finding = false;
  int _selectionVersion = 0;

  bool get _isMobileScan =>
      !controller.settings.useMockData &&
      controller.settings.dataProvider == 'direct';

  String get _marketShortLabel =>
      controller.market == StockMarket.tw ? '台股' : '美股';

  String get _marketDirectoryLabel =>
      controller.market == StockMarket.tw
          ? '台股上市／上櫃普通股名單'
          : '美股 NYSE／Nasdaq／NYSE American 普通股名單';

  bool _hasRoundCoverage(CandidateSnapshot? snapshot) =>
      snapshot != null &&
      !snapshot.isFallback &&
      snapshot.candidatesAreCumulative &&
      snapshot.universeCount > 0 &&
      snapshot.coverageTotalCount == snapshot.universeCount &&
      snapshot.coverageScannedCount != null &&
      snapshot.coverageEvaluatedCount != null &&
      snapshot.coverageRemainingCount != null;

  /// Display one round's membership and counters together. A directory probe
  /// can briefly report only one exchange; it must not relabel a saved full
  /// round as an 894-stock universe while its coverage still refers to 1979.
  CandidateSnapshot? get _mobileCoverageSnapshot {
    if (!_isMobileScan) return null;
    final progress = controller.marketScanProgress;
    final partial =
        controller.loading && progress?.market == controller.market
            ? controller.verifiedMarketPartialSnapshot
            : null;
    if (partial != null &&
        progress != null &&
        _hasRoundCoverage(partial) &&
        partial.universeCount == progress.universeCount &&
        partial.evaluatedCount == progress.evaluatedCount &&
        partial.scanPoolSize == progress.poolSize) {
      return partial;
    }
    final saved = controller.snapshot;
    return _hasRoundCoverage(saved) ? saved : null;
  }

  bool get _hasMobileCoverage => _mobileCoverageSnapshot != null;

  bool get _hasCumulativeCandidates =>
      _isMobileScan && (controller.snapshot?.candidatesAreCumulative ?? false);

  bool _requiresRefresh(StockCandidate stock) {
    if (controller.settings.useMockData) return false;
    if (controller.snapshot?.stale ?? false) return true;
    // The live engine accepts intraday quotes up to 15 minutes old. Apply the
    // same limit to retained cards outside the small foreground quote batch;
    // updating the batch's global timestamp cannot renew every card's quote.
    final age = DateTime.now().toUtc().difference(stock.dataTimestamp.toUtc());
    return age.isNegative || age > const Duration(minutes: 15);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insights_rounded, size: 27),
              SizedBox(width: 10),
              Flexible(
                child: Text(
                  '動能觀測站',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            if (controller.loading || controller.waitingForBackendScan)
              IconButton(
                key: const ValueKey('stop-market-evaluation'),
                tooltip: controller.waitingForBackendScan ? '停止查詢進度' : '停止掃描',
                onPressed: controller.cancelMarketEvaluation,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            IconButton(
              tooltip: '重新評估',
              onPressed:
                  controller.loading
                      ? null
                      : () => controller.refresh(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () => controller.refresh(forceRefresh: true),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildMarketSelector(context),
                          const SizedBox(height: 16),
                          StockSearchField(
                            key: const ValueKey('dashboard-stock-search'),
                            onSelected: _selectMetadata,
                            helperText: '跨市場離線搜尋：代碼、中文、英文或別名；選取不代表通過策略篩選。',
                          ),
                          if (_selection != null) ...[
                            const SizedBox(height: 12),
                            _buildSearchSelection(context),
                          ],
                          const SizedBox(height: 18),
                          _buildOverview(context),
                          if (controller.backendScanStatus != null) ...[
                            const SizedBox(height: 12),
                            _buildBackendProgress(context),
                          ],
                          if (controller.loading &&
                              !controller.waitingForBackendScan) ...[
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              key: const ValueKey('market-scan-progress'),
                              value:
                                  (controller.marketScanProgress?.poolSize ??
                                              0) >
                                          0
                                      ? controller.marketScanProgress!.fraction
                                      : null,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              controller.marketScanProgress?.label ??
                                  '正在準備市場評估…',
                              key: const ValueKey('market-scan-status'),
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ] else if (controller.marketScanProgress != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              controller.marketScanProgress!.label,
                              key: const ValueKey('market-scan-status'),
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ],
                          ..._buildWarnings(context),
                          const SizedBox(height: 24),
                          Text(
                            _hasCumulativeCandidates
                                ? '本輪累積推薦與觀察名單'
                                : '推薦與觀察名單',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _hasCumulativeCandidates
                                ? '各卡保留原行情時間與原掃描頁內 RS，並非全市場排名。'
                                    '確認突破與停損後才提供部位建議。'
                                : '確認突破與停損後才提供部位建議；點選個股可調整本金。',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 14),
                          _buildSorting(context),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                  if (controller.visibleCandidates.isNotEmpty)
                    _buildCandidateGrid(context)
                  else
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(child: _buildEmpty(context)),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        children: [
                          if (controller.filteredCount > 0)
                            _buildPagination(context),
                          if (controller.snapshot?.warnings.isNotEmpty ??
                              false) ...[
                            const SizedBox(height: 18),
                            _buildSourceDisclosures(context),
                          ],
                          const SizedBox(height: 18),
                          Text(
                            '資料更新時間與延遲依來源而異。策略訊號供研究與評估，'
                            '進場前請確認行情；0.5% 停損風險不含滑價與跳空。',
                            textAlign: TextAlign.center,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Future<void> _selectMetadata(StockItem stock) async {
    final version = ++_selectionVersion;
    setState(() {
      _selection = stock;
      _finding = true;
    });
    try {
      // The symbol determines the market and its independent capital. Search
      // must not relabel a US security as TW just because a TW tab was open.
      await controller.setMarket(stock.market);
      if (!mounted ||
          version != _selectionVersion ||
          controller.market != stock.market)
        return;
      StockCandidate? candidate;
      for (final row
          in controller.snapshot?.candidates ?? const <StockCandidate>[]) {
        if (row.symbol == stock.symbol && row.market == stock.market) {
          candidate = row;
          break;
        }
      }
      if (candidate != null) _openStock(context, candidate);
    } catch (error) {
      if (mounted && version == _selectionVersion) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已找到股票身份，評估讀取失敗：$error')));
      }
    } finally {
      if (mounted && version == _selectionVersion)
        setState(() => _finding = false);
    }
  }

  Widget _buildSearchSelection(BuildContext context) {
    final stock = _selection!;
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('dashboard-search-selection'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${stock.marketTag} · ${stock.symbol} · ${stock.displayName}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              stock.nameEn,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              _finding
                  ? '正在查詢該市場的評估快照…'
                  : '股票身份來自離線字典；若快照沒有此股，不產生行情、ADR 或突破建議。',
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed:
                  _finding
                      ? null
                      : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder:
                              (_) => PortfolioScreen(
                                controller: controller,
                                initialStock: stock,
                              ),
                        ),
                      ),
              icon: const Icon(Icons.add),
              label: const Text('將標準代碼帶入新增持股'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarketSelector(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 360;
      return Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<StockMarket>(
          segments: [
            ButtonSegment(
              value: StockMarket.tw,
              icon: const Icon(Icons.public),
              label: Text(compact ? '台股 · TW' : '台股上市櫃 · TW'),
            ),
            ButtonSegment(
              value: StockMarket.us,
              icon: const Icon(Icons.language),
              label: Text(compact ? '美股 · US' : '美股三大交易所 · US'),
            ),
          ],
          selected: {controller.market},
          onSelectionChanged: (markets) => controller.setMarket(markets.single),
          showSelectedIcon: false,
        ),
      );
    },
  );

  Widget _buildOverview(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final snapshot = controller.snapshot;
    final progress = controller.marketScanProgress;
    final backend = controller.backendScanStatus;
    final currentProgress =
        (controller.loading || snapshot == null) &&
                progress?.market == controller.market
            ? progress
            : null;
    final roundSnapshot = _mobileCoverageSnapshot ?? snapshot;
    final pageProgress =
        _hasMobileCoverage && currentProgress?.poolSize == 0
            ? null
            : currentProgress;
    // Old direct-mode caches can contain page counters without a cumulative
    // round. Only validated rolling snapshots can present those as coverage;
    // the server's separate coverage contract does not require this flag.
    final showCoverage = !_isMobileScan || _hasMobileCoverage;
    final coverageTotal =
        showCoverage
            ? backend?.coverageTotalCount ?? roundSnapshot?.coverageTotalCount
            : null;
    final coverageAttempted =
        showCoverage
            ? backend?.coverageScannedCount ??
                roundSnapshot?.coverageScannedCount
            : null;
    final coverageEvaluated =
        showCoverage
            ? backend?.coverageEvaluatedCount ??
                roundSnapshot?.coverageEvaluatedCount
            : null;
    final coverageRemaining =
        showCoverage
            ? backend?.coverageRemainingCount ??
                roundSnapshot?.coverageRemainingCount
            : null;
    final coverageRound =
        showCoverage
            ? backend?.coverageRound ?? roundSnapshot?.coverageRound
            : null;
    final pageStart =
        showCoverage
            ? backend?.scanPageStart ?? roundSnapshot?.scanPageStart
            : null;
    final pageSize =
        showCoverage
            ? backend?.scanPageSize ?? roundSnapshot?.scanPageSize
            : null;
    final threshold =
        controller.market == StockMarket.tw
            ? controller.settings.twAdrThreshold
            : controller.settings.usAdrThreshold;
    final confirmed =
        snapshot?.candidates
            .where(
              (stock) =>
                  stock.isConfirmed &&
                  !_requiresRefresh(stock) &&
                  stock.adrPercent >= threshold,
            )
            .length ??
        0;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primaryContainer, colors.secondaryContainer],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              Text(
                controller.market.label,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.onPrimaryContainer,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color:
                      controller.settings.useMockData
                          ? colors.tertiaryContainer
                          : colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  controller.settings.useMockData
                      ? 'OFFLINE MOCK · 離線示範'
                      : controller.settings.dataProvider == 'direct'
                      ? 'YAHOO · 連網行情'
                      : 'API · 掃描引擎',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Martin Luk 動能框架 · ADR × 相對強勢 × 突破',
            style: TextStyle(color: colors.onPrimaryContainer),
          ),
          const SizedBox(height: 12),
          _buildScanScope(context),
          const SizedBox(height: 16),
          Wrap(
            spacing: 28,
            runSpacing: 16,
            children: [
              _summary(
                context,
                _hasMobileCoverage ? '本輪名單' : '股票字典',
                '${_hasMobileCoverage ? coverageTotal : backend?.universeCount ?? currentProgress?.universeCount ?? snapshot?.universeCount ?? '—'}',
              ),
              if ((backend?.totalCount ??
                      pageProgress?.poolSize ??
                      roundSnapshot?.scanPoolSize) !=
                  null)
                _summary(
                  context,
                  controller.settings.dataProvider == 'direct' &&
                          !_hasMobileCoverage
                      ? '先前掃描池'
                      : '本頁掃描池',
                  '${backend?.totalCount ?? pageProgress?.poolSize ?? roundSnapshot?.scanPoolSize}',
                ),
              if ((backend?.evaluatedCount ??
                      pageProgress?.evaluatedCount ??
                      roundSnapshot?.evaluatedCount) !=
                  null)
                _summary(
                  context,
                  _hasMobileCoverage ? '本頁已評估' : '已評估',
                  '${backend?.evaluatedCount ?? pageProgress?.evaluatedCount ?? roundSnapshot?.evaluatedCount}',
                ),
              _summary(
                context,
                _hasMobileCoverage ? '本頁符合 ADR' : '目前符合 ADR',
                '${backend?.adrMatchCount ?? pageProgress?.adrMatchCount ?? roundSnapshot?.adrMatchCount ?? controller.filteredCount}',
              ),
              _summary(context, '已確認型態', '$confirmed'),
              if (_hasCumulativeCandidates)
                _summary(context, '本輪累積候選', '${snapshot!.candidates.length}'),
              _summary(context, 'ADR 門檻', '${threshold.toStringAsFixed(1)}%'),
            ],
          ),
          const SizedBox(height: 18),
          if (coverageTotal != null &&
              coverageAttempted != null &&
              coverageEvaluated != null &&
              coverageRemaining != null) ...[
            Text(
              _isMobileScan
                  ? '第 ${coverageRound ?? 1} 輪${_marketShortLabel}分頁輪掃 · 本輪名單 $coverageTotal 檔'
                  : '第 ${coverageRound ?? 1} 輪分頁掃描 · 全池 $coverageTotal 檔',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onPrimaryContainer),
            ),
            Text(
              '本輪已嘗試 $coverageAttempted 檔 · 成功 $coverageEvaluated 檔 · '
              '尚未嘗試 $coverageRemaining 檔',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onPrimaryContainer),
            ),
            if (pageStart != null && pageSize != null && pageSize > 0)
              Text(
                '本頁第 ${pageStart + 1}–${(pageStart + pageSize).clamp(0, coverageTotal)} 檔；'
                '${_hasCumulativeCandidates ? '清單累積本輪候選，各卡 RS 為原掃描頁內排名，並非全市場排名。' : '推薦與 RS 排名以本頁成功取得的行情計算。'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
            const SizedBox(height: 8),
          ],
          if (snapshot != null) ...[
            Text(
              '來源：${snapshot.source}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onPrimaryContainer),
            ),
            const SizedBox(height: 4),
            Text(
              snapshot.isFallback
                  ? '評估嘗試時間：${_date(snapshot.attemptedAt ?? snapshot.fetchedAt)}'
                  : '資料更新時間：${_date(snapshot.fetchedAt)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onPrimaryContainer),
            ),
            if (snapshot.scanCompletedAt != null &&
                snapshot.scanCompletedAt != snapshot.fetchedAt)
              Text(
                '${_hasMobileCoverage ? '本頁評估時間' : '市場評估時間'}：'
                '${_date(snapshot.scanCompletedAt!)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
            if (!snapshot.universeIsComplete)
              Text(
                snapshot.isFallback
                    ? '尚未完成股票池與行情驗證；0 表示未取得資料。'
                    : '目前股票清單覆蓋不足；請查看來源警語，勿視為完整市場。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
            if (snapshot.universeAsOf != null)
              Text(
                '股票名單時間：${_date(snapshot.universeAsOf!)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
          ] else
            Text(
              backend != null
                  ? backend.isFailed
                      ? '本次背景掃描尚未取得可驗證行情，請查看錯誤後重試。'
                      : controller.waitingForBackendScan
                      ? '首次背景掃描進行中；取得真實行情後才顯示資料時間。'
                      : '已停止查詢背景進度；下拉可重新查詢。'
                  : controller.loading
                  ? '正在取得本次評估，完成後儲存快照。'
                  : '尚未取得評估快照',
              style: TextStyle(color: colors.onPrimaryContainer),
            ),
          if (controller.settings.useMockData) ...[
            const SizedBox(height: 8),
            Text(
              '示範數值為合成資料，未執行全市場掃描。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (!controller.settings.useMockData) ...[
            const SizedBox(height: 8),
            if (controller.backgroundScanActive) ...[
              Text(
                controller.backgroundScanPaused
                    ? 'Android 背景服務已暫停；前台更新依原設定執行'
                    : 'Android 背景服務已啟用 · 切換 App 後可續掃 · 通知可暫停或停止',
                key: const ValueKey('dashboard-background-scan-status'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              controller.backgroundScanActive &&
                      !controller.backgroundScanPaused
                  ? controller.mobileScanPaused
                      ? '${_marketShortLabel}輪掃已手動暫停 · 下拉可繼續'
                      : '服務約每 60 秒續掃下一頁；系統省電可能延後'
                  : _isMobileScan
                  ? controller.mobileScanPaused
                      ? '${_marketShortLabel}輪掃已暫停 · 下拉可繼續'
                      : controller.autoRefreshActive
                      ? '前台每 60 秒續掃下一頁 · 下拉可立即續掃'
                      : '自動輪掃暫停 · 下拉可處理下一頁'
                  : controller.autoRefreshActive
                  ? '前台每 60 秒更新報價 · 下拉可立即更新'
                  : '自動更新暫停 · 下拉可立即更新',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onPrimaryContainer),
            ),
          ],
        ],
      ),
    );
  }

  /// A directory's member count is not a claim that all members were scanned.
  /// Only a server response with matching rolling-coverage metadata can label
  /// its scope as the whole verified directory. Completion remains separate.
  Widget _buildScanScope(BuildContext context) {
    final snapshot = controller.snapshot;
    final roundSnapshot = _mobileCoverageSnapshot ?? snapshot;
    final backend = controller.backendScanStatus;
    final progress = controller.marketScanProgress;
    final currentProgress =
        (controller.loading || snapshot == null) &&
                progress?.market == controller.market
            ? progress
            : null;
    final universe =
        _hasMobileCoverage
            ? roundSnapshot!.coverageTotalCount
            : backend?.universeCount ??
                currentProgress?.universeCount ??
                snapshot?.universeCount;
    final pageProgress =
        _hasMobileCoverage && currentProgress?.poolSize == 0
            ? null
            : currentProgress;
    final pool =
        backend?.totalCount ??
        pageProgress?.poolSize ??
        roundSnapshot?.scanPoolSize;
    final evaluated =
        backend?.evaluatedCount ??
        pageProgress?.evaluatedCount ??
        roundSnapshot?.evaluatedCount;
    final coverage =
        backend?.coverageTotalCount ?? roundSnapshot?.coverageTotalCount;
    final coverageEvaluated =
        backend?.coverageEvaluatedCount ??
        roundSnapshot?.coverageEvaluatedCount;
    final coverageRemaining =
        backend?.coverageRemainingCount ??
        roundSnapshot?.coverageRemainingCount;
    final symbolRange =
        _hasMobileCoverage && roundSnapshot != null
            ? _mobileSymbolRange(roundSnapshot)
            : null;
    final isMock = controller.settings.useMockData;
    final isDirect = controller.settings.dataProvider == 'direct';
    final hasFullScope =
        !isMock &&
        !isDirect &&
        universe != null &&
        universe > 0 &&
        coverage == universe &&
        coverageEvaluated != null &&
        coverageRemaining != null;
    final title =
        isMock
            ? '離線示範（非真實掃描）'
            : isDirect
            ? '手機${_marketShortLabel}分批輪掃'
            : hasFullScope
            ? 'Python 全股票池輪掃（分頁）'
            : 'Python 分批掃描';
    final detail =
        isMock
            ? '示範卡片與真實市場評估分開；未執行全市場掃描。'
            : isDirect
            ? _hasMobileCoverage
                ? '本輪已嘗試 ${roundSnapshot!.coverageScannedCount}/$universe 檔，'
                    '成功 $coverageEvaluated 檔，尚未嘗試 $coverageRemaining 檔。'
                    '本頁處理 ${pool ?? '待取得'} 檔，逐頁保留本輪候選與原行情時間。'
                : snapshot != null && !snapshot.isFallback
                ? '尚未建立本輪掃描進度；目前保留先前快照（已評估 ${evaluated ?? '待取得'} 檔）。'
                    '股票字典不等於全部已評估；下拉可依目前名單初始化分頁輪掃。'
                : '正在準備${_marketDirectoryLabel}；取得名單後依序分頁，'
                    '不會同時請求全市場，也不表示全部已完成評估。'
            : hasFullScope
            ? '本輪成功評估 $coverageEvaluated/$coverage 檔；'
                '尚未嘗試 $coverageRemaining 檔。覆蓋範圍以可確認的普通股名單為限，'
                '不代表全部已完成；推薦與 RS 仍以本頁行情計算。'
            : '本頁 ${pool ?? '待取得'} 檔 · 已評估 ${evaluated ?? '待取得'} 檔。'
                '伺服器尚未提供完整市場輪巡範圍，不宣稱已掃描全部股票。';
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('dashboard-scan-scope'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
          if (!isMock) ...[
            if (_isMobileScan) ...[
              if (_hasMobileCoverage && roundSnapshot != null) ...[
                const SizedBox(height: 6),
                Text(
                  _mobilePageRange(roundSnapshot),
                  key: const ValueKey('dashboard-mobile-page-range'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  (roundSnapshot.coverageRemainingCount ?? 0) > 0
                      ? '下一頁起點：第 ${roundSnapshot.coverageScannedCount! + 1} 檔；'
                          '本輪掃完前不因名單來源暫時失敗而回到第一檔。'
                      : '本輪名單已全部嘗試；下一輪再採用更新後的名單。',
                  key: const ValueKey('dashboard-mobile-next-start'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (symbolRange != null)
                  Text(
                    symbolRange,
                    key: const ValueKey('dashboard-mobile-symbol-range'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 4),
              Text(
                controller.mobileScanPaused
                    ? '已暫停自動輪掃；下拉或點繼續可處理下一頁。'
                    : '不需 Python API；前台自動更新或下拉會繼續掃描下一頁。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                key: const ValueKey('dashboard-mobile-scan-toggle'),
                onPressed:
                    controller.mobileScanPaused
                        ? controller.loading
                            ? null
                            : () => controller.refresh(forceRefresh: true)
                        : controller.cancelMarketEvaluation,
                icon: Icon(
                  controller.mobileScanPaused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  size: 18,
                ),
                label: Text(
                  controller.mobileScanPaused
                      ? '繼續${_marketShortLabel}輪掃'
                      : '暫停${_marketShortLabel}輪掃',
                ),
              ),
            ],
            TextButton.icon(
              key: const ValueKey('dashboard-api-settings'),
              onPressed:
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(controller: controller),
                    ),
                  ),
              icon: const Icon(Icons.cloud_outlined, size: 18),
              label: Text(_isMobileScan ? '選用雲端 API' : '查看 API 設定'),
            ),
          ],
        ],
      ),
    );
  }

  String _mobilePageRange(CandidateSnapshot snapshot) {
    final start = snapshot.scanPageStart ?? 0;
    final size = snapshot.scanPageSize ?? 0;
    if (size <= 0) return '正在準備本輪下一頁。';
    return '本頁範圍：第 ${start + 1}–${start + size} 檔'
        '（第 ${snapshot.coverageRound ?? 1} 輪，名單固定）。';
  }

  String? _mobileSymbolRange(CandidateSnapshot snapshot) {
    for (final note in snapshot.warnings.reversed) {
      if (note.startsWith('本頁已嘗試代碼：')) return note;
    }
    return null;
  }

  Widget _buildBackendProgress(BuildContext context) {
    final scan = controller.backendScanStatus!;
    final colors = Theme.of(context).colorScheme;
    final waiting = controller.waitingForBackendScan;
    final running = scan.isRunning && waiting;
    final stage = switch (scan.stage) {
      'queued' => '已排入背景工作',
      'reading_cache' => '讀取上次評估',
      'loading_calendar' => '確認交易時段',
      'loading_universe' => '載入股票池',
      'loading_benchmark' => '讀取大盤日 K',
      'loading_prices' => '分批取得行情',
      'calculating_indicators' => '計算 ADR、EMA 與 RS',
      'serializing_snapshot' => '整理評估結果',
      'saving_snapshot' => '儲存評估快照',
      'universe' => '載入股票池',
      'benchmark' => '讀取大盤日 K',
      'evaluating' => '分批計算 ADR、EMA 與 RS',
      'completed' => '背景評估完成',
      'client_error' => '查詢進度中斷',
      'failed' => '背景掃描失敗',
      'timed_out' => '背景掃描已達時間上限',
      _ => '處理掃描資料',
    };
    final headline =
        scan.isFailed
            ? '背景掃描／進度查詢失敗'
            : running
            ? 'Python 背景掃描進行中'
            : scan.isRunning
            ? '已停止查詢進度'
            : 'Python 背景評估已完成';
    return Card(
      key: const ValueKey('backend-scan-progress'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  scan.isFailed
                      ? Icons.cloud_off_outlined
                      : running
                      ? Icons.cloud_sync_outlined
                      : Icons.cloud_done_outlined,
                  color: scan.isFailed ? colors.error : colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    headline,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (running)
                  TextButton(
                    onPressed: controller.cancelMarketEvaluation,
                    child: const Text('停止查詢'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '$stage · 已處理 ${scan.completedCount}/${scan.totalCount} 檔；'
              '有效 ${scan.evaluatedCount}，ADR 符合 ${scan.adrMatchCount}，'
              '失敗 ${scan.failedCount}。',
            ),
            if (running) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value:
                    scan.totalCount > 0
                        ? (scan.completedCount / scan.totalCount)
                            .clamp(0.0, 1.0)
                            .toDouble()
                        : 0,
              ),
              const SizedBox(height: 8),
              const Text(
                '可繼續切換分頁或操作；每約 3 秒查詢一次背景進度。'
                '首次啟動可能較久，最多等待 3 分鐘後可重試。',
              ),
            ] else if (scan.isRunning)
              const Text('只停止此手機查詢；伺服器工作仍可繼續。下拉可恢復查詢。'),
            if (scan.isFailed && scan.error != null) ...[
              const SizedBox(height: 8),
              Text(scan.error!, style: TextStyle(color: colors.error)),
            ],
            const SizedBox(height: 6),
            Text(
              '工作進度時間：${_date(scan.updatedAt)}（非行情更新時間）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildWarnings(BuildContext context) {
    final widgets = <Widget>[];
    final snapshot = controller.snapshot;
    final incomplete = _hasIncompleteScan;
    if (controller.error != null) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _warning(
            context,
            '更新失敗',
            controller.error!,
            error: true,
            action: TextButton.icon(
              onPressed:
                  controller.loading
                      ? null
                      : () => controller.refresh(forceRefresh: true),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重試'),
            ),
          ),
        ),
      );
    }
    if (snapshot != null && snapshot.stale) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _warning(
            context,
            snapshot.isFallback
                ? '市場評估未完成'
                : incomplete
                ? '顯示已取得部分資料'
                : '顯示上次快取',
            snapshot.isFallback
                ? '本次未取得可驗證行情；顯示的是評估嘗試時間，可下拉或點選重試。'
                : '資料更新時間保留原始時間；請重新整理並確認最新行情後再評估進場。',
          ),
        ),
      );
    }
    if (snapshot != null) {
      if (snapshot.missingSymbols.isNotEmpty) {
        final shown = snapshot.missingSymbols.take(5).join('、');
        final extra = snapshot.missingSymbols.length > 5 ? ' 等' : '';
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _warning(
              context,
              '部分標的缺少行情',
              '${snapshot.missingSymbols.length} 檔資料未完整取得：$shown$extra。排名僅涵蓋可用資料。',
            ),
          ),
        );
      }
    }
    return widgets;
  }

  /// Keep informational source disclosures accessible without placing a long
  /// stack of identical cards ahead of the actual recommendations. Failures,
  /// stale/fallback snapshots and missing quotes remain outside this collapse.
  Widget _buildSourceDisclosures(BuildContext context) {
    final warnings = {...?controller.snapshot?.warnings}.toList();
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        key: const ValueKey('dashboard-source-disclosures'),
        leading: const Icon(Icons.info_outline),
        title: Text('資料來源與限制（${warnings.length} 則）'),
        subtitle: const Text('點開查看名單來源、分類排除與更新範圍'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isMobileScan)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '名單來源提示保留本輪建立時的狀態；續掃不會重設進度。個股行情時間請看卡片。',
                style: TextStyle(height: 1.5),
              ),
            ),
          for (var index = 0; index < warnings.length; index++)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '${index + 1}. ${warnings[index]}',
                style: const TextStyle(height: 1.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSorting(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Padding(
        padding: EdgeInsets.only(right: 4),
        child: Text('排序', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      for (final sort in CandidateSort.values)
        ChoiceChip(
          label: Text(switch (sort) {
            CandidateSort.rs => 'RS 強度',
            CandidateSort.adr => 'ADR ↓',
            CandidateSort.position => '風險上限試算 ↓',
          }),
          selected: controller.sort == sort,
          onSelected: (_) => controller.setSort(sort),
        ),
    ],
  );

  /// A sliver-backed responsive card grid without a fixed card height. Long
  /// names, translated labels and larger accessibility fonts can wrap safely.
  Widget _buildCandidateGrid(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent - 40;
      final columns =
          width >= 1080
              ? 3
              : width >= 680
              ? 2
              : 1;
      final stocks = controller.visibleCandidates;
      final rows = (stocks.length / columns).ceil();
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, row) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) const SizedBox(width: 14),
                    Expanded(
                      child:
                          row * columns + column < stocks.length
                              ? _RecommendationCard(
                                key: ValueKey(
                                  stocks[row * columns + column].id,
                                ),
                                stock: stocks[row * columns + column],
                                equity: controller.equityFor(
                                  stocks[row * columns + column].market,
                                ),
                                riskMode: controller.riskModeFor(
                                  stocks[row * columns + column].market,
                                ),
                                isCached: _requiresRefresh(
                                  stocks[row * columns + column],
                                ),
                                onTap:
                                    () => _openStock(
                                      context,
                                      stocks[row * columns + column],
                                    ),
                              )
                              : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
            childCount: rows,
          ),
        ),
      );
    },
  );

  void _openStock(BuildContext context, StockCandidate stock) {
    final sourceAtOpen = controller.snapshot?.source;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                StockCandidate? latest;
                final snapshot = controller.snapshot;
                for (final item
                    in snapshot?.candidates ?? const <StockCandidate>[]) {
                  if (item.market == stock.market &&
                      item.symbol == stock.symbol) {
                    latest = item;
                    break;
                  }
                }
                // Polling also updates the open detail screen. If a new scan no
                // longer contains the symbol, retain its last data as a snapshot.
                return CalculatorScreen(
                  candidate: latest ?? stock,
                  initialEquity: controller.equityFor(stock.market),
                  riskMode: controller.riskModeFor(stock.market),
                  dataSource: latest == null ? sourceAtOpen : snapshot?.source,
                  isCached: latest == null || _requiresRefresh(latest),
                  onEquityChanged:
                      (equity) => controller.setEquity(stock.market, equity),
                );
              },
            ),
      ),
    );
  }

  bool get _hasIncompleteScan {
    final snapshot = controller.snapshot;
    // A completed mobile page is not a failed whole-market scan. Its rolling
    // counters explicitly retain the rest of the directory for later pages.
    if (_hasMobileCoverage) return false;
    return !controller.settings.useMockData &&
        controller.settings.dataProvider == 'direct' &&
        snapshot != null &&
        !snapshot.isFallback &&
        snapshot.scanPoolSize != null &&
        snapshot.scanCompletedAt == null;
  }

  Widget _buildEmpty(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 38),
      child: Column(
        children: [
          Icon(
            Icons.manage_search,
            size: 42,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Text(
            controller.waitingForBackendScan
                ? 'Python 背景掃描進行中'
                : controller.backendScanStatus?.isRunning == true
                ? '已停止查詢背景進度'
                : controller.loading
                ? '正在掃描候選股'
                : _isMobileScan && controller.mobileScanPaused
                ? '${_marketShortLabel}輪掃已暫停'
                : controller.snapshot == null || controller.snapshot!.isFallback
                ? '市場評估未完成，請重試'
                : _hasMobileCoverage
                ? (controller.snapshot!.coverageRemainingCount ?? 0) > 0
                    ? '本輪目前尚無符合條件的標的'
                    : '本輪已取得資料尚無符合標的'
                : _isMobileScan
                ? '本輪掃描尚未初始化'
                : _hasIncompleteScan
                ? '市場評估僅部分完成'
                : controller.snapshot!.stale
                ? '暫無可用推薦；目前顯示上次資料'
                : '目前沒有符合條件的標的',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            controller.waitingForBackendScan
                ? '手機已結束本次刷新，伺服器正分批評估；完成後自動顯示結果，可繼續操作。'
                : controller.backendScanStatus?.isRunning == true
                ? '下拉更新可繼續取得同一背景工作的進度與快照。'
                : controller.loading
                ? '單次請求最多等待 10 秒；可點選右上方「停止掃描」。'
                : _isMobileScan && controller.mobileScanPaused
                ? '已保留本輪進度；點選「繼續${_marketShortLabel}輪掃」或下拉可繼續。'
                : controller.snapshot == null ||
                    controller.snapshot!.isFallback ||
                    controller.snapshot!.stale
                ? '查看上方錯誤提示並下拉重試；未取得有效行情時不產生推薦。'
                : _hasMobileCoverage
                ? (controller.snapshot!.coverageRemainingCount ?? 0) > 0
                    ? '仍有 ${controller.snapshot!.coverageRemainingCount} 檔尚未嘗試；'
                        '本頁沒有新候選不代表整個${_marketShortLabel}市場都沒有買點。'
                    : '本輪已嘗試全部名單；僅對成功取得行情的股票判斷，'
                        '失敗標的並非沒有買點。下拉可開始下一輪。'
                : _hasIncompleteScan
                ? '已處理部分股票，尚未完成本頁；請下拉重試。'
                : _isMobileScan
                ? '目前快照尚無本輪進度；下拉可初始化完整名單分批輪掃。'
                : '本次評估已完成；可在設定調整 ADR 門檻，或下拉更新。',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Widget _buildPagination(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton.filledTonal(
        tooltip: '上一頁',
        onPressed:
            controller.page > 0
                ? () => controller.setPage(controller.page - 1)
                : null,
        icon: const Icon(Icons.chevron_left),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Text('${controller.page + 1} / ${controller.pageCount} 頁'),
      ),
      IconButton.filledTonal(
        tooltip: '下一頁',
        onPressed:
            controller.page + 1 < controller.pageCount
                ? () => controller.setPage(controller.page + 1)
                : null,
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  Widget _summary(BuildContext context, String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 4),
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
    ],
  );

  Widget _warning(
    BuildContext context,
    String title,
    String text, {
    bool error = false,
    Widget? action,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.cloud_off_outlined : Icons.info_outline,
            color: error ? colors.onErrorContainer : colors.onTertiaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(text, style: const TextStyle(height: 1.5)),
                if (action != null) action,
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _date(DateTime time) {
    // Taiwan has no daylight-saving offset. Display one explicit time zone
    // across both markets rather than silently changing with device settings.
    final taipei = time.toUtc().add(const Duration(hours: 8));
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(taipei)} · 台北 UTC+08';
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({
    super.key,
    required this.stock,
    required this.equity,
    required this.riskMode,
    required this.onTap,
    required this.isCached,
  });

  final StockCandidate stock;
  final double equity;
  final RiskMode riskMode;
  final VoidCallback onTap;
  final bool isCached;

  PositionPlan? get _plan {
    if (isCached) return null;
    try {
      return StrategyEngine.calculate(stock, equity, riskMode: riskMode);
    } catch (_) {
      // A candidate with incomplete/invalid entry evidence remains a watchlist
      // card instead of silently inventing a stop or a suggested order.
      return null;
    }
  }

  TradeLevels? get _levels {
    try {
      return StrategyEngine.calculateTradeLevels(stock);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final plan = _plan;
    final levels = _levels;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      stock.symbol,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_outward_rounded,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(stock.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                stock.sector,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (stock.quotePrice != null) ...[
                const SizedBox(height: 8),
                Text(
                  '最新可用市價 ${stock.market.currencySymbol}${stock.quotePrice!.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 6),
              Text(
                '行情時間：${_date(stock.dataTimestamp)}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (isCached)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '保留行情 · 待更新確認',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.error),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      context,
                      'ADR · 20 日',
                      '${stock.adrPercent.toStringAsFixed(2)}%',
                    ),
                  ),
                  Expanded(
                    child: _metric(
                      context,
                      'RS 強度 · #${stock.rsRank}',
                      stock.rsScore.toStringAsFixed(1),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (stock.rsScore / 100).clamp(0.0, 1.0).toDouble(),
                  minHeight: 4,
                  color: colors.primary,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _patternBadge(
                    context,
                    isCached
                        ? '快取觀察'
                        : plan != null
                        ? '已確認'
                        : '觀察',
                    plan != null
                        ? Icons.verified_outlined
                        : Icons.visibility_outlined,
                  ),
                  for (final pattern in stock.patterns.take(3))
                    _patternBadge(
                      context,
                      isCached ? '上次：$pattern' : pattern,
                      _patternIcon(pattern),
                    ),
                  if (stock.patterns.length > 3)
                    _patternBadge(
                      context,
                      '+${stock.patterns.length - 3}',
                      Icons.more_horiz,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                stock.hybridSummary,
                key: ValueKey('hybrid-status-${stock.id}'),
              ),
              if (!stock.isConfirmed)
                Text(
                  stock.hybridPending.join('；'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const Divider(height: 30),
              if (isCached && levels != null) ...[
                Text(
                  '上次確認價位（待更新）',
                  key: ValueKey('recommendation-historical-levels-${stock.id}'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  '突破確認時間：${_date(stock.signalTimestamp ?? stock.dataTimestamp)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _metric(
                      context,
                      levels == null || isCached
                          ? '${stock.triggerType ?? '條件'} 觸發參考價'
                          : '假設買價 · ${stock.triggerType ?? '條件'} 觸發',
                      '${stock.market.currencySymbol}${stock.triggerPrice.toStringAsFixed(2)}',
                      small: true,
                      valueKey: ValueKey('recommendation-entry-${stock.id}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _metric(
                      context,
                      isCached && levels != null ? '上次初始硬停損參考' : '初始硬停損參考',
                      levels == null
                          ? (stock.stopPrice == null ? '缺少停損' : '待確認')
                          : '${stock.market.currencySymbol}${stock.stopPrice!.toStringAsFixed(2)}',
                      small: true,
                      valueKey: ValueKey('recommendation-stop-${stock.id}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '停損來源：${_stopSource(levels)}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    levels == null
                        ? '停損幅度待確認'
                        : '停損幅度 ${levels.stopPercent.toStringAsFixed(2)}%',
                    key: ValueKey('recommendation-stop-percent-${stock.id}'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    levels == null
                        ? '1R 待確認'
                        : '1R ${stock.market.currencySymbol}${levels.riskPerShare.toStringAsFixed(2)}',
                    key: ValueKey('recommendation-1r-${stock.id}'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    isCached
                        ? '部位待更新'
                        : plan == null
                        ? '部位待確認'
                        : '風險上限試算 ${plan.positionPercent.toStringAsFixed(2)}%',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const Divider(height: 26),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _metric(
                      context,
                      isCached ? '3R 參考價 · 原始股數 15%' : '3R 賣價 · 原始股數 15%',
                      _targetPrice(levels, 3),
                      small: true,
                      valueKey: ValueKey('recommendation-3r-${stock.id}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _metric(
                      context,
                      isCached ? '5R 參考價 · 再賣原始股數 15%' : '5R 賣價 · 再賣原始股數 15%',
                      _targetPrice(levels, 5),
                      small: true,
                      valueKey: ValueKey('recommendation-5r-${stock.id}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '剩餘 70%：日收盤跌破 9 EMA 追蹤出場。',
                key: ValueKey('recommendation-trailing-${stock.id}'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                levels == null
                    ? stock.stopPrice == null
                        ? '尚未取得已確認突破的實際停損，無法計算 1R 與目標價。點開詳情可手動試算。'
                        : '進場與停損未通過驗證，暫不提供目標價。點開詳情查看原因。'
                    : '${isCached ? '以上保留上次確認的參考價位，更新確認前不提供買進部位。' : ''}'
                        '${plan == null && !isCached ? '價位試算不受本金影響；買進部位需另行驗證本金。' : ''}'
                        '分批比例以原始買進股數為基準；停損先觸發則先出場。'
                        '目標價為策略試算，尚非下單指令。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _targetPrice(TradeLevels? levels, int multiple) =>
      levels == null
          ? (stock.stopPrice == null ? '缺少停損' : '待確認')
          : '${stock.market.currencySymbol}${levels.targetPrice(multiple).toStringAsFixed(2)}';

  String _stopSource(TradeLevels? levels) {
    if (levels == null) return '待確認實際低點';
    return stock.stopSource == 'entry_bar_low' ? '實際進場分鐘 K 低點' : '突破日當日實際低點';
  }

  Widget _metric(
    BuildContext context,
    String label,
    String value, {
    bool small = false,
    Key? valueKey,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        key: valueKey,
        style: (small
                ? Theme.of(context).textTheme.titleSmall
                : Theme.of(context).textTheme.titleLarge)
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );

  String _date(DateTime value) {
    final taipei = value.toUtc().add(const Duration(hours: 8));
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(taipei)} · 台北 UTC+08';
  }

  Widget _patternBadge(BuildContext context, String label, IconData icon) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label, style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ),
      );

  IconData _patternIcon(String pattern) {
    final value = pattern.toLowerCase();
    if (value.contains('pdh') || value.contains('突破')) return Icons.trending_up;
    if (value.contains('gap') ||
        value.contains('跳空') ||
        value.contains('episodic')) {
      return Icons.bolt;
    }
    if (value.contains('收斂') || value.contains('ema')) return Icons.compress;
    return Icons.show_chart;
  }
}
