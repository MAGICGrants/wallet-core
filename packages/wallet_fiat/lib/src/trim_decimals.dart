/// "Trim Decimals": how much of a coin amount's tail the balance and activity
/// screens leave out, worked out from the coin's price.
///
/// Send, confirm and transaction details never trim; they show every digit.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'fiat_currency.dart';

/// A Trim Decimals level. Each one hides the digits of a coin amount worth
/// less than [minorUnits] of the display currency's smallest unit (1 = a cent,
/// a yen), so a level means the same thing in every currency and survives a
/// currency change as it is.
enum TrimDecimals {
  off(0),
  belowOne(1),
  belowTen(10),
  belowHundred(100);

  const TrimDecimals(this.minorUnits);

  /// The threshold in the currency's smallest unit; 0 for [off].
  final int minorUnits;

  /// What a fresh install uses: digits worth under a cent are hidden.
  static const TrimDecimals initial = belowOne;

  /// As stored under `SettingsKeys.trimDecimals`: `off`, `1`, `10` or `100`.
  String get storageValue => this == off ? 'off' : '$minorUnits';

  /// The level stored as [value]; [initial] for nothing stored or anything
  /// unrecognised.
  static TrimDecimals fromStorage(String? value) {
    for (final level in values) {
      if (level.storageValue == value) return level;
    }
    return initial;
  }

  /// The threshold in [currency]: `0.01` for one US cent, `1` for one yen.
  double thresholdIn(FiatCurrency currency) => minorUnits / math.pow(10, currency.decimals);
}

/// How far past the threshold the hidden part may go. Without it, a coin
/// priced right at a power of ten (Dai at $0.9999 and at $1.0003) would gain
/// and lose a digit with every price update.
const double trimTolerance = 1.05;

/// Upper bound on the search. No coin has this many decimals, and `10^k`
/// stays exact in a double up to `10^22`.
const int _maxTrimDecimals = 22;

/// The decimals that keep what [level] hides under its threshold at [rate]
/// (the price of one coin in [currency]): the smallest `k >= 0` with
/// `rate × 10^-k <= threshold × trimTolerance`.
///
/// Not capped at the coin's precision; the caller clamps to its base-unit
/// decimals. Null for [TrimDecimals.off] or a rate that is not a positive
/// finite number, both of which mean "show every digit".
int? trimmedDecimals(double rate, FiatCurrency currency, TrimDecimals level) {
  if (level == TrimDecimals.off || !rate.isFinite || rate <= 0) return null;
  final limit = level.thresholdIn(currency) * trimTolerance;
  for (var k = 0; k < _maxTrimDecimals; k++) {
    // rate × 10^-k <= limit, kept in multiplication so each side rounds once.
    if (rate <= limit * math.pow(10, k)) return k;
  }
  return _maxTrimDecimals;
}

/// The decimals each level gave each coin at its last accepted rate.
///
/// Saved beside the rate so amounts keep trimming while the next price loads,
/// including after a currency change, which wipes the saved rates. Keyed by the
/// coin's Kraken base symbol (`XMR`; a testnet coin shares its mainnet entry),
/// then by [TrimDecimals.minorUnits]. Holds nothing about the user: only the
/// size of public market prices.
@immutable
class SavedTrimDigits {
  const SavedTrimDigits._(this._byCoin);

  static const SavedTrimDigits empty = SavedTrimDigits._({});

  final Map<String, ({String fiat, Map<int, int> digits})> _byCoin;

  /// What [level] gave [coin] at its last saved rate; null when nothing was
  /// saved for it.
  int? digitsFor(String coin, TrimDecimals level) =>
      level == TrimDecimals.off ? null : _byCoin[coin.toUpperCase()]?.digits[level.minorUnits];

  /// These digits with [coin]'s entry replaced by what [rate] in [currency]
  /// gives at every level.
  SavedTrimDigits withRate(String coin, double rate, FiatCurrency currency) {
    final digits = <int, int>{
      for (final level in TrimDecimals.values)
        level.minorUnits: ?trimmedDecimals(rate, currency, level),
    };
    if (digits.isEmpty) return this;
    return SavedTrimDigits._({
      ..._byCoin,
      coin.toUpperCase(): (fiat: currency.code, digits: digits),
    });
  }

  /// As stored under `SettingsKeys.trimDigits`:
  /// `{"XMR": {"fiat": "USD", "digits": {"1": 5, "10": 4, "100": 3}}}`.
  String encode() => jsonEncode({
    for (final MapEntry(key: coin, value: entry) in _byCoin.entries)
      coin: {
        'fiat': entry.fiat,
        'digits': {for (final d in entry.digits.entries) '${d.key}': d.value},
      },
  });

  /// The digits stored as [json]. Anything unreadable is skipped, entry by
  /// entry, so a damaged value costs only the trimming it described.
  static SavedTrimDigits decode(String? json) {
    if (json == null || json.isEmpty) return empty;
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return empty;
    }
    if (decoded is! Map) return empty;
    final byCoin = <String, ({String fiat, Map<int, int> digits})>{};
    for (final MapEntry(key: coin, value: entry) in decoded.entries) {
      if (coin is! String || entry is! Map) continue;
      final fiat = entry['fiat'];
      final rawDigits = entry['digits'];
      if (fiat is! String || rawDigits is! Map) continue;
      final digits = <int, int>{};
      for (final MapEntry(key: minor, value: k) in rawDigits.entries) {
        final minorUnits = minor is String ? int.tryParse(minor) : null;
        if (minorUnits == null || k is! int || k < 0) continue;
        digits[minorUnits] = k;
      }
      if (digits.isNotEmpty) byCoin[coin.toUpperCase()] = (fiat: fiat, digits: digits);
    }
    return SavedTrimDigits._(byCoin);
  }
}
