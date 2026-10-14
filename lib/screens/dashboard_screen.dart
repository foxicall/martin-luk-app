import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import '../services/strategy_engine.dart';
import '../widgets/stock_search_field.dart';
import 'calculator_screen.dart';
import 'portfolio_screen.dart';

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
                  Text('動能觀測站'),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: '重新評估',
                  onPressed: controller.loading
                      ? null : () => controller.refresh(forceRefresh: true),
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
                              if (controller.loading) ...[
                                const SizedBox(height: 12),
                                const LinearProgressIndicator(),
                                const SizedBox(height: 6),
                                Text('正在更新市場評估…',
                                    style: TextStyle(color: colors.onSurfaceVariant)),
                              ],
                              ..._buildWarnings(context),
                              const SizedBox(height: 24),
                              Text('推薦與觀察名單',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 6),
                              Text('確認突破與停損後才提供部位建議；點選個股可調整本金。',
                                  style: TextStyle(color: colors.onSurfaceVariant)),
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
                              const SizedBox(height: 18),
                              Text(
                                '資料更新時間與延遲依來源而異。策略訊號供研究與評估，'
                                '進場前請確認行情；0.5% 停損風險不含滑價與跳空。',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
    setState(() { _selection = stock; _finding = true; });
    try {
      // The symbol determines the market and its independent capital. Search
      // must not relabel a US security as TW just because a TW tab was open.
      await controller.setMarket(stock.market);
      if (!mounted || version != _selectionVersion || controller.market != stock.market) return;
      StockCandidate? candidate;
      for (final row in controller.snapshot?.candidates ?? const <StockCandidate>[]) {
        if (row.symbol == stock.symbol && row.market == stock.market) {
          candidate = row;
          break;
        }
      }
      if (candidate != null) _openStock(context, candidate);
    } catch (error) {
      if (mounted && version == _selectionVersion) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已找到股票身份，評估讀取失敗：$error')));
      }
    } finally {
      if (mounted && version == _selectionVersion) setState(() => _finding = false);
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${stock.marketTag} · ${stock.symbol} · ${stock.displayName}',
              style: Theme.of(context).textTheme.titleMedium),
          Text(stock.nameEn, style: TextStyle(color: colors.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(_finding ? '正在查詢該市場的評估快照…'
              : '股票身份來自離線字典；若快照沒有此股，不產生行情、ADR 或突破建議。'),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _finding ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PortfolioScreen(controller: controller, initialStock: stock),
            )),
            icon: const Icon(Icons.add),
            label: const Text('將標準代碼帶入新增持股'),
          ),
        ]),
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
                  label: Text(compact ? '台股 · TW' : '台股上市 · TW'),
                ),
                ButtonSegment(
                  value: StockMarket.us,
                  icon: const Icon(Icons.language),
                  label: Text(compact ? '美股 · US' : 'S&P 500 · US'),
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
    final threshold = controller.market == StockMarket.tw
        ? controller.settings.twAdrThreshold
        : controller.settings.usAdrThreshold;
    final confirmed = snapshot?.candidates
            .where((stock) => stock.isConfirmed && !_requiresRefresh(stock) &&
                stock.adrPercent >= threshold)
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
              Text(controller.market.label,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colors.onPrimaryContainer,
                      )),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: controller.settings.useMockData
                      ? colors.tertiaryContainer
                      : colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  controller.settings.useMockData ? 'OFFLINE MOCK · 離線示範'
                      : controller.settings.dataProvider == 'direct'
                          ? 'YAHOO · 連網行情' : 'API · 掃描引擎',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('Martin Luk 動能框架 · ADR × 相對強勢 × 突破',
              style: TextStyle(color: colors.onPrimaryContainer)),
          const SizedBox(height: 20),
          Wrap(
            spacing: 28,
            runSpacing: 16,
            children: [
              _summary(context, '股票池', snapshot?.universeCount.toString() ?? '—'),
              if (snapshot?.evaluatedCount != null)
                _summary(context, '已評估', '${snapshot!.evaluatedCount}'),
              _summary(context, '目前符合 ADR', '${controller.filteredCount}'),
              _summary(context, '已確認型態', '$confirmed'),
              _summary(context, 'ADR 門檻', '${threshold.toStringAsFixed(1)}%'),
            ],
          ),
          const SizedBox(height: 18),
          if (snapshot != null) ...[
            Text('來源：${snapshot.source}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onPrimaryContainer,
                    )),
            const SizedBox(height: 4),
            Text('資料更新時間：${_date(snapshot.fetchedAt)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onPrimaryContainer,
                    )),
            if (snapshot.scanCompletedAt != null &&
                snapshot.scanCompletedAt != snapshot.fetchedAt)
              Text('完整掃描時間：${_date(snapshot.scanCompletedAt!)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  )),
            if (!snapshot.universeIsComplete)
              Text('目前使用本機股票清單；尚未確認完整最新上市成分。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  )),
            if (snapshot.universeAsOf != null)
              Text('股票池時間：${_date(snapshot.universeAsOf!)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  )),
          ] else
            Text('尚未取得評估快照',
                style: TextStyle(color: colors.onPrimaryContainer)),
          if (controller.settings.useMockData) ...[
            const SizedBox(height: 8),
            Text('示範數值為合成資料，未執行全市場掃描。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    )),
          ],
          if (!controller.settings.useMockData) ...[
            const SizedBox(height: 8),
            Text(controller.autoRefreshActive
                ? '前台每 60 秒更新報價 · 下拉可立即更新'
                : '自動更新暫停 · 下拉可立即更新',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                )),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildWarnings(BuildContext context) {
    final widgets = <Widget>[];
    final snapshot = controller.snapshot;
    if (controller.error != null) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _warning(
          context,
          '更新失敗',
          controller.error!,
          error: true,
          action: TextButton.icon(
            onPressed: controller.loading
                ? null : () => controller.refresh(forceRefresh: true),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重試'),
          ),
        ),
      ));
    }
    if (snapshot?.stale ?? false) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _warning(context, '顯示上次快取',
            '資料更新時間仍保留原始時間；請重新整理並確認最新行情後再評估進場。'),
      ));
    }
    if (snapshot != null) {
      for (final warning in snapshot.warnings) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _warning(context, '資料提示', warning),
        ));
      }
      if (snapshot.missingSymbols.isNotEmpty) {
        final shown = snapshot.missingSymbols.take(5).join('、');
        final extra = snapshot.missingSymbols.length > 5 ? ' 等' : '';
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _warning(context, '部分標的缺少行情',
              '${snapshot.missingSymbols.length} 檔資料未完整取得：$shown$extra。排名僅涵蓋可用資料。'),
        ));
      }
    }
    return widgets;
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
                CandidateSort.position => '建議部位 ↓',
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
          final columns = width >= 1080 ? 3 : width >= 680 ? 2 : 1;
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
                          child: row * columns + column < stocks.length
                              ? _RecommendationCard(
                                  key: ValueKey(stocks[row * columns + column].id),
                                  stock: stocks[row * columns + column],
                                  equity: controller.equityFor(
                                      stocks[row * columns + column].market),
                                  isCached: _requiresRefresh(
                                      stocks[row * columns + column]),
                                  onTap: () => _openStock(
                                      context, stocks[row * columns + column]),
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          StockCandidate? latest;
          final snapshot = controller.snapshot;
          for (final item in snapshot?.candidates ?? const <StockCandidate>[]) {
            if (item.market == stock.market && item.symbol == stock.symbol) {
              latest = item;
              break;
            }
          }
          // Polling also updates the open detail screen. If a new scan no
          // longer contains the symbol, retain its last data as a snapshot.
          return CalculatorScreen(
            candidate: latest ?? stock,
            initialEquity: controller.equityFor(stock.market),
            dataSource: latest == null ? sourceAtOpen : snapshot?.source,
            isCached: latest == null || _requiresRefresh(latest),
            onEquityChanged: (equity) => controller.setEquity(stock.market, equity),
          );
        },
      ),
    ));
  }

  Widget _buildEmpty(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 38),
          child: Column(
            children: [
              Icon(Icons.manage_search, size: 42,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 14),
              Text(controller.loading ? '正在掃描候選股' : '目前沒有符合條件的標的',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('可在設定調整 ADR 門檻，或下拉更新評估結果。', textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget _buildPagination(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filledTonal(
            tooltip: '上一頁',
            onPressed: controller.page > 0
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
            onPressed: controller.page + 1 < controller.pageCount
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
          Text(value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  )),
        ],
      );

  Widget _warning(BuildContext context, String title, String text,
      {bool error = false, Widget? action}) {
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
          Icon(error ? Icons.cloud_off_outlined : Icons.info_outline,
              color: error ? colors.onErrorContainer : colors.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
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
    required this.onTap,
    required this.isCached,
  });

  final StockCandidate stock;
  final double equity;
  final VoidCallback onTap;
  final bool isCached;

  PositionPlan? get _plan {
    if (isCached) return null;
    try {
      return StrategyEngine.calculate(stock, equity);
    } catch (_) {
      // A candidate with incomplete/invalid entry evidence remains a watchlist
      // card instead of silently inventing a stop or a suggested order.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final plan = _plan;
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
                    child: Text(stock.symbol,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            )),
                  ),
                  Icon(Icons.arrow_outward_rounded,
                      size: 20, color: colors.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 4),
              Text(stock.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(stock.sector,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      )),
              if (stock.quotePrice != null) ...[
                const SizedBox(height: 8),
                Text('最新可用市價 ${stock.market.currencySymbol}${stock.quotePrice!.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
              const SizedBox(height: 6),
              Text('行情時間：${_date(stock.dataTimestamp)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  )),
              if (isCached) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('保留行情 · 待更新確認',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    )),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _metric(context, 'ADR · 20 日',
                      '${stock.adrPercent.toStringAsFixed(2)}%')),
                  Expanded(child: _metric(context, 'RS 強度 · #${stock.rsRank}',
                      stock.rsScore.toStringAsFixed(1))),
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
                  _patternBadge(context,
                      isCached ? '快取觀察' : plan != null ? '已確認' : '觀察',
                      plan != null ? Icons.verified_outlined : Icons.visibility_outlined),
                  for (final pattern in stock.patterns.take(3))
                    _patternBadge(context, isCached ? '上次：$pattern' : pattern,
                        _patternIcon(pattern)),
                  if (stock.patterns.length > 3)
                    _patternBadge(context, '+${stock.patterns.length - 3}', Icons.more_horiz),
                ],
              ),
              const Divider(height: 30),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _metric(context, '${stock.triggerType ?? '條件'} 觸發價',
                      '${stock.market.currencySymbol}${stock.triggerPrice.toStringAsFixed(2)}',
                      small: true)),
                  const SizedBox(width: 8),
                  Expanded(child: _metric(context, '初始硬停損',
                      stock.stopPrice == null
                          ? '待確認'
                          : '${stock.market.currencySymbol}${stock.stopPrice!.toStringAsFixed(2)}',
                      small: true)),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(stock.stopPercent == null
                      ? '停損待確認'
                      : '停損 ${stock.stopPercent!.toStringAsFixed(2)}%',
                      style: Theme.of(context).textTheme.bodySmall),
                  if (stock.riskPerShare != null)
                    Text('1R ${stock.market.currencySymbol}${stock.riskPerShare!.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.bodySmall),
                  Text(isCached ? '部位待更新' : plan == null
                      ? '部位待確認' : '建議部位 ${plan.positionPercent.toStringAsFixed(2)}%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.primary,
                            fontWeight: FontWeight.w700,
                          )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value,
      {bool small = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          const SizedBox(height: 4),
          Text(value,
              style: (small
                      ? Theme.of(context).textTheme.titleSmall
                      : Theme.of(context).textTheme.titleLarge)
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ],
      );

  String _date(DateTime value) {
    final taipei = value.toUtc().add(const Duration(hours: 8));
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(taipei)} · 台北 UTC+08';
  }

  Widget _patternBadge(BuildContext context, String label, IconData icon) => Container(
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
            Flexible(child: Text(label, style: Theme.of(context).textTheme.labelSmall)),
          ],
        ),
      );

  IconData _patternIcon(String pattern) {
    final value = pattern.toLowerCase();
    if (value.contains('pdh') || value.contains('突破')) return Icons.trending_up;
    if (value.contains('gap') || value.contains('跳空') || value.contains('episodic')) {
      return Icons.bolt;
    }
    if (value.contains('收斂') || value.contains('ema')) return Icons.compress;
    return Icons.show_chart;
  }
}
