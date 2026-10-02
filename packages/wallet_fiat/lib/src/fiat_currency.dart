import 'package:flutter/foundation.dart';

/// A fiat currency the apps can price in.
///
/// The one table both apps read. Anything that shows or parses a fiat amount
/// takes its symbol and minor units from [FiatCurrency.of], so every screen
/// agrees on how a currency looks.
@immutable
class FiatCurrency {
  const FiatCurrency._(this.code, this.symbol, this.decimals, {this.bridgedViaUsd = false});

  /// ISO 4217 code, as stored under `SettingsKeys.fiatCurrency`.
  final String code;

  /// Display prefix: `$`, `€`, `C$`.
  final String symbol;

  /// Minor-unit digits: 2 for cents, 0 for yen.
  final int decimals;

  /// Kraken has no direct pair for this currency, so rates are fetched in USD
  /// and bridged through `USDT<code>`.
  final bool bridgedViaUsd;

  static const usd = FiatCurrency._('USD', '\$', 2);
  static const eur = FiatCurrency._('EUR', '€', 2);
  static const cad = FiatCurrency._('CAD', 'C\$', 2, bridgedViaUsd: true);
  static const aud = FiatCurrency._('AUD', 'A\$', 2, bridgedViaUsd: true);
  static const gbp = FiatCurrency._('GBP', '£', 2, bridgedViaUsd: true);
  static const chf = FiatCurrency._('CHF', 'Fr', 2, bridgedViaUsd: true);
  static const jpy = FiatCurrency._('JPY', '¥', 0, bridgedViaUsd: true);

  /// Every supported currency, in picker order.
  static const List<FiatCurrency> all = [usd, eur, cad, aud, gbp, chf, jpy];

  /// The currency for [code], or USD for an unknown one (the model's default
  /// when nothing is stored).
  static FiatCurrency of(String code) {
    for (final c in all) {
      if (c.code == code) return c;
    }
    return usd;
  }

  @override
  String toString() => code;
}

/// One coin's price in the user's fiat currency.
typedef FiatQuote = ({FiatCurrency currency, double rate});

/// Where a price comes from. `FiatRateModel` is the real one; the seam exists
/// so amount entry can be tested without Kraken.
abstract interface class FiatQuoteSource implements Listenable {
  /// The price of [coinSymbol], or null when fiat is disabled or no rate has
  /// arrived. Null means "don't offer fiat at all", not "zero".
  FiatQuote? quoteFor(String coinSymbol);
}
