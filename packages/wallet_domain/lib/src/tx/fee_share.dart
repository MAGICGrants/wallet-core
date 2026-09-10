import '../amounts.dart';
import '../crypto_wallet.dart';
import 'tx_details.dart';

/// Why a fee's share of the amount could not be worked out.
enum FeeShareUnknown {
  /// The amount is zero (or negative), so a fraction of it is undefined. A sweep
  /// whose fee consumed everything lands here.
  noAmount,

  /// The fee is denominated in a different coin than the amount; an ERC-20 send
  /// pays its gas in ETH; so the two are only comparable through a common unit,
  /// and no fiat rate was available for one or both sides.
  ///
  /// Entirely expected: the user may have fiat lookups switched off, or be on
  /// Tor, where they fail closed by design. **This is not an error, and must
  /// never block a send.** See [FeeShare.needsManualCheck].
  noFiatRate,
}

/// The fee as a fraction of the amount being sent, or why that is unknown.
///
/// Deliberately **not** a `double?`. A nullable would let a caller write
/// `if (ratio != null && ratio > threshold)` and silently show nothing when the
/// ratio is unknown, which reads to the user as "checked, it's fine" when in
/// fact nothing was checked. The third state is on the type so it has to be
/// handled.
///
/// Deliberately carries **no threshold**. What counts as "too high" is a claim
/// about market conditions, which this repository does not make; see
/// This computes the number; the application judges it.
class FeeShare {
  const FeeShare._(this.fraction, this.unknownBecause);

  /// A known ratio; `0.1` means the fee is 10% of the amount.
  const FeeShare.known(double fraction) : this._(fraction, null);

  const FeeShare.unknown(FeeShareUnknown reason) : this._(null, reason);

  /// Fee ÷ amount, or null when unknown.
  final double? fraction;

  /// Set when [fraction] is null.
  final FeeShareUnknown? unknownBecause;

  bool get isKnown => fraction != null;

  /// The ratio as a percentage, or null when unknown.
  double? get percent => fraction == null ? null : fraction! * 100;

  /// Whether the application must ask the user to check the fee themselves.
  ///
  /// Named for what the UI is supposed to do about it. When this is true, show
  /// the fee (which is always known and exact) alongside a note that it could
  /// not be compared to the amount, and let the send proceed. Refusing to send
  /// because a *fiat rate* was unavailable would be a far worse outcome than a
  /// fee the user was asked to eyeball.
  bool get needsManualCheck => fraction == null;

  @override
  String toString() => isKnown
      ? 'FeeShare(${percent!.toStringAsFixed(2)}%)'
      : 'FeeShare(unknown: ${unknownBecause!.name})';
}

/// Ratio precision for the same-currency path: integer math to a millionth of a
/// millionth, then one conversion at the end. Keeps the amounts off `double`
/// until the ratio exists; the ratio is a display quantity, the amounts
/// feeding it are not.
///
/// 1e12 rather than something coarser because a dust fee on a whole coin is a
/// few parts per million, and truncating that to the nearest millionth would
/// report a visibly wrong percentage. The scaled result stays inside a double's
/// exact integer range for any ratio below ~9000×; past that the fee is
/// absurdly larger than the amount and a digit of precision is not the problem.
final BigInt _ratioScale = BigInt.from(1000000000000);
const double _ratioScaleDouble = 1000000000000;

/// The fee's share of the amount [tx] is sending.
///
/// Two cases:
///
///  - **Same coin** (XMR fee on an XMR send). One unit, so the ratio is exact
///    and needs no fiat rate. Must keep working with fiat off and over Tor.
///  - **Foreign fee** (an ERC-20 send: fee in ETH, amount in the token). Only
///    comparable through fiat, so [fiatRateFor] is asked for both symbols. If
///    either is missing the result is [FeeShareUnknown.noFiatRate] and the
///    caller warns instead of blocking.
///
/// [fiatRateFor] returns the fiat price of one whole coin for a symbol, or null
/// if unavailable. Pass null for the whole callback when the app has no fiat at
/// all; the same-currency path is unaffected.
FeeShare feeShareOfAmount(
  CryptoWallet wallet,
  PendingTransaction tx, {
  double? Function(String coinSymbol)? fiatRateFor,
}) {
  final amount = tx.amountBaseUnits;
  final fee = tx.feeBaseUnits;
  if (amount <= BigInt.zero) return const FeeShare.unknown(FeeShareUnknown.noAmount);

  final amountDecimals = wallet.baseUnitDecimals;
  final feeDecimals = wallet.feeBaseUnitDecimals;

  if (!wallet.feeIsForeign) {
    // One coin, so one unit, but normalise the exponents anyway rather than
    // assuming the two decimals getters agree. A coin that overrode one and not
    // the other would otherwise produce a ratio wrong by a factor of 10^n, and
    // a *silently* wrong percentage is worse than none.
    final scaleFee = _pow10(amountDecimals > feeDecimals ? amountDecimals - feeDecimals : 0);
    final scaleAmount = _pow10(feeDecimals > amountDecimals ? feeDecimals - amountDecimals : 0);
    final scaled = (fee * scaleFee * _ratioScale) ~/ (amount * scaleAmount);
    return FeeShare.known(scaled.toDouble() / _ratioScaleDouble);
  }

  // Foreign fee: fiat is the common unit, and there is no substitute for it.
  // Comparing an ETH fee to a DAI amount without one is not a conservative
  // approximation, it is a meaningless number.
  final amountRate = fiatRateFor?.call(wallet.coinSymbol);
  final feeRate = fiatRateFor?.call(wallet.feeCoinSymbol);
  if (amountRate == null || feeRate == null) {
    return const FeeShare.unknown(FeeShareUnknown.noFiatRate);
  }

  final amountFiat = _toDecimal(amount, amountDecimals) * amountRate;
  final feeFiat = _toDecimal(fee, feeDecimals) * feeRate;
  if (amountFiat <= 0) return const FeeShare.unknown(FeeShareUnknown.noAmount);
  return FeeShare.known(feeFiat / amountFiat);
}

BigInt _pow10(int exponent) => BigInt.from(10).pow(exponent);

/// Base units to a decimal `double`, via the exact string form so the conversion
/// happens once. Lossy by nature, it is feeding a fiat multiplication, and
/// only ever used on the foreign-fee path, where doubles are unavoidable because
/// the rates themselves are doubles.
double _toDecimal(BigInt units, int decimals) =>
    double.tryParse(baseUnitsToDecimalString(units, decimals)) ?? 0;
