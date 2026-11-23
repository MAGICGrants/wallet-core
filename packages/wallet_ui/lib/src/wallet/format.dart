import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart' show baseUnitsToDecimalString;
import 'package:wallet_fiat/wallet_fiat.dart' show FiatCurrency;

/// Display formatters for the shared wallet widgets and both apps. Fiat
/// formatting takes a [FiatCurrency], so the symbol and precision always come
/// from the shared currency table.

final _fiatByDecimals = <int, NumberFormat>{};

/// Base units → display double at [decimals] magnitude. Lossy (`double`); for
/// fiat arithmetic and charts only. Coin amounts a user reads go through
/// [formatExactAmount] or [formatTrimmedAmount].
double displayAmount(BigInt units, int decimals) =>
    double.tryParse(baseUnitsToDecimalString(units, decimals)) ?? 0;

/// [units] written out to the last base unit, trailing zeros dropped (`0.25`,
/// `3.141592653589`), optionally suffixed with [symbol].
///
/// For every amount a user checks before or after money moves: the send
/// screen, the confirm sheet and transaction details. Straight from base units,
/// so nothing is ever rounded.
String formatExactAmount(BigInt units, int baseDecimals, {String? symbol}) {
  final text = baseUnitsToDecimalString(units, baseDecimals);
  return symbol == null ? text : '$text $symbol';
}

/// [units] for the balance and activity screens: cut to [decimals] places,
/// never rounded, so it never reads higher than the real amount. Null
/// [decimals] (Trim Decimals off, or no price known) is every digit, as
/// [formatExactAmount] writes it.
///
/// A non-zero amount that would read as zero is written as the smallest step
/// shown instead: `<0.00001`. A negative amount gets a leading `-`; callers that
/// draw their own sign pass the magnitude. [decimals] comes from
/// `FiatRateModel.trimDigitsFor`.
String formatTrimmedAmount(BigInt units, int baseDecimals, int? decimals, {String? symbol}) {
  if (decimals == null || baseDecimals <= 0) {
    return formatExactAmount(units, baseDecimals, symbol: symbol);
  }
  final shownDecimals = decimals.clamp(0, baseDecimals);
  final magnitude = units.abs();
  final shown = magnitude ~/ BigInt.from(10).pow(baseDecimals - shownDecimals);
  final String body;
  if (shown == BigInt.zero && magnitude != BigInt.zero) {
    body = '<${shownDecimals == 0 ? '1' : '0.${'0' * (shownDecimals - 1)}1'}';
  } else if (shownDecimals == 0) {
    body = shown.toString();
  } else {
    final digits = shown.toString().padLeft(shownDecimals + 1, '0');
    final point = digits.length - shownDecimals;
    body = '${digits.substring(0, point)}.${digits.substring(point)}';
  }
  final text = units.isNegative ? '-$body' : body;
  return symbol == null ? text : '$text $symbol';
}

/// Fiat amount in [currency], grouped, at its minor-unit precision:
/// `$1,234.56`, `¥53,412`.
String formatFiat(double amount, FiatCurrency currency) {
  final format = _fiatByDecimals.putIfAbsent(
    currency.decimals,
    () => NumberFormat(currency.decimals == 0 ? '#,##0' : '#,##0.${'0' * currency.decimals}'),
  );
  return '${currency.symbol}${format.format(amount)}';
}

/// Middle-truncates a long string (address / hash / key): `abcdef…uvwxyz`.
String shortenMiddle(String s, {int head = 6, int tail = 6}) =>
    s.length <= head + tail + 1 ? s : '${s.substring(0, head)}…${s.substring(s.length - tail)}';
