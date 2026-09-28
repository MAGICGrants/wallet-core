/// Exact fiat <-> coin base-unit conversion.
///
/// A typed fiat amount becomes a spend amount here, so the math stays in
/// integers: a `double` holds ~16 significant digits, fewer than an 18-decimal
/// token or a large XMR amount needs. The rate itself arrives as a `double`
/// (Kraken's reply is parsed that way and persisted that way), so it is taken
/// at its shortest round-trip decimal, which is the string Kraken sent for a
/// direct pair.
library;

import 'package:wallet_domain/wallet_domain.dart' show decimalToBaseUnits;

/// Decimal places the rate is carried at. Far below anything Kraken quotes, and
/// enough that a sub-cent token price loses nothing that matters.
const _rateDecimals = 18;

/// The coin amount, in base units, worth [fiat] at [rate] fiat per coin.
///
/// Rounded to the nearest base unit, so every representable digit of the coin
/// is used: `$1` of DAI at 0.9999 is `1.000100010001000100` DAI, not `1.0001`.
/// Digits of [fiat] finer than [fiatDecimals] are dropped first, the same
/// truncation [decimalToBaseUnits] applies to any typed amount.
///
/// Throws [FormatException] for text that is not a decimal amount, and
/// [ArgumentError] for a rate that is not a positive finite number.
BigInt fiatToBaseUnits(
  String fiat,
  double rate, {
  required int fiatDecimals,
  required int coinDecimals,
}) {
  final fiatMinor = decimalToBaseUnits(fiat, fiatDecimals);
  final rateScaled = _scaledRate(rate);
  // coin = fiat / rate
  //   units = (fiatMinor / 10^fd) / (rateScaled / 10^R) * 10^cd
  final numerator = fiatMinor * BigInt.from(10).pow(_rateDecimals + coinDecimals);
  final denominator = rateScaled * BigInt.from(10).pow(fiatDecimals);
  return _roundedDivide(numerator, denominator);
}

/// [units] of a coin, in fiat minor units (cents), rounded to the nearest one.
///
/// Throws [ArgumentError] for a rate that is not a positive finite number.
BigInt baseUnitsToFiatMinor(
  BigInt units,
  double rate, {
  required int coinDecimals,
  required int fiatDecimals,
}) {
  final rateScaled = _scaledRate(rate);
  //   minor = (units / 10^cd) * (rateScaled / 10^R) * 10^fd
  final numerator = units * rateScaled * BigInt.from(10).pow(fiatDecimals);
  final denominator = BigInt.from(10).pow(coinDecimals + _rateDecimals);
  return _roundedDivide(numerator, denominator);
}

BigInt _scaledRate(double rate) {
  if (!rate.isFinite || rate <= 0) {
    throw ArgumentError.value(rate, 'rate', 'must be a positive finite number');
  }
  // `toString` may use exponent notation (`1e-7`); decimalToBaseUnits accepts it.
  final scaled = decimalToBaseUnits(rate.toString(), _rateDecimals);
  if (scaled == BigInt.zero) {
    throw ArgumentError.value(rate, 'rate', 'is below the supported precision');
  }
  return scaled;
}

/// Half-up division for a non-negative numerator and a positive denominator.
BigInt _roundedDivide(BigInt numerator, BigInt denominator) {
  if (numerator.isNegative) {
    return -_roundedDivide(-numerator, denominator);
  }
  return (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);
}
