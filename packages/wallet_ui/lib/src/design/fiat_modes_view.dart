import 'package:flutter/material.dart';

import 'brand.dart';
import 'fiat_controls.dart';
import 'mode_select_card.dart';
import 'section_header.dart';

/// A selectable fiat currency — its code and display symbol.
class FiatCurrencyOption {
  final String code;
  final String symbol;

  const FiatCurrencyOption({required this.code, required this.symbol});
}

/// The fiat rate-source selection body shared by the onboarding [FiatSetupView]
/// and the in-app fiat settings sheet: three [ModeSelectCard]s (Tor-only /
/// clearnet / disabled) and, unless disabled, a currency picker.
///
/// Presentational only. Mode is an int index (0=torOnly, 1=clearnet,
/// 2=disabled — matching each app's `FiatApiMode.index`) so it couples to no
/// fiat enum. [modeLabel] adds a section header above the cards (settings shows
/// one; onboarding, which has its own title, passes null).
class FiatModesView extends StatelessWidget {
  final String? modeLabel;
  final String torOnly;
  final String torOnlyDesc;
  final String clearnet;
  final String clearnetDesc;
  final String disabled;
  final String disabledDesc;

  /// Whether the Tor-only card is offered. Hidden when global Tor is off, since
  /// Tor-only fiat is unreachable then.
  final bool offerTorOnly;
  final int modeIndex;
  final ValueChanged<int> onModeChanged;

  final String currencyLabel;
  final List<FiatCurrencyOption> currencies;
  final String currency;
  final ValueChanged<String> onCurrencyChanged;

  const FiatModesView({
    super.key,
    this.modeLabel,
    required this.torOnly,
    required this.torOnlyDesc,
    required this.clearnet,
    required this.clearnetDesc,
    required this.disabled,
    required this.disabledDesc,
    required this.offerTorOnly,
    required this.modeIndex,
    required this.onModeChanged,
    required this.currencyLabel,
    required this.currencies,
    required this.currency,
    required this.onCurrencyChanged,
  });

  static const int _torOnly = 0;
  static const int _disabled = 2;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (modeLabel != null) ...[
          SectionHeader(label: modeLabel!),
          const SizedBox(height: BrandSpacing.md),
        ],
        if (offerTorOnly) ...[
          ModeSelectCard(
            title: torOnly,
            description: torOnlyDesc,
            selected: modeIndex == _torOnly,
            onTap: () => onModeChanged(_torOnly),
          ),
          const SizedBox(height: BrandSpacing.md),
        ],
        ModeSelectCard(
          title: clearnet,
          description: clearnetDesc,
          selected: modeIndex == 1,
          onTap: () => onModeChanged(1),
        ),
        const SizedBox(height: BrandSpacing.md),
        ModeSelectCard(
          title: disabled,
          description: disabledDesc,
          selected: modeIndex == _disabled,
          onTap: () => onModeChanged(_disabled),
        ),
        if (modeIndex != _disabled) ...[
          const SizedBox(height: BrandSpacing.xl),
          SectionHeader(label: currencyLabel),
          const SizedBox(height: BrandSpacing.md),
          Wrap(
            spacing: BrandSpacing.sm,
            runSpacing: BrandSpacing.sm,
            children: [
              for (final option in currencies)
                FiatCurrencyChip(
                  code: option.code,
                  symbol: option.symbol,
                  selected: currency == option.code,
                  onTap: () => onCurrencyChanged(option.code),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
