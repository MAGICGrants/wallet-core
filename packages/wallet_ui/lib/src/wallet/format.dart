import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart' show baseUnitsToDecimalString;
import 'package:wallet_fiat/wallet_fiat.dart' show FiatCurrency;

/// Display formatters for the shared wallet widgets and both apps. Fiat
/// formatting takes a [FiatCurrency], so the symbol and precision always come
/// from the shared currency table.

final _fiatByDecimals = <int, NumberFormat>{};

/// Base units → display double at [decimals] magnitude. Lossy (`double`); UI
/// only. Exact money stays `BigInt`.
double displayAmount(BigInt units, int decimals) =>
    double.tryParse(baseUnitsToDecimalString(units, decimals)) ?? 0;

/// A coin amount at capped precision, optionally suffixed with [symbol].
String formatAmount(double value, int decimals, {String? symbol}) {
  final text = value.toStringAsFixed(decimals.clamp(0, 8));
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
