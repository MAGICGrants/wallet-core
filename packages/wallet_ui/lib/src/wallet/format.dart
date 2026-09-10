import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart' show baseUnitsToDecimalString;

/// Display formatters for the shared wallet widgets. These mirror the app-side
/// copies (e.g. Spice's `lib/util/format.dart` + `lib/util/amount_units.dart`);
/// the duplication is deliberate so app screens keep their own utils while the
/// shared widgets stay self-contained.

final _fiat = NumberFormat('#,##0.00');

/// Base units → display double at [decimals] magnitude. Lossy (`double`); UI
/// only. Exact money stays `BigInt`.
double displayAmount(BigInt units, int decimals) =>
    double.tryParse(baseUnitsToDecimalString(units, decimals)) ?? 0;

/// A coin amount at capped precision, optionally suffixed with [symbol].
String formatAmount(double value, int decimals, {String? symbol}) {
  final text = value.toStringAsFixed(decimals.clamp(0, 8));
  return symbol == null ? text : '$text $symbol';
}

/// Fiat amount with its currency symbol, grouped: `$1,234.56`.
String formatFiat(double amount, String symbol) => '$symbol${_fiat.format(amount)}';

/// Middle-truncates a long string (address / hash / key): `abcdef…uvwxyz`.
String shortenMiddle(String s, {int head = 6, int tail = 6}) =>
    s.length <= head + tail + 1 ? s : '${s.substring(0, head)}…${s.substring(s.length - tail)}';
