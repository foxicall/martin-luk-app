import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import 'stock_candidate.dart';

/// One unadjusted provider OHLCV candle. The timestamp is its start, not the
/// time our phone downloaded it. Prices from a candle must use one price basis.
class PriceBar {
  PriceBar({
    required DateTime timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    this.interval = const Duration(days: 1),
  }) : timestamp = timestamp.toUtc() {
    if ([
          open,
          high,
          low,
          close,
        ].any((value) => !value.isFinite || value <= 0) ||
        !volume.isFinite ||
        volume < 0 ||
        high < low ||
        high < open ||
        high < close ||
        low > open ||
        low > close ||
        interval <= Duration.zero) {
      throw const FormatException('OHLCV 價格、成交量或 K 棒週期無效。');
    }
  }

  final DateTime timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final Duration interval;
  DateTime get closeTimestamp => timestamp.add(interval);
}

/// Actual provider data plus delivery provenance. A successful HTTP request is
/// not evidence that the exchange quote itself is current or a candle closed.
class MarketChart {
  MarketChart({
    required this.symbol,
    required this.market,
    required this.currency,
    required this.exchangeTimezoneName,
    required this.gmtoffset,
    required List<PriceBar> bars,
    required this.latestPrice,
    required DateTime quoteTimestamp,
    required DateTime fetchedAt,
    required this.interval,
    DateTime? regularSessionStart,
    DateTime? regularSessionEnd,
    this.isCached = false,
    this.isStale = false,
    this.cacheWarning,
    this.marketCap,
    this.exchangeName,
    this.source = 'Yahoo Finance 公開行情（可能延遲，不保證即時）',
  }) : bars = List.unmodifiable(bars),
       quoteTimestamp = quoteTimestamp.toUtc(),
       fetchedAt = fetchedAt.toUtc(),
       regularSessionStart = regularSessionStart?.toUtc(),
       regularSessionEnd = regularSessionEnd?.toUtc() {
    if (symbol.trim().isEmpty ||
        currency != market.currency ||
        exchangeTimezoneName.isEmpty ||
        !latestPrice.isFinite ||
        latestPrice <= 0 ||
        bars.isEmpty ||
        !['1d', '1m', '5m'].contains(interval) ||
        (this.regularSessionStart == null) !=
            (this.regularSessionEnd == null) ||
        (this.regularSessionStart != null &&
            !this.regularSessionEnd!.isAfter(this.regularSessionStart!))) {
      throw const FormatException('股票、幣別、交易時段或行情資料無效。');
    }
    _location(exchangeTimezoneName);
    for (var index = 1; index < this.bars.length; index++) {
      if (!this.bars[index].timestamp.isAfter(this.bars[index - 1].timestamp)) {
        throw const FormatException('K 棒時間必須嚴格遞增，不得重複。');
      }
    }
  }

  final String symbol;
  final StockMarket market;
  final String currency;
  final String exchangeTimezoneName;
  final int gmtoffset;
  final List<PriceBar> bars;
  final double latestPrice;
  final DateTime quoteTimestamp;
  final DateTime fetchedAt;
  final String interval;
  final DateTime? regularSessionStart;
  final DateTime? regularSessionEnd;
  final bool isCached;
  final bool isStale;
  final String? cacheWarning;
  final String source;
  final double? marketCap;
  final String? exchangeName;

  /// A date-only value in the exchange's IANA timezone, including US DST.
  DateTime localSessionDate(DateTime timestamp) {
    final local = tz.TZDateTime.from(
      timestamp.toUtc(),
      _location(exchangeTimezoneName),
    );
    return DateTime.utc(local.year, local.month, local.day);
  }

  /// A current daily candle remains provisional until 15 minutes after the
  /// provider's regular-session end. Older days are finalized. If the provider
  /// omitted session metadata, today's daily bar is conservatively excluded.
  List<PriceBar> get completedDailyBars {
    if (interval != '1d') return const [];
    final today = localSessionDate(fetchedAt);
    final sessionStart = regularSessionStart;
    final sessionEnd = regularSessionEnd;
    final sessionDate =
        sessionStart == null ? null : localSessionDate(sessionStart);
    return List.unmodifiable(
      bars.where((bar) {
        final date = localSessionDate(bar.timestamp);
        if (sessionDate != null && date == sessionDate) {
          return sessionEnd != null &&
              !fetchedAt.isBefore(
                sessionEnd.add(const Duration(minutes: 15)),
              ) &&
              !quoteTimestamp.isBefore(
                sessionEnd.subtract(const Duration(minutes: 1)),
              );
        }
        if (date.isBefore(today)) return true;
        if (date != today || sessionDate == null) return false;
        // Yahoo can roll currentTradingPeriod to tomorrow before changing the
        // daily history. Today's completed candle still needs a consistent close
        // test; simply comparing its date with fetchedAt would discard it.
        // The normal exchange close is conservative on early-close sessions.
        final close = dailyCloseTimestamp(bar);
        return !fetchedAt.isBefore(close.add(const Duration(minutes: 15))) &&
            !quoteTimestamp.isBefore(
              close.subtract(const Duration(minutes: 1)),
            );
      }),
    );
  }

  /// Extended-hours bars never form the regular opening range.
  List<PriceBar> get regularSessionBars {
    final start = regularSessionStart;
    final end = regularSessionEnd;
    if (interval == '1d' || start == null || end == null) return const [];
    return List.unmodifiable(
      bars.where(
        (bar) => !bar.timestamp.isBefore(start) && bar.timestamp.isBefore(end),
      ),
    );
  }

  bool get quoteIsInRegularSession =>
      regularSessionStart != null &&
      !quoteTimestamp.isBefore(regularSessionStart!) &&
      quoteTimestamp.isBefore(regularSessionEnd!);

  /// A daily bar starts at the open; adding 24 hours would produce the wrong
  /// close date and US daylight-saving offset. Use the exchange's wall clock.
  DateTime dailyCloseTimestamp(PriceBar bar) {
    final date = localSessionDate(bar.timestamp);
    if (regularSessionStart != null &&
        regularSessionEnd != null &&
        date == localSessionDate(regularSessionStart!)) {
      return regularSessionEnd!;
    }
    return tz.TZDateTime(
      _location(exchangeTimezoneName),
      date.year,
      date.month,
      date.day,
      market == StockMarket.tw ? 13 : 16,
      market == StockMarket.tw ? 30 : 0,
    ).toUtc();
  }

  bool isQuoteFresh(
    DateTime now, {
    Duration maxAge = const Duration(minutes: 15),
  }) {
    final age = now.toUtc().difference(quoteTimestamp);
    return !age.isNegative && age <= maxAge && !isStale && cacheWarning == null;
  }
}

class ChartBundle {
  const ChartBundle({required this.daily, this.intraday, this.intradayError});
  final MarketChart daily;
  final MarketChart? intraday;
  final String? intradayError;
}

bool _zonesInitialized = false;
tz.Location _location(String name) {
  if (!_zonesInitialized) {
    timezone_data.initializeTimeZones();
    _zonesInitialized = true;
  }
  try {
    return tz.getLocation(name);
  } catch (_) {
    throw FormatException('行情供應商提供了未知交易所時區：$name');
  }
}
