import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../models/app_settings.dart';
import '../models/stock_candidate.dart';

/// User preferences are edited together and persisted by [AppController].
/// Notification permission is requested only after explicitly enabling the
/// reminders and pressing save.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

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
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    _apiUrl = TextEditingController(text: settings.apiBaseUrl);
    _twAdr = TextEditingController(text: _number(settings.twAdrThreshold));
    _usAdr = TextEditingController(text: _number(settings.usAdrThreshold));
    _twEquity = TextEditingController(text: _number(settings.twEquity));
    _usEquity = TextEditingController(text: _number(settings.usEquity));
    _useMockData = settings.useMockData;
    _dataProvider = settings.dataProvider;
    _autoRefreshEnabled = settings.autoRefreshEnabled;
    _darkMode = settings.darkMode;
    _remindersEnabled = settings.remindersEnabled;
  }

  String _number(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  String _capitalHelper(TextEditingController controller, StockMarket market) {
    final value = double.tryParse(controller.text.trim());
    final defaultAmount = market == StockMarket.tw ? '1,000,000' : '50,000';
    final budget = value != null && value.isFinite && value > 0
        ? '${market.currencySymbol}${_money(value * 0.005)} ${market.currency}'
        : '請輸入有效資金';
    return '預設 ${market.currencySymbol}$defaultAmount ${market.currency}；'
        '此帳戶每筆 0.5% 風險預算：$budget。';
  }

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
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return '請輸入完整的 http:// 或 https:// API 網址';
    }
    return null;
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
        SnackBar(content: Text(error ?? '設定已儲存，候選清單已更新')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('儲存設定失敗：$error')),
      );
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
            Row(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
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
                        title: '資料來源與外觀',
                        icon: Icons.cloud_outlined,
                        children: [
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('離線示範資料'),
                            subtitle: const Text(
                              '開啟後使用內建假資料，可離線預覽所有頁面；不代表即時行情。',
                            ),
                            value: _useMockData,
                            onChanged: _saving
                                ? null
                                : (value) =>
                                    setState(() => _useMockData = value),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: const ValueKey('settings-data-provider'),
                            value: _dataProvider,
                            decoration: const InputDecoration(
                              labelText: '正式行情來源',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'direct', child: Text('Yahoo Finance · 手機直接連線')),
                              DropdownMenuItem(value: 'backend', child: Text('Python API · 自訂中繼')),
                            ],
                            onChanged: _saving || _useMockData ? null : (value) {
                              if (value != null) setState(() => _dataProvider = value);
                            },
                          ),
                          const SizedBox(height: 8),
                          Text(_useMockData
                              ? '示範模式需明確開啟；連線失敗不會自動切換到假資料。'
                              : _dataProvider == 'direct'
                                  ? 'Android 直接取得 Yahoo 日 K 與最新可用報價，並在裝置上計算 ADR、EMA 與動能。行情可能延遲。'
                                  : '經您的 Python API 取得行情與掃描結果。'),
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
                              hintText: 'http://192.168.1.100:8000',
                              helperText: _useMockData
                                  ? '示範模式不連線；仍可預先儲存 API 網址。'
                                  : '實機請填伺服器的 HTTPS 網址或同網域電腦 IP。',
                              helperMaxLines: 3,
                              border: const OutlineInputBorder(),
                            ),
                            validator: _validateApiUrl,
                          ),
                          ],
                          const SizedBox(height: 8),
                          SwitchListTile.adaptive(
                            key: const ValueKey('settings-auto-refresh'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('前台自動更新'),
                            subtitle: const Text(
                              'App 開啟時每 60 秒更新最新可用報價與持股診斷；背景暫停。下拉更新會強制重新請求。',
                            ),
                            value: _autoRefreshEnabled,
                            onChanged: _saving ? null : (value) =>
                                setState(() => _autoRefreshEnabled = value),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('深色模式'),
                            subtitle: const Text('儲存後套用整個 App 的色彩主題'),
                            value: _darkMode,
                            onChanged: _saving
                                ? null
                                : (value) => setState(() => _darkMode = value),
                          ),
                        ],
                      ),
                      _section(
                        title: '波幅門檻與分市場帳戶資金',
                        icon: Icons.tune,
                        children: [
                          Text(
                            'ADR = 20 日平均 (最高 − 最低) / 最低 × 100%。'
                            '美股 USD 與台股 TWD 帳戶獨立保存；每筆交易風險'
                            '固定為該市場帳戶總資金的 0.5%，不進行匯率換算。',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 16),
                          _numericField(
                            controller: _twAdr,
                            label: '台股 ADR 門檻',
                            suffix: '%',
                            helper: '預設 3.5%；可依漲跌幅限制調整。',
                            maximum: 20,
                          ),
                          const SizedBox(height: 16),
                          _numericField(
                            controller: _usAdr,
                            label: '美股 ADR 門檻',
                            suffix: '%',
                            helper: '預設 5.0%；設定範圍大於 0 至 20%。',
                            maximum: 20,
                          ),
                          const SizedBox(height: 16),
                          _numericField(
                            controller: _twEquity,
                            label: '台股帳戶總資金（Capital）',
                            prefix: 'NT\$ ',
                            suffix: 'TWD',
                            helper: _capitalHelper(_twEquity, StockMarket.tw),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 16),
                          _numericField(
                            controller: _usEquity,
                            label: '美股帳戶總資金（Capital）',
                            prefix: 'US\$ ',
                            suffix: 'USD',
                            helper: _capitalHelper(_usEquity, StockMarket.us),
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
                            onChanged: _saving
                                ? null
                                : (value) =>
                                    setState(() => _remindersEnabled = value),
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
                            '通知提醒您開啟 App 更新；手機不會在背景執行金融掃描。'
                            '省電限制可能讓通知延後。',
                          ),
                        ],
                      ),
                      if (widget.controller.error != null) ...[
                        Card(
                          color: Theme.of(context)
                              .colorScheme
                              .errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              widget.controller.error!,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
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
