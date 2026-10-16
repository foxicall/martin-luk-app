import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/stock_candidate.dart';
import '../services/strategy_engine.dart';

/// A single-stock review and risk calculator. A watchlist item never becomes a
/// trade merely because an account balance has been entered.
class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({
    super.key,
    required this.candidate,
    required this.initialEquity,
    this.onEquityChanged,
    this.dataSource,
    this.isCached = false,
  });

  final StockCandidate candidate;
  final double initialEquity;
  final ValueChanged<double>? onEquityChanged;
  final String? dataSource;
  final bool isCached;

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  late final TextEditingController _equityController;
  PositionPlan? _plan;
  String? _inputError;

  bool get _eligible => widget.candidate.hasValidStopRange && !widget.isCached;

  String get _currency => widget.candidate.market.currencySymbol;

  String get _capitalLabel => widget.candidate.market == StockMarket.tw
      ? '台股帳戶總資金（Capital）'
      : '美股帳戶總資金（Capital）';

  // Keep stored fractional currency units; rounding the seed to an integer
  // would change the risk budget even before the user edits the account.
  String _inputNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  String _money(double value) =>
      '$_currency${_number(value)} ${widget.candidate.market.currency}';

  String get _capitalHelper {
    final equity = double.tryParse(
        _equityController.text.trim().replaceAll(',', ''));
    final budget = equity != null && equity.isFinite && equity > 0
        ? _money(equity * 0.005)
        : '請輸入有效資金';
    return '僅更新此市場 ${widget.candidate.market.currency} 帳戶；'
        '每筆 0.5% 風險預算：$budget。';
  }

  @override
  void initState() {
    super.initState();
    _equityController = TextEditingController(
      text: _inputNumber(widget.initialEquity),
    );
    _recalculate(notify: false);
  }

  @override
  void didUpdateWidget(covariant CalculatorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.candidate.market != widget.candidate.market ||
        oldWidget.initialEquity != widget.initialEquity) {
      // Reusing the screen for another market must seed its own account, even
      // after invalid input, and discard the previous market's position plan.
      _equityController.text = _inputNumber(widget.initialEquity);
    }
    _recalculate(notify: false);
  }

  @override
  void dispose() {
    _equityController.dispose();
    super.dispose();
  }

  void _recalculate({bool notify = true}) {
    final text = _equityController.text.trim().replaceAll(',', '');
    final equity = double.tryParse(text);
    // Clear the preceding result before validation: invalid text must never
    // leave a previously successful buy recommendation on screen.
    _plan = null;
    _inputError = null;
    if (equity == null || !equity.isFinite || equity <= 0) {
      _inputError = '請輸入大於 0 的有效帳戶淨值';
    } else if (_eligible) {
      try {
        _plan = StrategyEngine.calculate(widget.candidate, equity);
      } on ArgumentError catch (error) {
        _inputError = error.message?.toString() ?? '無法計算此標的的部位';
      } on StateError catch (error) {
        _inputError = error.message;
      } catch (_) {
        _inputError = '計算失敗，請重新整理行情後再試';
      }
    }
    if (notify && mounted) {
      setState(() {});
      if (_inputError == null && equity != null) {
        widget.onEquityChanged?.call(equity);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stock = widget.candidate;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(stock.symbol, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
              label: Text(stock.market == StockMarket.tw ? 'TW · 台股' : 'US · 美股'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStockHeader(context),
                if (widget.isCached) ...[
                  const SizedBox(height: 12),
                  _notice(context, '顯示上次快取',
                      '目前為原始時間的快取行情與型態；請回到推薦頁下拉更新後再評估進場。'),
                ],
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final calculator = _buildCalculator(context);
                    final details = _buildDetails(context);
                    if (constraints.maxWidth >= 760) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 6, child: calculator),
                          const SizedBox(width: 20),
                          Expanded(flex: 5, child: details),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [calculator, const SizedBox(height: 20), details],
                    );
                  },
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '股數以整股計算；台股可用零股交易。0.5% 為依停損價估算的名目風險，'
                    '未包含手續費、滑價與跳空。此頁提供策略評估，不會自動下單。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.6,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStockHeader(BuildContext context) {
    final stock = widget.candidate;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stock.name,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.onPrimaryContainer,
                  )),
          const SizedBox(height: 6),
          Text('${stock.sector}  ·  ${stock.isLargeLiquid ? '大型流動性股票' : '一般股票'}',
              style: TextStyle(color: colors.onPrimaryContainer)),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _tag(context, _eligible ? '進場條件已確認' : '觀察清單 · 等待確認',
                  icon: _eligible ? Icons.verified_outlined : Icons.visibility_outlined),
              ...stock.patterns.map((pattern) => _tag(context, pattern)),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 28,
            runSpacing: 16,
            children: [
              _metric(context, 'ADR · 20 日', '${stock.adrPercent.toStringAsFixed(2)}%'),
              _metric(context, 'RS 強度', stock.rsScore.toStringAsFixed(1)),
              _metric(context, 'RS 排名', '#${stock.rsRank}'),
              if (stock.quotePrice != null)
                _metric(context, '最新可用市價', _money(stock.quotePrice!)),
              _metric(context, '${stock.triggerType ?? '條件'} 觸發價', _money(stock.triggerPrice)),
              if (stock.confirmationPrice != null)
                _metric(context, '突破確認價', _money(stock.confirmationPrice!)),
            ],
          ),
          if (stock.dailyCloses.length >= 2) ...[
            const SizedBox(height: 22),
            SizedBox(
              height: 82,
              width: double.infinity,
              child: Semantics(
                label: '最近 ${stock.dailyCloses.length} 筆日收盤價走勢',
                child: CustomPaint(
                  painter: _CloseLinePainter(stock.dailyCloses, colors.primary),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('最近 ${stock.dailyCloses.length} 筆日收盤價 · 趨勢示意',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onPrimaryContainer,
                    )),
          ],
        ],
      ),
    );
  }

  Widget _buildCalculator(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final stock = widget.candidate;
    final plan = _plan;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('部位計算機', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('每筆最多承擔 ${stock.market.currency} 帳戶總資金 0.5% 的停損風險',
                style: TextStyle(color: colors.onSurfaceVariant)),
            const SizedBox(height: 20),
            TextField(
              key: ValueKey('calculator-capital-${stock.market.name}'),
              controller: _equityController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.done,
              onChanged: (_) => _recalculate(),
              onSubmitted: (_) => _recalculate(),
              decoration: InputDecoration(
                labelText: _capitalLabel,
                prefixText: '$_currency ',
                suffixText: stock.market.currency,
                border: const OutlineInputBorder(),
                errorText: _inputError,
                helperText: _capitalHelper,
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 20),
            if (!_eligible)
              _notice(
                context,
                widget.isCached ? '快取行情待更新' : '等待進場確認',
                widget.isCached
                    ? '請取得最新行情與型態確認後再計算建議買進股數。'
                    : '此標的尚無有效突破或實際停損；當日低點風險須 ≤5%，'
                    '超過時才採 1.5%–3% 的分鐘 K 低點。'
                    '確認進場 K 棒與停損後才會提供買進股數。',
              ),
            if (_eligible && plan != null) ...[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('建議買進股數',
                        style: TextStyle(color: colors.onSecondaryContainer)),
                    const SizedBox(height: 4),
                    Text('${_integer(plan.shares)} 股',
                        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: colors.onSecondaryContainer,
                            )),
                    const SizedBox(height: 6),
                    Text('${_money(plan.amount)}  ·  帳戶資金 ${plan.positionPercent.toStringAsFixed(2)}%',
                        style: TextStyle(color: colors.onSecondaryContainer)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _dataRow(context, '0.5% 風險預算', _money(plan.riskBudget)),
              _dataRow(context, '此部位名目風險', _money(plan.riskAmount)),
              _dataRow(context, '最大持倉上限', '${plan.capPercent.toStringAsFixed(0)}%'),
              if (plan.shares == 0)
                _notice(context, '淨值不足', '風險與曝險上限不足以購入 1 股。'),
            ],
            if (_eligible && plan == null && _inputError == null)
              _notice(context, '尚無計算結果', '請輸入有效的帳戶淨值。'),
            const Divider(height: 32),
            _buildTradeLevels(context),
          ],
        ),
      ),
    );
  }

  /// Targets share the validated position plan; an incomplete entry, stale
  /// quote or invalid balance never acquires executable-looking target values.
  Widget _buildTradeLevels(BuildContext context) {
    final stock = widget.candidate;
    final plan = _plan;
    final pending = widget.isCached ? '待更新' : '待確認';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('進出場價位與分批計畫',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _dataRow(context,
            plan == null
                ? '${stock.triggerType ?? '條件'} 觸發參考價'
                : '假設買價 · ${stock.triggerType ?? '條件'} 觸發',
            _money(stock.triggerPrice),
            valueKey: ValueKey('calculator-entry-${stock.id}')),
        _dataRow(context, '初始硬停損參考',
            plan == null ? pending : _money(stock.stopPrice!),
            valueKey: ValueKey('calculator-stop-${stock.id}')),
        _dataRow(context, '停損來源', plan == null
            ? '待確認實際低點'
            : stock.stopSource == 'entry_bar_low'
                ? '實際進場分鐘 K 低點' : '突破日當日實際低點'),
        _dataRow(context, '停損幅度',
            plan == null ? pending : '${plan.stopPercent.toStringAsFixed(2)}%',
            valueKey: ValueKey('calculator-stop-percent-${stock.id}')),
        _dataRow(context, '每股風險 · 1R',
            plan == null ? pending : _money(plan.riskPerShare),
            valueKey: ValueKey('calculator-1r-${stock.id}')),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _targetChip(context, '3R 賣價 · 原始股數 15%',
                plan == null ? pending : _money(plan.targetPrice(3)),
                valueKey: ValueKey('calculator-3r-${stock.id}')),
            _targetChip(context, '5R 賣價 · 再賣原始股數 15%',
                plan == null ? pending : _money(plan.targetPrice(5)),
                valueKey: ValueKey('calculator-5r-${stock.id}')),
            _targetChip(context, '10R · 額外觀察目標',
                plan == null ? pending : _money(plan.targetPrice(10)),
                valueKey: ValueKey('calculator-10r-${stock.id}')),
          ],
        ),
        const SizedBox(height: 12),
        Text('剩餘 70%：以日收盤跌破 9 EMA 為追蹤出場條件。',
            key: ValueKey('calculator-trailing-${stock.id}'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              height: 1.6,
            )),
        const SizedBox(height: 6),
        Text(plan == null
                ? '買點、實際停損與有效本金確認後，才提供完整價位；目前為觀察參考。'
                : '1R＝假設買價－初始硬停損；3R／5R＝假設買價＋3／5×1R。'
                    '兩次各賣原始股數的 15%，合計 30%；整股交易需另行調整股數。'
                    '停損先觸發則先出場。'
                    '價位為策略試算，請確認交易所跳動單位與最新行情後再下單。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
            )),
      ],
    );
  }

  Widget _buildDetails(BuildContext context) {
    final stock = widget.candidate;
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('型態與評估依據', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final pattern in stock.patterns)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle_outline, size: 20, color: colors.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(pattern)),
                  ],
                ),
              ),
            if (stock.patterns.isEmpty)
              Text('目前沒有已確認的突破型態。',
                  style: TextStyle(color: colors.onSurfaceVariant)),
            if (stock.notes.isNotEmpty) ...[
              const Divider(height: 24),
              for (final note in stock.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('• $note',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.6,
                          )),
                ),
            ],
            const Divider(height: 28),
            if (stock.ema9 != null)
              _dataRow(context, '日線 9 EMA', _money(stock.ema9!)),
            if (stock.ema21 != null)
              _dataRow(context, '日線 21 EMA', _money(stock.ema21!)),
            if (stock.ema50 != null)
              _dataRow(context, '日線 50 EMA', _money(stock.ema50!)),
            if (widget.dataSource != null)
              _dataRow(context, '行情來源', widget.dataSource!),
            _dataRow(context, '資料更新時間', _date(stock.dataTimestamp)),
            _dataRow(context, '訊號時間',
                stock.signalTimestamp == null ? '尚未確認' : _date(stock.signalTimestamp!)),
            const SizedBox(height: 8),
            Text('時間以台北 UTC+08 顯示。最新可用市價與 PDH／ORH 觸發價分別列示；進場前請確認報價與訊號有效性。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.5,
                    )),
          ],
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  )),
        ],
      );

  Widget _tag(BuildContext context, String text, {IconData? icon}) => Chip(
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text(text),
        visualDensity: VisualDensity.compact,
      );

  Widget _dataRow(BuildContext context, String label, String value,
      {Key? valueKey}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant))),
            const SizedBox(width: 12),
            Flexible(
                child: Text(value,
                    key: valueKey,
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Widget _notice(BuildContext context, String title, String message) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(message, style: const TextStyle(height: 1.6)),
          ],
        ),
      );

  Widget _targetChip(BuildContext context, String label, String value,
      {Key? valueKey}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(value, key: valueKey),
          ],
        ),
      );

  String _date(DateTime time) {
    final taipei = time.toUtc().add(const Duration(hours: 8));
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(taipei)} · 台北 UTC+08';
  }

  String _number(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final whole = parts.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return '$whole.${parts.last}';
  }

  String _integer(int value) => value.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (_) => ',',
      );
}

/// Small close-price plot only; it does not invent candle/volume data or imply
/// that offline demonstration prices are a live chart.
class _CloseLinePainter extends CustomPainter {
  _CloseLinePainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final prices = values.where((price) => price.isFinite).toList();
    if (prices.length < 2 || size.isEmpty) return;
    final minValue = prices.reduce(math.min);
    final maxValue = prices.reduce(math.max);
    final range = math.max(maxValue - minValue, 0.01);
    final line = Path();
    for (var i = 0; i < prices.length; i++) {
      final x = i / (prices.length - 1) * size.width;
      final y = 6 + (1 - (prices[i] - minValue) / range) * (size.height - 12);
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.01)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.3
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CloseLinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
