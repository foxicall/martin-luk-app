import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../models/portfolio_position.dart';
import '../models/hybrid_protocol.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import '../services/exit_advisory_engine.dart';
import '../services/market_data_api.dart' show canonicalSymbol;
import '../widgets/stock_search_field.dart';

// Keep form controllers alive through the dialog's reverse transition.
Future<T?> _showOwnedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

/// Local holdings are independent of brokerage accounts; all actions are advice.
class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({
    super.key,
    required this.controller,
    this.initialStock,
  });
  final AppController controller;
  final StockItem? initialStock;
  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  StockMarket _market = StockMarket.tw;
  bool _busy = false;
  double? _threshold;
  AppController get controller => widget.controller;
  String _price(double value) => value.toStringAsFixed(2);
  String _date(DateTime value) {
    final taipei = value.toUtc().add(const Duration(hours: 8));
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(taipei)} · 台北 UTC+08';
  }

  @override
  void initState() {
    super.initState();
    final stock = widget.initialStock;
    if (stock != null) {
      _market = stock.market;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editHolding(stock: stock);
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editHolding({
    PortfolioPosition? holding,
    StockItem? stock,
  }) async {
    final symbol = TextEditingController(
      text: holding?.symbol ?? stock?.symbol ?? '',
    );
    final name = TextEditingController(
      text: holding?.name ?? stock?.displayName ?? '',
    );
    final entry = TextEditingController(
      text: holding == null ? '' : '${holding.entryPrice}',
    );
    final shares = TextEditingController(
      text: holding == null ? '' : '${holding.shares}',
    );
    final stop = TextEditingController(
      text: holding == null ? '' : '${holding.initialStop}',
    );
    final actualStop = TextEditingController(
      text: holding == null ? '' : '${holding.trailingStop}',
    );
    var sold3R = holding?.sold3R ?? false, sold5R = holding?.sold5R ?? false;
    final hybrid = holding?.usesHybrid ?? true;
    final form = GlobalKey<FormState>();
    var market = holding?.market ?? stock?.market ?? _market;
    var mainUptrend = holding?.mainUptrend ?? false;
    var ema = holding?.trailingEma ?? 9;
    String? dialogError;
    try {
      final result = await _showOwnedDialog<PortfolioPosition>(
        context: context,
        builder:
            (dialogContext) => StatefulBuilder(
              builder:
                  (context, update) => AlertDialog(
                    title: Text(holding == null ? '新增持股' : '編輯持股'),
                    content: SizedBox(
                      width: 440,
                      child: SingleChildScrollView(
                        child: Form(
                          key: form,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DropdownButtonFormField<StockMarket>(
                                value: market,
                                decoration: const InputDecoration(
                                  labelText: '市場／計價幣別',
                                ),
                                items:
                                    StockMarket.values
                                        .map(
                                          (value) => DropdownMenuItem(
                                            value: value,
                                            child: Text(
                                              '${value.label} · ${value.currency}',
                                            ),
                                          ),
                                        )
                                        .toList(),
                                onChanged: (value) {
                                  if (value != null)
                                    update(() => market = value);
                                },
                              ),
                              const SizedBox(height: 12),
                              StockSearchField(
                                controller: symbol,
                                key: const ValueKey('holding-stock-search'),
                                label: '股票代碼／中英文名稱',
                                helperText:
                                    '選擇提示會填入標準代碼；上市 .TW、上櫃 .TWO。未選提示的純數字預設為上市。',
                                onSelected:
                                    (item) => update(() {
                                      market = item.market;
                                      symbol.text = item.symbol;
                                      name.text = item.displayName;
                                    }),
                                validator:
                                    (text) =>
                                        (text ?? '').trim().isEmpty
                                            ? '請輸入代碼'
                                            : null,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: name,
                                decoration: const InputDecoration(
                                  labelText: '名稱（選填）',
                                ),
                              ),
                              const SizedBox(height: 12),
                              _numberField(entry, '買進成本價'),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: shares,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '買進股數（整股）',
                                ),
                                validator:
                                    (text) =>
                                        (int.tryParse(text ?? '') ?? 0) <= 0
                                            ? '請輸入正整數'
                                            : null,
                              ),
                              const SizedBox(height: 12),
                              _numberField(
                                stop,
                                '原始初始停損價',
                                validator: (text) {
                                  final value = double.tryParse(text ?? '');
                                  final cost = double.tryParse(entry.text);
                                  return value == null ||
                                          !value.isFinite ||
                                          value <= 0 ||
                                          cost == null ||
                                          value >= cost
                                      ? '停損須為正數且低於成本價'
                                      : null;
                                },
                              ),
                              const SizedBox(height: 8),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('主升段追蹤'),
                                subtitle: const Text('最高獲利達 3R 才採用 21／50 EMA'),
                                value: mainUptrend,
                                onChanged:
                                    (value) =>
                                        update(() => mainUptrend = value),
                              ),
                              DropdownButtonFormField<int>(
                                value: ema,
                                decoration: const InputDecoration(
                                  labelText: '每日收盤追蹤均線',
                                ),
                                items:
                                    (hybrid ? [9, 21] : [9, 21, 50])
                                        .map(
                                          (value) => DropdownMenuItem(
                                            value: value,
                                            child: Text('$value EMA'),
                                          ),
                                        )
                                        .toList(),
                                onChanged: (value) {
                                  if (value != null) update(() => ema = value);
                                },
                              ),
                              const SizedBox(height: 10),
                              Text(
                                hybrid
                                    ? 'Hybrid v1.3.0：1.5R提示保本，3R／5R各原始股數15%。'
                                    : '此持倉保留舊版計畫（2R保本）；不因App升版改寫。',
                              ),
                              if (hybrid) ...[
                                TextFormField(
                                  controller: actualStop,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '目前已確認硬停損（空白沿用初始）',
                                    helperText: '請核對券商狀態後手動記錄；App不會掛單。',
                                  ),
                                ),
                                CheckboxListTile(
                                  value: sold3R,
                                  title: const Text('3R分批已成交'),
                                  onChanged:
                                      (v) => update(() => sold3R = v ?? false),
                                ),
                                CheckboxListTile(
                                  value: sold5R,
                                  title: const Text('5R分批已成交'),
                                  onChanged:
                                      (v) => update(() => sold5R = v ?? false),
                                ),
                              ],
                              const Text(
                                '修改成本、原始停損或股票代碼會建立新R基準。分批成交後請同步更新剩餘股數。',
                              ),
                              if (dialogError != null)
                                Text(
                                  dialogError!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () {
                          if (!form.currentState!.validate()) return;
                          try {
                            final code = canonicalSymbol(symbol.text, market);
                            final result = PortfolioPosition(
                              id:
                                  holding?.id ??
                                  'holding-${DateTime.now().microsecondsSinceEpoch}',
                              symbol: code,
                              name: name.text.trim(),
                              market: market,
                              entryPrice: double.parse(entry.text),
                              shares: int.parse(shares.text),
                              initialStop: double.parse(stop.text),
                              trailingEma: ema,
                              mainUptrend: mainUptrend,
                              trailingStop:
                                  actualStop.text.trim().isEmpty
                                      ? null
                                      : double.parse(actualStop.text),
                              strategyVersion:
                                  holding?.strategyVersion ??
                                  HybridProtocol.version,
                              originalShares: holding?.originalShares,
                              sold3R: sold3R,
                              sold5R: sold5R,
                            );
                            Navigator.pop(dialogContext, result);
                          } catch (error) {
                            update(() => dialogError = '$error');
                          }
                        },
                        child: const Text('儲存'),
                      ),
                    ],
                  ),
            ),
      );
      if (result != null && mounted) {
        setState(() => _market = result.market);
        await _run(() => controller.savePortfolioPosition(result));
      }
    } finally {
      for (final field in [symbol, name, entry, shares, stop, actualStop]) {
        field.dispose();
      }
    }
  }

  Widget _numberField(
    TextEditingController text,
    String label, {
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: text,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label),
    validator:
        validator ??
        (value) {
          final n = double.tryParse(value ?? '');
          return n == null || !n.isFinite || n <= 0 ? '請輸入有限正數' : null;
        },
  );

  Future<void> _editQuote(PortfolioPosition holding) async {
    if (!controller.settings.useMockData) return;
    final quote = controller.portfolioQuotes[holding.key];
    final fields =
        [
              quote?.currentPrice,
              quote?.ema9,
              quote?.ema21,
              quote?.ema50,
              quote?.lastClose,
            ]
            .map((n) => TextEditingController(text: n == null ? '' : '$n'))
            .toList();
    final form = GlobalKey<FormState>();
    var confirmed = quote?.closeConfirmed ?? false;
    var large = quote?.isLargeLiquid ?? false;
    try {
      final result = await _showOwnedDialog<PortfolioQuote>(
        context: context,
        builder:
            (dialogContext) => StatefulBuilder(
              builder:
                  (context, update) => AlertDialog(
                    title: Text('${holding.symbol} 示範行情'),
                    content: SizedBox(
                      width: 440,
                      child: SingleChildScrollView(
                        child: Form(
                          key: form,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '這些數值僅為本機情境試算，不會取代實際市場報價。EMA 以已完成日 K 為基準。',
                              ),
                              const SizedBox(height: 12),
                              for (var i = 0; i < 4; i++) ...[
                                _numberField(
                                  fields[i],
                                  [
                                    '目前市價',
                                    '日線 9 EMA',
                                    '日線 21 EMA',
                                    '日線 50 EMA',
                                  ][i],
                                ),
                                const SizedBox(height: 12),
                              ],
                              _numberField(
                                fields[4],
                                '已完成交易日收盤價',
                                validator: (text) {
                                  if (!confirmed && (text ?? '').trim().isEmpty)
                                    return null;
                                  final value = double.tryParse(text ?? '');
                                  return value == null ||
                                          !value.isFinite ||
                                          value <= 0
                                      ? '請輸入有效收盤價'
                                      : null;
                                },
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('收盤資料已確認'),
                                subtitle: const Text('未確認時不觸發每日均線出場'),
                                value: confirmed,
                                onChanged:
                                    (value) => update(() => confirmed = value),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('大型流動性股'),
                                value: large,
                                onChanged:
                                    (value) => update(() => large = value),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () {
                          if (!form.currentState!.validate()) return;
                          final now = DateTime.now().toUtc();
                          Navigator.pop(
                            dialogContext,
                            PortfolioQuote(
                              symbol: holding.symbol,
                              name:
                                  quote?.name ??
                                  (holding.name.isEmpty
                                      ? holding.symbol
                                      : holding.name),
                              market: holding.market,
                              currentPrice: double.parse(fields[0].text),
                              ema9: double.parse(fields[1].text),
                              ema21: double.parse(fields[2].text),
                              ema50: double.parse(fields[3].text),
                              lastClose: double.tryParse(fields[4].text),
                              closeConfirmed: confirmed,
                              quoteTimestamp: now,
                              closeTimestamp: confirmed ? now : null,
                              isLargeLiquid: large,
                              source: '使用者輸入的虛構行情／收盤情境（非即時市場）',
                            ),
                          );
                        },
                        child: const Text('套用並診斷'),
                      ),
                    ],
                  ),
            ),
      );
      if (result != null && mounted)
        await _run(() => controller.setMockPortfolioQuote(result));
    } finally {
      for (final field in fields) {
        field.dispose();
      }
    }
  }

  Future<void> _delete(PortfolioPosition holding) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('刪除 ${holding.symbol}？'),
            content: const Text('將刪除本機庫存與這筆持股的最高 R／追蹤停損紀錄。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('刪除'),
              ),
            ],
          ),
    );
    if (confirmed == true && mounted)
      await _run(() => controller.deletePortfolioPosition(holding.id));
  }

  Widget _metric(String label, String value) => SizedBox(
    width: 155,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    ),
  );

  Widget _holdingCard(PortfolioPosition holding) {
    final quote = controller.portfolioQuotes[holding.key];
    final diagnosis = controller.diagnosisFor(holding);
    final error = controller.portfolioErrors[holding.key];
    final color =
        diagnosis?.action == ExitAction.exit
            ? Colors.red
            : diagnosis?.action == ExitAction.trim
            ? Colors.green
            : Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        holding.symbol,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '${quote?.name ?? holding.name} · ${holding.shares} 股 · ${holding.market.currency}',
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  enabled: !_busy && !controller.portfolioLoading,
                  onSelected: (action) {
                    if (action == 'edit') {
                      _editHolding(holding: holding);
                    } else if (action == 'quote') {
                      _editQuote(holding);
                    } else {
                      _delete(holding);
                    }
                  },
                  itemBuilder:
                      (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('編輯持股')),
                        if (controller.settings.useMockData)
                          const PopupMenuItem(
                            value: 'quote',
                            child: Text('調整示範行情'),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('刪除持股'),
                        ),
                      ],
                ),
              ],
            ),
            if (!controller.settings.useMockData &&
                holding.id.startsWith('demo-'))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('先前示範庫存，請確認成本與股數或刪除。'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              children: [
                _metric(
                  '目前市價',
                  quote == null ? '尚無行情' : _price(quote.currentPrice),
                ),
                _metric(
                  '買進成本／固定 1R',
                  '${_price(holding.entryPrice)}／${_price(holding.riskPerShare)}',
                ),
                _metric('初始硬停損', _price(holding.initialStop)),
                _metric(
                  '目前浮動硬停損',
                  _price(
                    diagnosis?.position.trailingStop ?? holding.trailingStop,
                  ),
                ),
              ],
            ),
            if (quote != null &&
                (quote.isCached ||
                    quote.isStale ||
                    controller.isPortfolioQuoteCached(holding.key)))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  quote.cacheWarning ?? '顯示上次快取行情；報價時間維持原值，請更新後再評估操作。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error),
                    TextButton.icon(
                      onPressed:
                          _busy || controller.portfolioLoading
                              ? null
                              : () => _run(
                                () => controller.refreshPortfolio(
                                  forceRefresh: true,
                                ),
                              ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重試行情'),
                    ),
                  ],
                ),
              ),
            if (diagnosis != null && quote != null) ...[
              const Divider(),
              Text(
                holding.usesHybrid
                    ? 'Hybrid v1.3.0 · 原始${holding.originalShares}股'
                    : '舊持倉計畫 · 保留原規則',
              ),
              if (holding.usesHybrid)
                Text(
                  '1.5R保本觸發：${_price(diagnosis.breakEvenTrigger)}；費後保本價需另計交易成本。',
                ),
              if (diagnosis.breakEvenSuggested)
                Text(
                  '保本建議待確認：提高硬停損至至少${_price(diagnosis.suggestedStop)}加交易費用；尚未修改券商訂單。',
                ),
              Text(
                diagnosis.label,
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
              for (final reason in diagnosis.reasons) Text('• $reason'),
              if (diagnosis.action == ExitAction.trim)
                Text(
                  diagnosis.trimShares > 0
                      ? '本次參考減碼 ${diagnosis.trimShares} 股（${(diagnosis.trimShares / holding.shares * 100).toStringAsFixed(1)}%）'
                      : holding.usesHybrid
                      ? '無未完成的3R／5R梯次，或部位過小；額外減碼須另訂計畫。'
                      : '股數不足以整股減碼 10%～15%；不強制賣出 1 股。',
                ),
              Text(diagnosis.health),
              Wrap(
                spacing: 12,
                children: [
                  _metric(
                    '未實現損益',
                    '${holding.market.currencySymbol}${_price(diagnosis.unrealizedPnl)}',
                  ),
                  _metric(
                    '目前／最高 R',
                    '${diagnosis.currentR.toStringAsFixed(2)}R／${diagnosis.position.peakR.toStringAsFixed(2)}R',
                  ),
                  _metric(
                    '部位曝險／上限',
                    '${diagnosis.positionPercent.toStringAsFixed(1)}%／${diagnosis.exposureLimitPercent.toStringAsFixed(0)}%',
                  ),
                  _metric(
                    '每日收盤 ${diagnosis.selectedEma} EMA 界線',
                    _price(diagnosis.emaBoundary),
                  ),
                ],
              ),
              if (diagnosis.overExposure)
                Text(
                  '⚠ 部位曝險超標；中小型股 25% 與強勢止盈的 35% 條件分別判定。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (diagnosis.currentR / 10).clamp(0.0, 1.0).toDouble(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children:
                    diagnosis.targets.entries
                        .map(
                          (target) => Chip(
                            label: Text(
                              '${target.key}R · ${_price(target.value)}',
                            ),
                            backgroundColor:
                                diagnosis.currentR >= target.key
                                    ? color.withValues(alpha: 0.14)
                                    : null,
                          ),
                        )
                        .toList(),
              ),
              Text(
                '每日均線：9=${_price(quote.ema9)} · 21=${_price(quote.ema21)} · 50=${_price(quote.ema50)}',
              ),
              Text(
                quote.closeConfirmed
                    ? '已確認日收盤 ${_price(quote.lastClose!)} · ${_date(quote.closeTimestamp!)}'
                    : '收盤尚未確認；市價低於均線不觸發每日出場',
              ),
              const SizedBox(height: 6),
              Text(
                '${quote.source}\n資料更新時間：${_date(quote.quoteTimestamp)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (controller.settings.useMockData)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _editQuote(holding),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('調整示範市價／收盤'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final holdings =
          controller.portfolioPositions
              .where((p) => p.market == _market)
              .toList();
      final totalValue = holdings.fold<double>(
        0,
        (sum, p) =>
            sum +
            (controller.portfolioQuotes[p.key]?.currentPrice ?? 0) * p.shares,
      );
      final missing =
          holdings
              .where((p) => !controller.portfolioQuotes.containsKey(p.key))
              .length;
      return Scaffold(
        appBar: AppBar(
          title: const Text('我的持股庫存'),
          actions: [
            IconButton(
              tooltip: '更新行情',
              onPressed:
                  controller.portfolioLoading || _busy
                      ? null
                      : () => _run(
                        () => controller.refreshPortfolio(forceRefresh: true),
                      ),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed:
              _busy || controller.portfolioLoading
                  ? null
                  : () => _editHolding(),
          icon: const Icon(Icons.add),
          label: const Text('新增持股'),
        ),
        body: RefreshIndicator(
          onRefresh: () => controller.refreshPortfolio(forceRefresh: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<StockMarket>(
                        segments: const [
                          ButtonSegment(
                            value: StockMarket.tw,
                            label: Text('台股 TW'),
                          ),
                          ButtonSegment(
                            value: StockMarket.us,
                            label: Text('美股 US'),
                          ),
                        ],
                        selected: {_market},
                        onSelectionChanged:
                            (values) => setState(() => _market = values.first),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        controller.settings.useMockData
                            ? '離線假行情情境；範例持股與報價均為虛構。'
                            : controller.settings.dataProvider == 'direct'
                            ? 'Yahoo Finance 最新可用行情 · 裝置上計算每日 EMA 與持股 R 倍數。'
                            : 'Python API 最新可用市場行情。',
                      ),
                      if (!controller.settings.useMockData) ...[
                        Text(
                          controller.autoRefreshActive
                              ? '前台每 60 秒自動更新；下拉可立即重新取得報價。'
                              : '自動更新暫停；下拉可立即重新取得報價。',
                        ),
                        if (controller.portfolioUpdatedAt != null)
                          Text(
                            '最近取得行情：${_date(controller.portfolioUpdatedAt!)}',
                          ),
                      ],
                      const Text('庫存只儲存在此裝置，不連接券商。各市場以自身帳戶淨值計算，不合併 USD／TWD。'),
                      const SizedBox(height: 12),
                      Text(
                        '帳戶淨值 ${_market.currencySymbol}${_price(controller.equityFor(_market))}',
                      ),
                      Text(
                        '已知持股市值 ${_price(totalValue)} · 曝險 ${(totalValue / controller.equityFor(_market) * 100).toStringAsFixed(1)}%'
                        '${missing > 0 ? '（$missing 筆缺少行情，合計不完整）' : ''}',
                      ),
                      Text(
                        '9 EMA 強勢正乖離門檻：${(_threshold ?? controller.euphoriaPercent).toStringAsFixed(1)}%',
                      ),
                      Slider(
                        value: _threshold ?? controller.euphoriaPercent,
                        min: 15,
                        max: 20,
                        divisions: 10,
                        onChanged:
                            (value) => setState(() => _threshold = value),
                        onChangeEnd:
                            (value) => _run(() async {
                              await controller.setEuphoriaPercent(value);
                              if (mounted) setState(() => _threshold = null);
                            }),
                      ),
                      if (controller.portfolioNotice != null)
                        Text(
                          controller.portfolioNotice!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (controller.portfolioLoading)
                        const LinearProgressIndicator(),
                      if (holdings.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('尚無持股，按「新增持股」開始診斷。'),
                        ),
                      ...holdings.map(_holdingCard),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
