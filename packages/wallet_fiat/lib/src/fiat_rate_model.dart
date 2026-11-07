import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:wallet_domain/wallet_domain.dart' show WalletManager;
import 'package:wallet_infra/wallet_infra.dart';

import 'fiat_currency.dart';

/// Ceiling on a Kraken ticker reply, which is a handful of numbers.
///
/// The bound matters most here: this is the only reader that runs unattended on
/// a timer forever. Everywhere else a user is waiting and would notice a stall.
const int maxFiatResponseBytes = 256 * 1024;

enum FiatApiMode { torOnly, clearnet, disabled }

/// The price in a Kraken `Ticker` reply for [pair]: the last trade (`c[0]`),
/// which is the price Kraken itself shows.
///
/// Not `o`, the day's opening price: that is fixed at 00:00 UTC, so late in a
/// day with a large move it is off by the whole move.
///
/// Throws when Kraken reports an error (it does so as HTTP 200 with a populated
/// `error` array and an empty `result`) or the reply has no usable price.
@visibleForTesting
double krakenLastTradePrice(Object? body, String pair) {
  final reply = body is Map ? body : null;
  final errors = reply?['error'];
  if (errors is List && errors.isNotEmpty) {
    throw Exception('Kraken error: ${errors.join(', ')}');
  }
  final result = reply?['result'];
  final ticker = result is Map ? result[pair] : null;
  final lastTrade = ticker is Map ? ticker['c'] : null;
  final price = lastTrade is List && lastTrade.isNotEmpty ? lastTrade.first : null;
  final value = price is String ? double.tryParse(price) : null;
  if (value == null || !value.isFinite || value <= 0) {
    throw Exception('Could not find rate for $pair');
  }
  return value;
}

/// The app's Tor SOCKS proxy, or null when unavailable. The apps run their own
/// `TorService`, the one everything else connects through, so the fiat model
/// asks the app for the proxy rather than owning Tor.
typedef TorProxyProvider = Future<({InternetAddress host, int port})?> Function();

/// Injectable seam for [FiatRateModel], installed once from the app's bootstrap.
class FiatRates {
  const FiatRates._();

  static TorProxyProvider getTorProxy = () async => null;

  /// Store screenshots only: these rates, in the user's currency and keyed by
  /// coin (`XMR`), stand in for Kraken's, so the pictures show the same figures
  /// on every run. Null in the apps, which always fetch.
  static Map<String, double>? fixedRates;

  static void install({required TorProxyProvider getTorProxy}) {
    FiatRates.getTorProxy = getTorProxy;
  }
}

/// Tracks the latest fiat exchange rate (in [fiatCode]) for every coin the
/// wallet supports. Each coin is fetched independently so a Kraken outage on one
/// pair doesn't blank out the others.
class FiatRateModel with ChangeNotifier implements FiatQuoteSource {
  // coinSymbol -> Kraken base code prefix used to build the pair name. Kraken
  // uses the legacy "X<asset>Z<fiat>" notation for its original assets (XMR
  // `XXMRZ`, BTC `XXBTZ`, ETH `XETHZ`); newer assets like DAI have no prefix
  // (pair is just `DAIUSD`). Shared Kraken knowledge, not app config.
  static const Map<String, String> _krakenBase = {
    'XMR': 'XXMRZ',
    'BTC': 'XXBTZ',
    'ETH': 'XETHZ',
    'DAI': 'DAI',
  };

  static List<String> get supportedCoins => _krakenBase.keys.toList();

  static Future<FiatApiMode> loadFiatApiMode() async {
    final s = await SharedPreferencesService.get<String>(SettingsKeys.fiatApiMode);
    if (s == null) {
      return FiatApiMode.torOnly;
    }
    for (final m in FiatApiMode.values) {
      if (m.name == s) return m;
    }
    return FiatApiMode.torOnly;
  }

  static Future<void> saveFiatApiMode(FiatApiMode mode) async {
    await SharedPreferencesService.set<String>(SettingsKeys.fiatApiMode, mode.name);
  }

  /// Clears every persisted rate, in every currency. Called when the user
  /// changes the fiat currency or API mode, so a rate saved long ago is not
  /// shown if they come back to that currency.
  static Future<void> clearPersistedRates() async {
    for (final coin in _krakenBase.keys) {
      await SharedPreferencesService.remove(_legacyPersistKeyFor(coin));
      for (final currency in FiatCurrency.all) {
        await SharedPreferencesService.remove(_persistKeyFor(coin, currency.code));
      }
    }
  }

  /// Stands in for Kraken in tests: the price for a ticker pair, ahead of the
  /// API mode and the Tor proxy. Null in the apps.
  @visibleForTesting
  static Future<double> Function(String pair)? requestPairForTesting;

  /// Each coin's latest rate with the currency it was fetched in, so a rate is
  /// only ever shown in that currency ([rateFor]). `fetch` numbers the fetch
  /// that got it (0 for one read from disk), so an older fetch that ends last
  /// cannot replace a newer rate.
  final Map<String, ({String fiat, double value, int fetch})?> _rates = {};
  int _fetchCount = 0;
  bool _isLoading = false;
  bool _hasFailed = false;
  bool _isDisabled = false;
  String _fiatCode = 'USD';
  FiatApiMode _fiatApiMode = FiatApiMode.torOnly;
  Timer? _rateFetchTimer;
  WalletManager? _walletManager;
  Set<String> _lastFetchedActiveCoins = {};

  /// How long to wait before each retry of a failed fetch, after which the
  /// 10-minute poll takes over. Without these a fetch that failed once, at
  /// launch or right after a restore, left fiat blank for ten minutes.
  @visibleForTesting
  static List<Duration> retryBackoff = const [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  Timer? _retryTimer;
  int _retryAttempt = 0;

  /// Whether the last fetch failed for any coin, for [retryIfFailed].
  bool _lastFetchFailed = false;

  /// Whether a fiat rate is obtainable for [coinSymbol] (its mainnet base is a
  /// supported Kraken coin). Testnet coins inherit their base's support.
  bool isSupported(String coinSymbol) {
    final wallet = _walletManager?.getWallet(coinSymbol.toUpperCase());
    final base = (wallet?.fiatBaseSymbol ?? coinSymbol).toUpperCase();
    return _krakenBase.containsKey(base);
  }

  /// Latest fiat rate for [coinSymbol] in [fiatCode], or `null` if none has
  /// been fetched in that currency yet (or the most recent fetch failed).
  /// Testnet coins resolve to their mainnet `CryptoWallet.fiatBaseSymbol` rate
  /// (e.g. TBTC → BTC).
  double? rateFor(String coinSymbol, {bool? walletActive}) {
    final symbol = coinSymbol.toUpperCase();
    final wallet = _walletManager?.getWallet(symbol);
    if (walletActive == false) return null;
    if (wallet != null && wallet.connectionAddress.isEmpty) return null;
    return _rateInFiat(_rates[(wallet?.fiatBaseSymbol ?? symbol).toUpperCase()]);
  }

  /// Every coin's rate in [fiatCode]; null where there is none in it.
  Map<String, double?> get rates =>
      Map.unmodifiable(_rates.map((coin, rate) => MapEntry(coin, _rateInFiat(rate))));

  double? _rateInFiat(({String fiat, double value, int fetch})? rate) =>
      rate != null && rate.fiat == _fiatCode ? rate.value : null;
  bool get isLoading => _isLoading;
  bool get hasFailed => _hasFailed;
  bool get isDisabled => _isDisabled;
  String get fiatCode => _fiatCode;

  /// The user's currency, from the shared table: its symbol and minor units.
  FiatCurrency get fiatCurrency => FiatCurrency.of(_fiatCode);

  /// [rateFor] with the currency attached, or null when fiat is disabled or no
  /// rate has arrived. A disabled API keeps its last in-memory rates, so this is
  /// the check to use before offering fiat anywhere a user can act on it.
  @override
  FiatQuote? quoteFor(String coinSymbol) {
    if (_isDisabled) return null;
    final rate = rateFor(coinSymbol);
    if (rate == null || !rate.isFinite || rate <= 0) return null;
    return (currency: fiatCurrency, rate: rate);
  }

  /// One key per coin and currency, so a saved rate always says which
  /// currency it is in.
  static String _persistKeyFor(String coinSymbol, String fiat) =>
      '${SettingsKeys.fiatRate}_${coinSymbol.toLowerCase()}_${fiat.toLowerCase()}';

  /// Where builds before the currency was part of the key saved a rate. Not
  /// read: nothing says which currency it was in, and a fetch that ended after
  /// a currency change could have saved one in the old currency.
  static String _legacyPersistKeyFor(String coinSymbol) =>
      '${SettingsKeys.fiatRate}_${coinSymbol.toLowerCase()}';

  void attachWalletManager(WalletManager manager) {
    if (identical(_walletManager, manager)) return;
    _walletManager?.removeListener(_onWalletManagerChanged);
    _walletManager = manager;
    manager.addListener(_onWalletManagerChanged);
  }

  void _onWalletManagerChanged() {
    final active = _activeKrakenCoins().toSet();
    if (_setEquals(active, _lastFetchedActiveCoins)) return;
    if (_rateFetchTimer != null && !_isDisabled) {
      _loadRate();
    }
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final item in a) {
      if (!b.contains(item)) return false;
    }
    return true;
  }

  Iterable<String> _activeKrakenCoins() {
    final manager = _walletManager;
    if (manager == null) return [];
    return manager.allWallets
        .where((w) => w.connectionAddress.isNotEmpty)
        .map((w) => w.fiatBaseSymbol.toUpperCase())
        .where(_krakenBase.containsKey);
  }

  void _startRateFetchTimer() {
    if (_fiatApiMode == FiatApiMode.disabled) {
      _isDisabled = true;
      _hasFailed = false; // a disabled API is not a failed one
      log(LogLevel.info, 'Fiat API is disabled. Not starting rate fetch timer.');
      notifyListeners();
      return;
    } else {
      _isDisabled = false;
    }

    _rateFetchTimer?.cancel();

    _loadRate();

    _rateFetchTimer = Timer.periodic(Duration(minutes: 10), (_) {
      _loadRate();
    });
  }

  Future<void> _loadPersisted() async {
    _fiatCode = await SharedPreferencesService.get<String>(SettingsKeys.fiatCurrency) ?? 'USD';
    _fiatApiMode = await FiatRateModel.loadFiatApiMode();
    final fiat = _fiatCode;
    for (final coin in _krakenBase.keys) {
      await SharedPreferencesService.remove(_legacyPersistKeyFor(coin));
      final rate = await SharedPreferencesService.get<double>(_persistKeyFor(coin, fiat));
      _rates[coin] = rate == null ? null : (fiat: fiat, value: rate, fetch: 0);
    }
  }

  Future<void> _persist(String coin, String fiat, double rate) async {
    await SharedPreferencesService.set<double>(_persistKeyFor(coin, fiat), rate);
  }

  Future<double> _requestPairRateClearnet(String pair) async {
    final url = 'https://api.kraken.com/0/public/Ticker?pair=$pair';
    log(LogLevel.info, 'Fetching rate from fiat api (clearnet): $url');

    // Bounded like the rest of the request: with no connect timeout a stalled
    // handshake keeps the model loading for as long as the OS lets it.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(Duration(seconds: 20));
      final body = await readBoundedBody(
        response,
        maxBytes: maxFiatResponseBytes,
        timeout: const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw Exception('Status code: ${response.statusCode}');
      }
      return krakenLastTradePrice(jsonDecode(body), pair);
    } finally {
      client.close(force: true);
    }
  }

  Future<double> _requestPairRateTor(String pair) async {
    final url = 'https://api.kraken.com/0/public/Ticker?pair=$pair';
    final proxyInfo = await FiatRates.getTorProxy();

    log(LogLevel.info, 'Fetching rate from fiat api (Tor):');
    log(LogLevel.info, '  url: $url');

    if (proxyInfo == null) {
      throw Exception('Not fetching rate from fiat API because no Tor proxy is available');
    }

    try {
      // The bound lives inside the read, not in a `.timeout()` around it. A
      // wrapper completes the future while the stalled read keeps consuming, so
      // on a ten-minute poller abandoned reads pile up instead of being
      // replaced. makeSocksHttpRequest caps the socket close separately.
      final response = await makeSocksHttpRequest(
        'GET',
        url,
        proxyInfo,
        maxBytes: maxFiatResponseBytes,
        timeout: const Duration(seconds: 20),
      );
      if (response.statusCode == 200) {
        return krakenLastTradePrice(response.jsonBody, pair);
      } else {
        throw Exception('Status code: ${response.statusCode}');
      }
    } catch (error) {
      log(LogLevel.error, 'Failed to get fiat rate. ${error.toString()}');
      throw Exception('Failed to get fiat rate. ${error.toString()}');
    }
  }

  Future<double> _requestPairRate(String pair) async {
    final fake = requestPairForTesting;
    if (fake != null) return fake(pair);
    if (_fiatApiMode == FiatApiMode.clearnet) {
      try {
        return await _requestPairRateClearnet(pair);
      } catch (error) {
        log(LogLevel.error, 'Failed to get fiat rate. ${error.toString()}');
        throw Exception('Failed to get fiat rate. ${error.toString()}');
      }
    }
    return _requestPairRateTor(pair);
  }

  /// Fetches the rate for one coin in [fiat], applying the USD->fiat bridge for
  /// fiat codes Kraken doesn't quote directly.
  Future<double> _fetchCoinRate(String coin, String fiat) async {
    final fixed = FiatRates.fixedRates?[coin];
    if (fixed != null) return fixed;
    final krakenBase = _krakenBase[coin]!;
    final isIndirect = FiatCurrency.of(fiat).bridgedViaUsd;
    final pair1 = isIndirect ? '${krakenBase}USD' : '$krakenBase$fiat';
    final pair2 = isIndirect ? 'USDT$fiat' : null;

    final rates = await Future.wait([
      _requestPairRate(pair1),
      pair2 != null ? _requestPairRate(pair2) : Future.value(null),
    ]);
    return rates[0]! * (rates[1] ?? 1);
  }

  Future<void> _loadRate() async {
    // A fetch is starting either way; a pending retry would only repeat it.
    _retryTimer?.cancel();
    _retryTimer = null;

    _fiatApiMode = await FiatRateModel.loadFiatApiMode();
    if (_fiatApiMode == FiatApiMode.disabled) {
      _rateFetchTimer?.cancel();
      _rateFetchTimer = null;
      _isDisabled = true;
      _hasFailed = false; // a disabled API is not a failed one
      notifyListeners();
      return;
    }
    _isDisabled = false;

    _fiatCode = await SharedPreferencesService.get<String>(SettingsKeys.fiatCurrency) ?? 'USD';
    // This fetch's currency and number. Fetches overlap (a currency change
    // restarts the service while the last one is still out), and each answer
    // is kept only if it is still current when it arrives.
    final fiat = _fiatCode;
    final fetch = ++_fetchCount;

    _isLoading = true;
    notifyListeners();

    final coinsToFetch = _activeKrakenCoins().toList();
    _lastFetchedActiveCoins = coinsToFetch.toSet();

    if (coinsToFetch.isEmpty) {
      _hasFailed = false;
      _isLoading = false;
      notifyListeners();
      return;
    }

    var anySucceeded = false;
    var anyFailed = false;

    await Future.wait(
      coinsToFetch.map((coin) async {
        try {
          final rate = await _fetchCoinRate(coin, fiat);
          anySucceeded = true;
          if (fiat != _fiatCode) {
            log(LogLevel.info, 'Dropped the $fiat/$coin rate: the currency is now $_fiatCode.');
            return;
          }
          final current = _rates[coin];
          if (current != null && current.fiat == fiat && current.fetch > fetch) {
            log(LogLevel.info, 'Dropped the $fiat/$coin rate: a newer fetch already answered.');
            return;
          }
          _rates[coin] = (fiat: fiat, value: rate, fetch: fetch);
          await _persist(coin, fiat, rate);
          log(LogLevel.info, '$fiat/$coin rate: $rate');
        } catch (error) {
          log(LogLevel.error, 'Failed to get $coin/$fiat rate. $error');
          anyFailed = true;
        }
      }),
    );

    // A fetch that a newer one has overtaken leaves loading, failure and
    // retries to that one.
    if (fetch == _fetchCount) {
      _hasFailed = anyFailed && !anySucceeded;
      _lastFetchFailed = anyFailed;
      _isLoading = false;
      _scheduleRetry(failed: anyFailed);
    }
    notifyListeners();
  }

  /// Retries a failed fetch on [retryBackoff], then leaves it to the poll. A
  /// success resets the schedule. Whatever the failure (Kraken down, no
  /// network, Tor still starting), the next attempt comes in seconds rather
  /// than ten minutes. Nothing about the wallet's own connection is involved.
  void _scheduleRetry({required bool failed}) {
    if (!failed) {
      _retryAttempt = 0;
      return;
    }
    // Only while the service runs; it arms the poll before any fetch returns.
    if (_rateFetchTimer == null || _retryAttempt >= retryBackoff.length) return;
    // Two fetches can overlap (a restart and a wallet change); one retry.
    _retryTimer?.cancel();
    _retryTimer = Timer(retryBackoff[_retryAttempt++], _loadRate);
  }

  /// Fetches now when the last fetch failed, rather than on [retryBackoff] or
  /// the 10-minute poll. For the app coming back to the foreground: the network
  /// may have changed meanwhile (a VPN switched on where Tor is blocked), and
  /// once the backoff has run out the next poll can be ten minutes away.
  void retryIfFailed() {
    if (!_lastFetchFailed || _isLoading || _isDisabled || _rateFetchTimer == null) return;
    unawaited(_loadRate());
  }

  Future<void> startService({WalletManager? walletManager}) async {
    if (walletManager != null) {
      attachWalletManager(walletManager);
    }
    _rateFetchTimer?.cancel();
    _rateFetchTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
    await _loadPersisted();
    _startRateFetchTimer();
  }
}
