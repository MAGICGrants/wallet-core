import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show baseUnitsToDecimalString, decimalToBaseUnits;
import 'package:wallet_fiat/wallet_fiat.dart';
import 'package:wallet_infra/wallet_infra.dart' show SettingsKeys, SharedPreferencesService;

/// What the send screen's amount field is typed in.
enum AmountUnit { coin, fiat }

/// The send amount, typed in either the coin or the user's fiat currency.
///
/// [baseUnits] / [coinText] are the amount that will be spent, whichever unit
/// the field shows; callers must never read [field]'s text as a coin amount.
///
/// The rules:
///  - The number in the field is the amount, except when a swap or MAX put it
///    there. Then the field shows a rounding of an exact coin amount, which is
///    kept until the next edit so swapping back and forth never changes what is
///    sent.
///  - Fiat converts at the coin's full precision (see [fiatToBaseUnits]).
///  - When the rate updates, a typed fiat amount keeps its fiat value and the
///    coin amount follows. MAX keeps its coin amount and the fiat display
///    follows.
///  - When the rate goes away, fiat entry falls back to the coin, keeping the
///    coin amount, and [canSwap] turns false so the swap is hidden.
///  - The unit last chosen with [swap] is remembered and applied to the next
///    empty entry once a rate is available.
class AmountEntryController extends ChangeNotifier {
  AmountEntryController({
    required FiatQuoteSource quotes,
    required String coinSymbol,
    required int coinDecimals,
    bool restoreUnit = true,
  }) : _quotes = quotes,
       _coinSymbol = coinSymbol,
       _coinDecimals = coinDecimals {
    _quote = _quotes.quoteFor(_coinSymbol);
    field.addListener(_onFieldChanged);
    _quotes.addListener(_onQuotesChanged);
    if (restoreUnit) unawaited(_restoreUnit());
  }

  /// The text field's controller. Bind it to the input; read the amount from
  /// [baseUnits] or [coinText].
  final TextEditingController field = TextEditingController();

  final FiatQuoteSource _quotes;
  String _coinSymbol;
  int _coinDecimals;
  FiatQuote? _quote;
  AmountUnit _unit = AmountUnit.coin;

  /// The exact coin amount behind a field that shows a rounding of it.
  BigInt? _pinned;

  /// Whether [_pinned] outlives a rate change (MAX) or yields to the field's
  /// fiat value (a swap).
  bool _pinSurvivesRate = false;

  bool _preferFiat = false;

  /// Set once the user types or swaps, so a remembered unit that loads late
  /// never switches the field under them.
  bool _unitSettled = false;

  bool _writing = false;
  String _lastText = '';
  bool _disposed = false;

  AmountUnit get unit => _unit;
  String get coinSymbol => _coinSymbol;
  int get coinDecimals => _coinDecimals;

  /// The coin's price, or null when fiat is off or unpriced. Null hides the
  /// swap and every fiat figure.
  FiatQuote? get quote => _quote;
  bool get canSwap => _quote != null;

  bool get isEmpty => _pinned == null && field.text.trim().isEmpty;

  /// The amount to spend, in base units. Zero when empty or unparseable.
  BigInt get baseUnits {
    final pinned = _pinned;
    if (pinned != null) return pinned;
    try {
      if (_unit == AmountUnit.coin) return decimalToBaseUnits(field.text, _coinDecimals);
      final quote = _quote;
      if (quote == null) return BigInt.zero;
      return fiatToBaseUnits(
        field.text,
        quote.rate,
        fiatDecimals: quote.currency.decimals,
        coinDecimals: _coinDecimals,
      );
    } on FormatException {
      return BigInt.zero;
    }
  }

  /// [baseUnits] as a decimal coin string, for engines that take text. Empty
  /// when the field is.
  String get coinText => isEmpty ? '' : baseUnitsToDecimalString(baseUnits, _coinDecimals);

  /// The amount's fiat value in minor units (cents), or null without a rate. A
  /// typed fiat amount is returned as typed, not round-tripped.
  BigInt? get fiatMinorUnits {
    final quote = _quote;
    if (quote == null) return null;
    if (_unit == AmountUnit.fiat && _pinned == null) {
      try {
        return decimalToBaseUnits(field.text, quote.currency.decimals);
      } on FormatException {
        return BigInt.zero;
      }
    }
    return baseUnitsToFiatMinor(
      baseUnits,
      quote.rate,
      coinDecimals: _coinDecimals,
      fiatDecimals: quote.currency.decimals,
    );
  }

  /// Switches the field between the coin and fiat, keeping the amount exactly.
  void swap() {
    if (_quote == null) return;
    final hadAmount = !isEmpty;
    final units = baseUnits;
    _unit = _unit == AmountUnit.coin ? AmountUnit.fiat : AmountUnit.coin;
    _unitSettled = true;
    if (hadAmount) {
      _pinned = units;
      _write(_render(units));
    }
    unawaited(SharedPreferencesService.set<String>(SettingsKeys.sendAmountUnit, _unit.name));
    notifyListeners();
  }

  /// Sets the amount to exactly [units] of the coin, shown in the current unit.
  /// For MAX: the coin amount holds through rate changes.
  void setMax(BigInt units) {
    _pinned = units;
    _pinSurvivesRate = true;
    _write(_render(units));
    notifyListeners();
  }

  /// Puts [text] in the field as a coin amount, switching to the coin: for
  /// amounts that arrive denominated in it (a scanned request, a prefilled
  /// send). The text goes in verbatim, so validation sees what arrived.
  void setCoinText(String text) {
    _unit = AmountUnit.coin;
    _unitSettled = true;
    _clearPin();
    _write(text);
    notifyListeners();
  }

  void clear() {
    _clearPin();
    _write('');
    notifyListeners();
  }

  /// Changes the coin being sent. A fiat amount carries over when the new coin
  /// is priced (`$100` of ETH becomes `$100` of DAI); a coin amount does not,
  /// since it means a different value in another coin.
  void setCoin(String coinSymbol, int coinDecimals) {
    if (coinSymbol == _coinSymbol && coinDecimals == _coinDecimals) return;
    _coinSymbol = coinSymbol;
    _coinDecimals = coinDecimals;
    _quote = _quotes.quoteFor(coinSymbol);
    _clearPin();
    if (_unit == AmountUnit.fiat && _quote == null) _unit = AmountUnit.coin;
    if (_unit == AmountUnit.coin) _write('');
    _applyPreferredUnit();
    notifyListeners();
  }

  void _onFieldChanged() {
    if (_writing || field.text == _lastText) return;
    _lastText = field.text;
    _clearPin();
    _unitSettled = true;
    notifyListeners();
  }

  void _onQuotesChanged() {
    final previous = _quote;
    final next = _quotes.quoteFor(_coinSymbol);
    if (previous?.rate == next?.rate && previous?.currency == next?.currency) return;
    // Taken at the old rate: the amount the user is looking at.
    final units = baseUnits;
    _quote = next;

    if (_unit == AmountUnit.fiat) {
      if (next == null) {
        _unit = AmountUnit.coin;
        if (!isEmpty) {
          _pinned = null;
          _write(baseUnitsToDecimalString(units, _coinDecimals));
        }
      } else if (!isEmpty && previous?.currency != next.currency) {
        // A figure in the old currency means nothing in the new one.
        _pinned = units;
        _write(_render(units));
      } else if (_pinned != null) {
        if (_pinSurvivesRate) {
          _write(_render(_pinned!));
        } else {
          _pinned = null;
        }
      }
    }
    _applyPreferredUnit();
    notifyListeners();
  }

  Future<void> _restoreUnit() async {
    final stored = await SharedPreferencesService.get<String>(SettingsKeys.sendAmountUnit);
    if (_disposed) return;
    _preferFiat = stored == AmountUnit.fiat.name;
    if (_applyPreferredUnit()) notifyListeners();
  }

  /// Opens in fiat when that was the last unit chosen, but only on an empty
  /// field the user hasn't touched, and only once there is a rate.
  bool _applyPreferredUnit() {
    if (!_preferFiat || _unitSettled || _unit == AmountUnit.fiat) return false;
    if (_quote == null || !isEmpty) return false;
    _unit = AmountUnit.fiat;
    return true;
  }

  /// [units] as field text in the current unit. Fiat keeps its minor digits
  /// (`150.00`), the way money is typed.
  String _render(BigInt units) {
    final quote = _quote;
    if (_unit == AmountUnit.coin || quote == null) {
      return baseUnitsToDecimalString(units, _coinDecimals);
    }
    final decimals = quote.currency.decimals;
    final minor = baseUnitsToFiatMinor(
      units,
      quote.rate,
      coinDecimals: _coinDecimals,
      fiatDecimals: decimals,
    );
    if (decimals == 0) return minor.toString();
    final digits = minor.toString().padLeft(decimals + 1, '0');
    return '${digits.substring(0, digits.length - decimals)}.'
        '${digits.substring(digits.length - decimals)}';
  }

  void _clearPin() {
    _pinned = null;
    _pinSurvivesRate = false;
  }

  void _write(String text) {
    _writing = true;
    field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _lastText = text;
    _writing = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _quotes.removeListener(_onQuotesChanged);
    field.removeListener(_onFieldChanged);
    field.dispose();
    super.dispose();
  }
}
