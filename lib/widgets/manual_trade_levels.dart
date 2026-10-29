import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/stock_candidate.dart';
import '../services/strategy_engine.dart';

/// Optional arithmetic for the user's own prices, separate from a scanned setup.
///
/// In particular, an unconfirmed candidate never receives an invented stop or
/// an order quantity from this widget. Manual values remain local to this state.
class ManualTradeLevels extends StatefulWidget {
  const ManualTradeLevels({super.key, required this.candidate});

  final StockCandidate candidate;

  @override
  State<ManualTradeLevels> createState() => _ManualTradeLevelsState();
}

class _ManualTradeLevelsState extends State<ManualTradeLevels> {
  final _entry = TextEditingController();
  final _stop = TextEditingController();
  final _number = NumberFormat('#,##0.00', 'en_US');
  TradeLevels? _levels;
  String? _error;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _resetFields();
    _entry.addListener(_recalculate);
    _stop.addListener(_recalculate);
  }

  @override
  void didUpdateWidget(covariant ManualTradeLevels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.candidate.id != widget.candidate.id ||
        oldWidget.candidate.symbol != widget.candidate.symbol ||
        oldWidget.candidate.market != widget.candidate.market) {
      _resetFields();
    }
    // A new background quote for the same identity must not erase typing.
  }

  void _resetFields() {
    _resetting = true;
    // Preserve the candidate's decimal trigger without inventing a stop price.
    _entry.text = widget.candidate.triggerPrice.toString();
    _stop.clear();
    _levels = null;
    _error = null;
    _resetting = false;
  }

  void _recalculate() {
    if (_resetting) return;
    TradeLevels? next;
    String? error;
    final entryText = _entry.text.trim();
    final stopText = _stop.text.trim();
    final entry = double.tryParse(entryText);
    final stop = double.tryParse(stopText);
    if (entryText.isEmpty) {
      error = '請輸入假設買進價。';
    } else if (entry == null || !entry.isFinite || entry <= 0) {
      error = '假設買進價必須為大於 0 的有限數字。';
    } else if (stopText.isEmpty) {
      error = '請輸入假設停損價。';
    } else if (stop == null || !stop.isFinite || stop <= 0) {
      error = '假設停損價必須為大於 0 的有限數字。';
    } else if (stop >= entry) {
      error = '假設停損價必須低於假設買進價。';
    } else {
      try {
        final calculated = StrategyEngine.calculateHypotheticalLevels(
          entryPrice: entry,
          stopPrice: stop,
        );
        if (!calculated.riskPerShare.isFinite ||
            !calculated.stopPercent.isFinite ||
            calculated.targets.values.any((price) => !price.isFinite)) {
          throw ArgumentError('計算超出有限數值範圍。');
        }
        next = calculated;
      } on ArgumentError {
        error = '輸入數值超出可計算範圍，請調整假設價格。';
      }
    }
    setState(() {
      // Always clear old output on invalid or empty input.
      _levels = next;
      _error = error;
    });
  }

  String _price(double value) =>
      '${widget.candidate.market.currencySymbol}${_number.format(value)} '
      '${widget.candidate.market.currency}';

  Widget _metric(String label, String value, {String? keyName}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label)),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Text(value,
                  key: keyName == null ? null : ValueKey(keyName),
                  textAlign: TextAlign.end),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final levels = _levels;
    return ExpansionTile(
      title: const Text('手動試算 3R／5R'),
      leading: const Icon(Icons.calculate_outlined),
      maintainState: true,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        const Text('自行輸入假設價格；不會變更推薦、停損或買進股數。'),
        const SizedBox(height: 8),
        Text('試算幣別：${candidate.market.currency} · '
            '${candidate.market.currencySymbol}；不換匯或套用帳戶本金。'),
        const SizedBox(height: 12),
        TextField(
          key: ValueKey('manual-entry-${candidate.id}'),
          controller: _entry,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: '假設買進價（${candidate.market.currency}）',
            prefixText: '${candidate.market.currencySymbol} ',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: ValueKey('manual-stop-${candidate.id}'),
          controller: _stop,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: '假設停損價（${candidate.market.currency}）',
            prefixText: '${candidate.market.currencySymbol} ',
            hintText: '自行輸入，不自動推定',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Text(_error!,
              key: ValueKey('manual-error-${candidate.id}'),
              style: TextStyle(color: Theme.of(context).colorScheme.error))
        else if (levels == null)
          const Text('輸入假設停損價後顯示試算目標；這不是系統確認買點。'),
        if (levels != null) ...[
          Text('假設價格試算 · 非買進建議',
              key: ValueKey('manual-result-${candidate.id}'),
              style: Theme.of(context).textTheme.titleSmall),
          _metric('1R 價差', _price(levels.riskPerShare),
              keyName: 'manual-risk-${candidate.id}'),
          _metric('假設停損幅度', '${_number.format(levels.stopPercent)}%',
              keyName: 'manual-percent-${candidate.id}'),
          for (final r in [3, 5, 10])
            _metric('${r}R 目標價', _price(levels.targetPrice(r)),
                keyName: 'manual-${r}r-${candidate.id}'),
          if (levels.stopPercent > 5)
            Text('假設停損幅度超過 5%；此試算不代表通過策略進場條件，不會產生買進建議。',
                key: ValueKey('manual-wide-stop-${candidate.id}'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _entry.dispose();
    _stop.dispose();
    super.dispose();
  }
}
