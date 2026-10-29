import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'screens/dashboard_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/portfolio_screen.dart';
import 'services/stock_industry_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IndustryBootstrap());
}

class IndustryBootstrap extends StatefulWidget {
  const IndustryBootstrap({super.key});

  @override
  State<IndustryBootstrap> createState() => _IndustryBootstrapState();
}

class _IndustryBootstrapState extends State<IndustryBootstrap> {
  late Future<void> _loading = StockIndustryService.instance.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _loading,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done && !snapshot.hasError) {
        return const MartinLukApp();
      }
      return MaterialApp(home: Scaffold(body: Center(child: snapshot.hasError
        ? Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('產業分類載入失敗，請重試。'),
            TextButton(onPressed: () => setState(() {
              _loading = StockIndustryService.instance.load();
            }), child: const Text('重新載入')),
          ])
        : const Text('載入產業分類…'))));
    },
  );
}

class MartinLukApp extends StatefulWidget {
  const MartinLukApp({super.key, this.controller});
  final AppController? controller;

  @override
  State<MartinLukApp> createState() => _MartinLukAppState();
}

class _MartinLukAppState extends State<MartinLukApp> with WidgetsBindingObserver {
  late final AppController _controller;
  int _selectedPage = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller ?? AppController();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _controller.setForeground(lifecycle == null || lifecycle == AppLifecycleState.resumed);
    if (widget.controller == null) _controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive, hidden and paused all stop the timer. This is foreground
    // monitoring rather than Android background work or unattended trading.
    _controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.setForeground(false);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0AA895), brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'MartinPreviewSans',
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF0B1320) : const Color(0xFFF4F7FB),
      appBarTheme: const AppBarTheme(centerTitle: false),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(), filled: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => MaterialApp(
          title: 'Martin Luk 動能策略',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: _controller.settings.darkMode ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(
            body: switch (_selectedPage) {
              0 => DashboardScreen(controller: _controller),
              1 => PortfolioScreen(controller: _controller),
              _ => SettingsScreen(controller: _controller),
            },
            bottomNavigationBar: NavigationBar(
              selectedIndex: _selectedPage,
              onDestinationSelected: (value) => setState(() => _selectedPage = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.auto_graph_outlined),
                  selectedIcon: Icon(Icons.auto_graph), label: '動能總覽',
                ),
                NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  selectedIcon: Icon(Icons.account_balance_wallet), label: '我的持股',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune), label: '設定與提醒',
                ),
              ],
            ),
          ),
        ),
      );
}
