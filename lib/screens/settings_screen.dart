import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../models/app_settings.dart';
import '../models/hybrid_protocol.dart';
import '../models/stock_candidate.dart';
import '../services/backend_connection_service.dart';

/// User preferences are edited together and persisted by [AppController].
/// Notification permission is requested only after explicitly enabling the
/// reminders and pressing save.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.connectionService,
  });

  final AppController controller;

  /// Optional caller-owned service for tests or custom HTTP transports.
  final BackendConnectionService? connectionService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiUrl;
  late final TextEditingController _twAdr;
  late final TextEditingController _usAdr;
  late final TextEditingController _twEquity;
  late final TextEditingController _usEquity;
  late bool _useMockData;
  late String _dataProvider;
  late bool _autoRefreshEnabled;
  late bool _darkMode;
  late bool _remindersEnabled;
  late RiskMode _twRiskMode, _usRiskMode;
  bool _saving = false;
  bool _testingApi = false;
  int _apiRevision = 0;
  BackendCapabilities? _capabilities;
  String? _connectionError;
  late final BackendConnectionService _connectionService;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    _apiUrl = TextEditingController(text: settings.apiBaseUrl);
    _apiUrl.addListener(_invalidateConnection);
    _connectionService = widget.connectionService ?? BackendConnectionService();
    _twAdr = TextEditingController(text: _number(settings.twAdrThreshold));
    _usAdr = TextEditingController(text: _number(settings.usAdrThreshold));
    _twEquity = TextEditingController(text: _number(settings.twEquity));
    _usEquity = TextEditingController(text: _number(settings.usEquity));
    _useMockData = settings.useMockData;
    _dataProvider = settings.dataProvider;
    _autoRefreshEnabled = settings.autoRefreshEnabled;
    _darkMode = settings.darkMode;
    _remindersEnabled = settings.remindersEnabled;
    _twRiskMode = settings.twRiskMode;
    _usRiskMode = settings.usRiskMode;
  }

  String _number(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  String _capitalHelper(TextEditingController controller, StockMarket market) {
    final value = double.tryParse(controller.text.trim());
    final defaultAmount = market == StockMarket.tw ? '1,000,000' : '50,000';
    final budget =
        value != null && value.isFinite && value > 0
            ? '${market.currencySymbol}${_money(value * 0.005)} ${market.currency}'
            : '請輸入有效資金';
    return '預設 ${market.currencySymbol}$defaultAmount ${market.currency}；'
        '正常0.5%情境預算：$budget；回撤時減半，仍須核對可用現金及費用。';
  }

  Widget _riskModeField(
    StockMarket market,
  ) => DropdownButtonFormField<RiskMode>(
    key: ValueKey('risk-mode-${market.name}'),
    value: market == StockMarket.tw ? _twRiskMode : _usRiskMode,
    isExpanded: true,
    decoration: InputDecoration(labelText: '${market.currency} 帳戶風險狀態（人工核對）'),
    items:
        RiskMode.values
            .map(
              (mode) => DropdownMenuItem(value: mode, child: Text(mode.label)),
            )
            .toList(),
    onChanged:
        _saving
            ? null
            : (mode) {
              if (mode != null)
                setState(() {
                  if (market == StockMarket.tw) {
                    _twRiskMode = mode;
                  } else {
                    _usRiskMode = mode;
                  }
                });
            },
  );

  String _money(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final whole = parts.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return '$whole.${parts.last}';
  }

  @override
  void dispose() {
    _apiUrl.removeListener(_invalidateConnection);
    if (widget.connectionService == null) _connectionService.close();
    _apiUrl.dispose();
    _twAdr.dispose();
    _usAdr.dispose();
    _twEquity.dispose();
    _usEquity.dispose();
    super.dispose();
  }

  String? _validatePositive(String? text, {double? maximum}) {
    final value = double.tryParse((text ?? '').trim());
    if (value == null || !value.isFinite || value <= 0) {
      return '請輸入大於 0 的有效數字';
    }
    if (maximum != null && value > maximum) {
      return '數值需小於或等於 ${_number(maximum)}';
    }
    return null;
  }

  String? _validateApiUrl(String? text) {
    final value = (text ?? '').trim();
    // Direct Yahoo mode works on Android without a backend URL. Validate the
    // optional relay only when it is the selected production data provider.
    if (_useMockData || _dataProvider != 'backend') return null;
    try {
      BackendConnectionService.parseBaseUri(value);
    } on BackendConnectionException catch (error) {
      return error.message;
    }
    return null;
  }

  void _invalidateConnection() {
    _apiRevision++;
    if (!mounted) return;
    setState(() {
      _capabilities = null;
      _connectionError = null;
    });
  }

  Future<void> _testApiConnection() async {
    if (_testingApi || _saving || _useMockData) return;
    final revision = _apiRevision;
    final url = _apiUrl.text.trim();
    setState(() {
      _testingApi = true;
      _capabilities = null;
      _connectionError = null;
    });
    try {
      final result = await _connectionService.testConnection(url);
      if (!mounted || _apiRevision != revision) return;
      setState(() => _capabilities = result);
    } catch (error) {
      if (!mounted || _apiRevision != revision) return;
      setState(() => _connectionError = '$error');
    } finally {
      if (mounted) setState(() => _testingApi = false);
    }
  }

  Widget _backendSetupPanel() {
    final capabilities = _capabilities;
    return Container(
      key: const ValueKey('settings-backend-setup'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '尚未部署 Python API？',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          // Keep the explicit connection action above the longer deployment
          // instructions so it is easy to reach on a compact phone display.
          OutlinedButton.icon(
            key: const ValueKey('settings-test-api'),
            onPressed:
                _testingApi || _saving || _useMockData
                    ? null
                    : _testApiConnection,
            icon:
                _testingApi
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.wifi_tethering),
            label: Text(_testingApi ? '正在測試 API…' : '測試 API 連線'),
          ),
          const SizedBox(height: 8),
          if (_connectionError != null)
            Text(
              _connectionError!,
              key: const ValueKey('settings-api-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else if (capabilities != null)
            Text(
              'API 可連線：${capabilities.scopeLabel}；'
              '每頁 ${capabilities.pageSize} 檔，輪掃頁面設定 '
              '${capabilities.pageIntervalSeconds.toStringAsFixed(0)} 秒'
              '（下拉可提早更新）。\n'
              '僅確認 API 契約相容，尚未驗證行情供應商或真實報價；'
              '請儲存後回總覽檢查資料時間與掃描狀態。',
              key: const ValueKey('settings-api-success'),
            )
          else
            const Text(
              '尚未測試 API。儲存設定不代表已取得真實行情。',
              key: ValueKey('settings-api-unchecked'),
            ),
          const SizedBox(height: 12),
          const Text(
            '1. 將完整專案更新到 GitHub，依 CLOUD_API_GUIDE.md 部署 Render 服務。\n'
            '2. 在 Render 建立 Blueprint，等待部署完成，複製平台實際提供的 HTTPS 網址。\n'
            '3. 填入上方基底網址，測試 API 連線，再儲存設定並回總覽查看掃描進度。',
          ),
          const SizedBox(height: 8),
          const SelectableText('https://dashboard.render.com/'),
          const SizedBox(height: 8),
          const Text(
            '沒有部署就沒有可填的雲端網址；不會自動建立服務。'
            '免費服務可能休眠，先在瀏覽器開啟網址加 /health 等待喚醒。\n'
            '全股票池以分頁輪掃；App 在前台時才持續請求下一頁，'
            '手機退出後不保證掃完全部股票。推薦清單只呈現最近一頁，並非全市場累積排名。',
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final AppSettings previous = widget.controller.settings;
    final next = previous.copyWith(
      useMockData: _useMockData,
      dataProvider: _dataProvider,
      autoRefreshEnabled: _autoRefreshEnabled,
      darkMode: _darkMode,
      apiBaseUrl: _apiUrl.text.trim(),
      twAdrThreshold: double.parse(_twAdr.text.trim()),
      usAdrThreshold: double.parse(_usAdr.text.trim()),
      twEquity: double.parse(_twEquity.text.trim()),
      usEquity: double.parse(_usEquity.text.trim()),
      remindersEnabled: _remindersEnabled,
      twRiskMode: _twRiskMode,
      usRiskMode: _usRiskMode,
    );
    try {
      await widget.controller.updateSettings(next);
      if (!mounted) return;
      final persisted = widget.controller.settings;
      // If Android denied notification permission, the controller persists
      // false and the screen reflects that instead of displaying a fake switch.
      setState(() => _remindersEnabled = persisted.remindersEnabled);
      final error = widget.controller.error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error ??
                (widget.controller.waitingForBackendScan
                    ? '設定已儲存，背景掃描已啟動；可回總覽查看進度。'
                    : '設定已儲存，行情讀取已結束'),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('儲存設定失敗：$error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _numericField({
    required TextEditingController controller,
    required String label,
    String? suffix,
    String? prefix,
    String? helper,
    double? maximum,
    ValueChanged<String>? onChanged,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_saving,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        suffixText: suffix,
        helperText: helper,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
      validator: (text) => _validatePositive(text, maximum: maximum),
    );
  }

  Widget _section({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  /// Starting is an immediate, explicit action rather than a persisted
  /// preference. In particular, editing an unsaved data-source switch must
  /// not start a service with a different source than the one on screen.
  Widget _backgroundScanSection() {
    final controller = widget.controller;
    final active = controller.backgroundScanActive;
    final paused = controller.backgroundScanPaused;
    final busy = controller.backgroundScanBusy;
    final supported = controller.backgroundScanSupported;
    final saved = controller.settings;
    final direct = !saved.useMockData && saved.dataProvider == 'direct';
    final sourceUnsaved =
        _useMockData != saved.useMockData ||
        _dataProvider != saved.dataProvider;
    final canStart = supported && direct && !sourceUnsaved && !_saving && !busy;
    final state =
        busy
            ? '正在處理背景服務…'
            : active
            ? (paused ? '已暫停背景更新' : '背景持續更新中')
            : '背景服務未啟動';
    final market = controller.market;
    final progress = controller.marketScanProgress;
    return _section(
      title: '背景持續更新（Android）',
      icon: Icons.sync,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            state,
            key: const ValueKey('settings-background-state'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '目前市場：${market.label}；行情來源：'
          '${saved.useMockData
              ? '離線示範'
              : saved.dataProvider == 'direct'
              ? 'Yahoo Finance 直連'
              : 'Python API'}。',
          key: const ValueKey('settings-background-market'),
        ),
        const SizedBox(height: 8),
        const Text(
          '手動啟動後以常駐通知維持更新，可切換其他 App 或鎖螢幕。'
          '台股與美股都依目前可取得的普通股完整名單分頁續掃，保留進度；名單缺漏會另行提示。'
          '掃描跟隨總覽目前選取市場；切換行情來源或 ADR 門檻會先停止服務，需重新啟動。',
        ),
        if (active && progress != null && progress.market == market) ...[
          const SizedBox(height: 8),
          Text(
            progress.label,
            key: const ValueKey('settings-background-progress'),
          ),
        ],
        if (!supported) ...[
          const SizedBox(height: 8),
          const Text(
            '此裝置不支援 Android 背景服務；Web、iOS 與桌面版仍僅在前台更新。',
            key: ValueKey('settings-background-unavailable'),
          ),
        ] else if (!direct || sourceUnsaved) ...[
          const SizedBox(height: 8),
          const Text(
            '請先關閉離線示範、選擇手機直接連線並儲存設定，再啟動此服務。Python API 仍使用原有前台讀取方式。',
            key: ValueKey('settings-background-requires-direct'),
          ),
        ],
        if (controller.backgroundScanMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            controller.backgroundScanMessage!,
            key: const ValueKey('settings-background-message'),
          ),
        ],
        if (controller.backgroundScanError != null) ...[
          const SizedBox(height: 8),
          Text(
            controller.backgroundScanError!,
            key: const ValueKey('settings-background-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (!active)
              FilledButton.icon(
                key: const ValueKey('settings-background-start'),
                onPressed: canStart ? controller.startBackgroundScan : null,
                icon:
                    busy
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.play_arrow),
                label: const Text('啟動背景更新'),
              )
            else ...[
              OutlinedButton.icon(
                key: const ValueKey('settings-background-pause-resume'),
                onPressed:
                    busy || _saving
                        ? null
                        : paused
                        ? controller.resumeBackgroundScan
                        : controller.pauseBackgroundScan,
                icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                label: Text(paused ? '繼續更新' : '暫停更新'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('settings-background-stop'),
                onPressed: busy ? null : controller.stopBackgroundScan,
                icon: const Icon(Icons.stop),
                label: const Text('停止服務'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '第一次啟動請允許通知。服務可從此頁或常駐通知暫停／停止；'
          '從最近使用清單移除 App、強制停止、系統省電或重新開機仍可能中斷，不會自動重新啟動。'
          '背景更新會使用網路與電量；未啟動本服務時，原有前台更新行為不變。',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder:
          (context, _) => Scaffold(
            appBar: AppBar(title: const Text('設定與評估提醒')),
            body: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _section(
                            title:
                                'App ${HybridProtocol.appVersion} · Hybrid v${HybridProtocol.version}',
                            icon: Icons.cloud_outlined,
                            children: [
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('離線示範資料'),
                                subtitle: const Text(
                                  '開啟後使用內建假資料，可離線預覽所有頁面；不代表即時行情。',
                                ),
                                value: _useMockData,
                                onChanged:
                                    _saving
                                        ? null
                                        : (value) => setState(
                                          () => _useMockData = value,
                                        ),
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                key: const ValueKey('settings-data-provider'),
                                value: _dataProvider,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '正式行情來源',
                                  border: OutlineInputBorder(),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'direct',
                                    child: Text(
                                      'Yahoo Finance · 手機直接連線',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'backend',
                                    child: Text(
                                      'Python API · 雲端／自訂中繼',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                                onChanged:
                                    _saving || _useMockData
                                        ? null
                                        : (value) {
                                          if (value != null)
                                            setState(
                                              () => _dataProvider = value,
                                            );
                                        },
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _useMockData
                                    ? '示範模式需明確開啟；連線失敗不會自動切換到假資料。'
                                    : _dataProvider == 'direct'
                                    ? 'Android 直接取得 Yahoo 日 K 與最新可用報價，並在裝置上計算 ADR、EMA 與動能。行情可能延遲。'
                                    : '由 Python API 背景分批掃描，手機快速讀取進度與快照；沒有符合股票時正常顯示 0 檔。',
                              ),
                              if (_dataProvider == 'direct' &&
                                  !_useMockData) ...[
                                const SizedBox(height: 8),
                                const Text(
                                  '台股直連依上市／上櫃普通股名單，美股依 NYSE／Nasdaq／NYSE American 普通股名單分頁續掃，不需部署 Python API；'
                                  '前台每次只處理一頁，保留本輪累積候選與各股原行情時間。'
                                  '名單數不等於已評估數；來源不完整時保留覆蓋不足警告，RS 為原掃描頁內排名。'
                                  '雲端部署方式見專案 CLOUD_API_GUIDE.md。',
                                  key: ValueKey('settings-direct-scope'),
                                ),
                              ],
                              if (_dataProvider == 'backend') ...[
                                const SizedBox(height: 12),
                                TextFormField(
                                  key: const ValueKey('settings-backend-url'),
                                  controller: _apiUrl,
                                  enabled: !_saving,
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  decoration: InputDecoration(
                                    labelText: 'Python API 基底網址',
                                    hintText: 'https://你的服務名稱.onrender.com',
                                    helperText:
                                        _useMockData
                                            ? '示範模式不連線；仍可預先儲存 API 網址。'
                                            : '5G 請填已部署的公開 HTTPS 基底網址，不加 /v1/candidates。'
                                                '免費雲端冷啟動若逾時，先用手機瀏覽器開啟網址加 /health，回應後再重試。',
                                    helperMaxLines: 5,
                                    border: const OutlineInputBorder(),
                                  ),
                                  validator: _validateApiUrl,
                                ),
                                const SizedBox(height: 12),
                                _backendSetupPanel(),
                              ],
                              const SizedBox(height: 8),
                              SwitchListTile.adaptive(
                                key: const ValueKey('settings-auto-refresh'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text('前台自動更新'),
                                subtitle: const Text(
                                  'App 前台每 60 秒更新目前市場：台股、美股直連均續掃下一頁；'
                                  '持股診斷同步更新。'
                                  '未啟動下方 Android 背景服務時，離開 App 會暫停；下拉可立即續掃或更新。'
                                  '背景服務需另外手動啟動，不受此開關控制。',
                                ),
                                value: _autoRefreshEnabled,
                                onChanged:
                                    _saving
                                        ? null
                                        : (value) => setState(
                                          () => _autoRefreshEnabled = value,
                                        ),
                              ),
                              const SizedBox(height: 8),
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('深色模式'),
                                subtitle: const Text('儲存後套用整個 App 的色彩主題'),
                                value: _darkMode,
                                onChanged:
                                    _saving
                                        ? null
                                        : (value) =>
                                            setState(() => _darkMode = value),
                              ),
                            ],
                          ),
                          _backgroundScanSection(),
                          _section(
                            title: '波幅門檻與分市場帳戶資金',
                            icon: Icons.tune,
                            children: [
                              const Text(
                                '以排除入出金影響的帳戶淨值核對回撤；低於歷史高水位採0.25%。連續5筆停損暫停新倉。未知時不計算建議股數。',
                              ),
                              const SizedBox(height: 12),
                              _riskModeField(StockMarket.tw),
                              const SizedBox(height: 12),
                              _riskModeField(StockMarket.us),
                              const SizedBox(height: 16),
                              Text(
                                'ADR = 20 日平均 (最高 − 最低) / 最低 × 100%。'
                                '美股 USD 與台股 TWD 帳戶獨立保存；每筆交易風險'
                                '正常0.5%、確認回撤時0.25%，暫停時不開新倉。不進行匯率換算。',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 16),
                              _numericField(
                                controller: _twAdr,
                                label: '台股 ADR 門檻',
                                suffix: '%',
                                helper: '觀察清單門檻；Hybrid台股仍嚴格要求ADR >3.5%。',
                                maximum: 20,
                              ),
                              const SizedBox(height: 16),
                              _numericField(
                                controller: _usAdr,
                                label: '美股 ADR 門檻',
                                suffix: '%',
                                helper: '觀察清單門檻；Hybrid美股仍要求ADR ≥5%。',
                                maximum: 20,
                              ),
                              const SizedBox(height: 16),
                              _numericField(
                                controller: _twEquity,
                                label: '台股帳戶總資金（Capital）',
                                prefix: 'NT\$ ',
                                suffix: 'TWD',
                                helper: _capitalHelper(
                                  _twEquity,
                                  StockMarket.tw,
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                              const SizedBox(height: 16),
                              _numericField(
                                controller: _usEquity,
                                label: '美股帳戶總資金（Capital）',
                                prefix: 'US\$ ',
                                suffix: 'USD',
                                helper: _capitalHelper(
                                  _usEquity,
                                  StockMarket.us,
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                          _section(
                            title: '每日評估提醒',
                            icon: Icons.notifications_active_outlined,
                            children: [
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('啟用 Android 本機通知'),
                                subtitle: const Text('儲存時請允許通知權限'),
                                value: _remindersEnabled,
                                onChanged:
                                    _saving
                                        ? null
                                        : (value) => setState(
                                          () => _remindersEnabled = value,
                                        ),
                              ),
                              const Divider(),
                              const ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.public),
                                title: Text('台股：08:30 / 14:00'),
                                subtitle: Text('Asia/Taipei · 台北時間'),
                              ),
                              const ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.public),
                                title: Text('美股：08:45 / 16:30'),
                                subtitle: Text(
                                  'America/New_York · 美東時間，自動套用夏令時間',
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '週一至週五提醒，休市請以交易日曆為準。'
                                '此排程僅提醒開啟 App，不會自行啟動行情掃描；'
                                '背景持續更新需另行手動啟動上方 Android 服務。'
                                '省電限制可能讓通知延後。',
                              ),
                            ],
                          ),
                          if (widget.controller.error != null) ...[
                            Card(
                              color:
                                  Theme.of(context).colorScheme.errorContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  widget.controller.error!,
                                  style: TextStyle(
                                    color:
                                        Theme.of(
                                          context,
                                        ).colorScheme.onErrorContainer,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon:
                                _saving
                                    ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Icon(Icons.save_outlined),
                            label: Text(_saving ? '儲存與更新中…' : '儲存設定並更新'),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }
}
