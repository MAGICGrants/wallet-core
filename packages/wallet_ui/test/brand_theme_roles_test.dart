import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/design.dart';

/// Every token a distinct colour, so a role wired to the wrong one — or left to
/// `ColorScheme.fromSeed` — cannot coincidentally match.
BrandPalette _probe() {
  var n = 0;
  (int, int) next() {
    n++;
    return (0xFF000000 | (n * 0x010203), 0xFF000000 | (0x800000 + n * 0x010203));
  }

  return BrandPalette(
    paper: next(),
    card: next(),
    surfaceSunken: next(),
    surfaceTinted: next(),
    surfaceMuted: next(),
    hairline: next(),
    border: next(),
    borderStrong: next(),
    inputBorder: next(),
    frameEdge: next(),
    ink: next(),
    inverseSurface: next(),
    inkMuted: next(),
    inkFaint: next(),
    inkDisabled: next(),
    primary: next(),
    primaryDeep: next(),
    success: next(),
    successBg: next(),
    warning: next(),
    warningBg: next(),
    error: next(),
    errorBg: next(),
    purple: next(),
    blue: next(),
    orange: next(),
    electrum: next(),
    surfaceAccent: next(),
    purpleBg: next(),
    blueBg: next(),
    orangeBg: next(),
    electrumBg: next(),
  );
}

void main() {
  setUp(() => BrandColors.install(_probe()));

  for (final entry in {'light': brandLightTheme, 'dark': brandDarkTheme}.entries) {
    test('every Material role a widget paints from is a brand token (${entry.key})', () {
      final scheme = entry.value().colorScheme;
      // Re-pin: the builder set the brightness, and the tokens resolve against it.
      BrandColors.setBrightness(scheme.brightness);

      final expected = <String, (Color, Color)>{
        'primary': (scheme.primary, BrandColors.primary),
        'onPrimary': (scheme.onPrimary, BrandColors.onPrimary),
        'secondary': (scheme.secondary, BrandColors.primaryDeep),
        'surface': (scheme.surface, BrandColors.paper),
        'onSurface': (scheme.onSurface, BrandColors.ink),
        'inverseSurface': (scheme.inverseSurface, BrandColors.inverseSurface),
        'onInverseSurface': (scheme.onInverseSurface, BrandColors.onPrimary),
        // The container ramp: dialogs, menus, chips, bottom sheets.
        'surfaceContainerLowest': (scheme.surfaceContainerLowest, BrandColors.paper),
        'surfaceContainerLow': (scheme.surfaceContainerLow, BrandColors.card),
        'surfaceContainer': (scheme.surfaceContainer, BrandColors.surfaceSunken),
        'surfaceContainerHigh': (scheme.surfaceContainerHigh, BrandColors.surfaceTinted),
        'surfaceContainerHighest': (scheme.surfaceContainerHighest, BrandColors.surfaceMuted),
        'onSurfaceVariant': (scheme.onSurfaceVariant, BrandColors.inkMuted),
        'outline': (scheme.outline, BrandColors.border),
        'outlineVariant': (scheme.outlineVariant, BrandColors.hairline),
        'error': (scheme.error, BrandColors.error),
        'onError': (scheme.onError, BrandColors.onPrimary),
        'errorContainer': (scheme.errorContainer, BrandColors.errorBg),
        'onErrorContainer': (scheme.onErrorContainer, BrandColors.error),
      };

      for (final role in expected.entries) {
        final (actual, token) = role.value;
        expect(
          actual,
          token,
          reason:
              '${role.key} is not pinned to its brand token, so Material derives it '
              'from the primary hue — which is how Skylight ended up painting its '
              'dialogs in Spice\'s cream.',
        );
      }
    });
  }
}
