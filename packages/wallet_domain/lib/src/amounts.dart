/// Exact decimal <-> integer base-unit conversion.
///
/// Money never travels through `double`.
/// `double` loses precision above 2^53, which is inside the range of a Monero
/// balance in piconero (12 decimals) and well inside an 18-decimal ETH value.
library;

/// Largest exponent accepted in `1.5e7` notation.
///
/// Only there to stop a nonsense exponent asking for a `10^n` the size of
/// memory. Any real amount is orders below it: 18 decimals over a supply of
/// `10^27` wei.
const _maxExponent = 1000;

/// Converts a decimal amount string to integer base units (e.g. XMR ->
/// piconero, ETH -> wei).
///
/// Digits finer than [decimals] are truncated toward zero, never rounded.
/// Dropping precision the asset cannot express is the **only** loss permitted
/// here: every other input either converts exactly or throws. Quietly returning
/// a different amount is the one outcome this must never have, because the
/// caller is about to spend it.
///
/// Exponential notation is accepted because it arrives whether or not anyone
/// asked for it: `double.toString()` switches to it below 1e-6, so an amount
/// that has been through a double — a scanned `tx_amount`, a Max button —
/// reaches here as `1.5e-7`. The exponent is normalised rather than rejected so
/// those amounts convert instead of failing.
BigInt decimalToBaseUnits(String amount, int decimals) {
  var s = amount.trim();
  if (s.isEmpty) return BigInt.zero;

  var negative = false;
  if (s.startsWith('-') || s.startsWith('+')) {
    negative = s.startsWith('-');
    s = s.substring(1);
  }

  var exponent = 0;
  final e = s.indexOf(RegExp('[eE]'));
  if (e >= 0) {
    final parsed = int.tryParse(s.substring(e + 1));
    if (parsed == null || parsed.abs() > _maxExponent) {
      throw FormatException('Invalid amount: $amount');
    }
    exponent = parsed;
    s = s.substring(0, e);
  }

  final parts = s.split('.');
  if (parts.length > 2) throw FormatException('Invalid amount: $amount');
  final intPart = parts[0];
  final fracPart = parts.length == 2 ? parts[1] : '';
  if (intPart.isEmpty && fracPart.isEmpty) throw FormatException('Invalid amount: $amount');
  if (!_isDigits(intPart) || !_isDigits(fracPart)) {
    throw FormatException('Invalid amount: $amount');
  }

  // The mantissa as an integer, with the point `fracPart.length` places from the
  // right, moved `exponent` places, then scaled by `10^decimals`. Folding the
  // three shifts into one keeps every step exact; the single division at the end
  // is the truncation, and the only place precision is lost.
  final digits = BigInt.parse('${intPart.isEmpty ? '0' : intPart}$fracPart');
  final shift = exponent - fracPart.length + decimals;
  final units = shift >= 0
      ? digits * BigInt.from(10).pow(shift)
      : digits ~/ BigInt.from(10).pow(-shift);

  return negative ? -units : units;
}

bool _isDigits(String s) => !s.contains(RegExp(r'[^0-9]'));

/// Inverse of [decimalToBaseUnits]: renders integer base units as a decimal
/// string, trimming trailing fractional zeros.
String baseUnitsToDecimalString(BigInt units, int decimals) {
  if (decimals <= 0) return units.toString();
  final negative = units.isNegative;
  final digits = units.abs().toString().padLeft(decimals + 1, '0');
  final intPart = digits.substring(0, digits.length - decimals);
  final fracPart = digits.substring(digits.length - decimals).replaceAll(RegExp(r'0+$'), '');
  final result = fracPart.isEmpty ? intPart : '$intPart.$fracPart';
  return negative ? '-$result' : result;
}
