import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import '../services/stock_search_service.dart';

/// Reusable autocomplete for dashboard and holding forms. Suggestions are
/// computed after 200 ms and the supplied controller receives a Yahoo symbol.
/// Manual input remains possible if the offline dictionary is unavailable.
class StockSearchField extends StatefulWidget {
  const StockSearchField({
    super.key,
    required this.onSelected,
    this.controller,
    this.service,
    this.market,
    this.enabled = true,
    this.label = '搜尋股票代碼／中英文名稱',
    this.helperText = '例如：台積電、2330、TSMC、NVDA、輝達',
    this.validator,
  });

  final ValueChanged<StockItem> onSelected;
  final TextEditingController? controller;
  final StockSearchService? service;
  final StockMarket? market;
  final bool enabled;
  final String label;
  final String helperText;
  final FormFieldValidator<String>? validator;

  @override
  State<StockSearchField> createState() => _StockSearchFieldState();
}

class _StockSearchFieldState extends State<StockSearchField> {
  late TextEditingController _text;
  final FocusNode _focus = FocusNode();
  StockSearchService? _service;
  Timer? _debounce;
  Timer? _blur;
  List<StockItem> _results = const [];
  int _active = 0;
  bool _suppress = false;
  bool _open = false;
  String? _loadError;
  String? _readyQuery;

  @override
  void initState() {
    super.initState();
    _text = widget.controller ?? TextEditingController();
    _text.addListener(_queryChanged);
    _focus.addListener(_focusChanged);
    _load();
  }

  Future<void> _load() async {
    final provided = widget.service;
    try {
      final loaded = provided ?? await StockSearchService.load();
      if (!mounted || widget.service != provided) return;
      setState(() { _service = loaded; _loadError = null; });
      if (_readyQuery == _text.text && _focus.hasFocus) _search();
    } catch (_) {
      if (!mounted || widget.service != provided) return;
      setState(() => _loadError = '股票字典讀取失敗；可手動輸入標準代碼。');
    }
  }

  @override
  void didUpdateWidget(covariant StockSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _text.removeListener(_queryChanged);
      if (oldWidget.controller == null) _text.dispose();
      _text = widget.controller ?? TextEditingController();
      _text.addListener(_queryChanged);
      _clear();
    }
    if (widget.service != oldWidget.service) {
      _clear();
      _service = null;
      _load();
    }
    if (widget.market != oldWidget.market || !widget.enabled) _clear();
  }

  void _clear() {
    _debounce?.cancel();
    _readyQuery = null;
    _results = const [];
    _open = false;
  }

  void _queryChanged() {
    if (_suppress || !widget.enabled) return;
    _debounce?.cancel();
    _readyQuery = null;
    setState(() { _results = const []; _open = false; _active = 0; });
    if (StockSearchService.normalize(_text.text).isEmpty) return;
    final query = _text.text;
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || query != _text.text || !_focus.hasFocus) return;
      _readyQuery = query;
      _search();
    });
  }

  void _search() {
    final service = _service;
    if (service == null) return;
    setState(() {
      _results = service.searchStock(_text.text, market: widget.market, limit: 8);
      _active = 0;
      _open = _text.text.trim().isNotEmpty;
    });
  }

  void _focusChanged() {
    _blur?.cancel();
    if (_focus.hasFocus) {
      if (_text.text.isNotEmpty) _queryChanged();
    } else {
      // Give an option's tap callback time to run before closing the list.
      _blur = Timer(const Duration(milliseconds: 100), () {
        if (mounted && !_focus.hasFocus) setState(() => _open = false);
      });
    }
  }

  void _pick(StockItem stock) {
    _debounce?.cancel();
    _blur?.cancel();
    _suppress = true;
    _text.value = TextEditingValue(text: stock.symbol,
        selection: TextSelection.collapsed(offset: stock.symbol.length));
    _suppress = false;
    setState(_clear);
    _focus.unfocus();
    widget.onSelected(stock);
  }

  void _move(int direction) {
    if (!_open || _results.isEmpty) return;
    setState(() => _active = (_active + direction) % _results.length);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
      const SingleActivator(LogicalKeyboardKey.escape): () => setState(_clear),
    },
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextFormField(
        controller: _text,
        focusNode: _focus,
        enabled: widget.enabled,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: _loadError ?? widget.helperText,
          helperMaxLines: 3,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(tooltip: '清除搜尋', onPressed: widget.enabled ? _text.clear : null,
              icon: const Icon(Icons.close, size: 20)),
        ),
        validator: widget.validator,
        onFieldSubmitted: (_) {
          if (_open && _results.isNotEmpty) _pick(_results[_active]);
        },
      ),
      if (_open) Container(
        key: const ValueKey('stock-search-suggestions'),
        margin: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        constraints: const BoxConstraints(maxHeight: 300),
        child: _results.isEmpty
            ? const Padding(padding: EdgeInsets.all(14), child: Text('未找到相符股票；可手動輸入標準代碼。'))
            : ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final stock = _results[index];
                  return Semantics(
                    button: true,
                    label: '${stock.marketTag} ${stock.symbol} ${stock.displayName} ${stock.nameEn}',
                    child: ListTile(
                      key: ValueKey('stock-suggestion-${stock.key}'),
                      selected: index == _active,
                      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
                      leading: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                        decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(7)),
                        child: Text(stock.marketTag),
                      ),
                      title: Text('${stock.symbol} · ${stock.displayName}',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(stock.nameEn, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => _pick(stock),
                    ),
                  );
                },
              ),
      ),
    ]),
  );

  @override
  void dispose() {
    _debounce?.cancel();
    _blur?.cancel();
    _text.removeListener(_queryChanged);
    if (widget.controller == null) _text.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }
}
