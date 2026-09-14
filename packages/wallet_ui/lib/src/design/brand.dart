import 'package:flutter/material.dart';

/// Shared brand design tokens, extracted from Spice's design handoff so both
/// apps render the same UI with a per-app colour palette.
///
/// The raw hex comes from an installed [BrandPalette] — the app calls
/// [BrandColors.install] once in `main()` before `runApp`. The static-getter
/// call-site API (`BrandColors.paper`, etc.) is unchanged, so consumers don't
/// care where the values come from. Every value except the chain brands +
/// [onPrimary] resolves per brightness; [setBrightness] is called once per frame
/// from the app's `MaterialApp.builder`, driven by the theme picker. Because the
/// resolved tokens are getters (not `const`), they can't be used in `const`
/// expressions — but the chain colours + [onPrimary] stay `const` for the few
/// call sites that need them inside `const` widgets.

/// A brightness-resolved colour palette: `(lightHex, darkHex)` for every
/// palette-backed [BrandColors] token. The chain colours + [BrandColors.onPrimary]
/// are NOT here — they are compile-time constants (needed for `const` call sites).
class BrandPalette {
  const BrandPalette({
    required this.paper,
    required this.card,
    required this.surfaceSunken,
    required this.surfaceTinted,
    required this.surfaceMuted,
    required this.hairline,
    required this.border,
    required this.borderStrong,
    required this.inputBorder,
    required this.frameEdge,
    required this.ink,
    required this.inverseSurface,
    required this.inkMuted,
    required this.inkFaint,
    required this.inkDisabled,
    required this.primary,
    required this.primaryDeep,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.error,
    required this.errorBg,
    required this.purple,
    required this.blue,
    required this.orange,
    required this.electrum,
    required this.surfaceAccent,
    required this.purpleBg,
    required this.blueBg,
    required this.orangeBg,
    required this.electrumBg,
  });

  // Each field is (lightHex, darkHex) as 0xAARRGGBB ints.
  final (int, int) paper,
      card,
      surfaceSunken,
      surfaceTinted,
      surfaceMuted,
      hairline,
      border,
      borderStrong,
      inputBorder,
      frameEdge;
  final (int, int) ink, inverseSurface, inkMuted, inkFaint, inkDisabled;
  final (int, int) primary, primaryDeep;
  final (int, int) success, successBg, warning, warningBg, error, errorBg;
  final (int, int) purple, blue, orange, electrum;
  final (int, int) surfaceAccent, purpleBg, blueBg, orangeBg, electrumBg;
}

/// Neutral fallback so a forgotten [BrandColors.install] renders greys rather
/// than crashing. Apps install their own palette in `main()`.
const _fallbackPalette = BrandPalette(
  paper: (0xFFFFFFFF, 0xFF121212),
  card: (0xFFFFFFFF, 0xFF1E1E1E),
  surfaceSunken: (0xFFF2F2F2, 0xFF262626),
  surfaceTinted: (0xFFEDEDED, 0xFF222222),
  surfaceMuted: (0xFFE6E6E6, 0xFF2E2E2E),
  hairline: (0xFFE6E6E6, 0xFF2E2E2E),
  border: (0xFFE0E0E0, 0xFF2E2E2E),
  borderStrong: (0xFFCFCFCF, 0xFF3A3A3A),
  inputBorder: (0xFFBDBDBD, 0xFF3A3A3A),
  frameEdge: (0xFFCFCFCF, 0xFF3A3A3A),
  ink: (0xFF1A1A1A, 0xFFEDEDED),
  inverseSurface: (0xFF1A1A1A, 0xFF2E2E2E),
  inkMuted: (0xFF6B6B6B, 0xFFA6A6A6),
  inkFaint: (0xFF8A8A8A, 0xFF8A8A8A),
  inkDisabled: (0xFFBDBDBD, 0xFF5A5A5A),
  primary: (0xFF3A3A3A, 0xFFB0B0B0),
  primaryDeep: (0xFF2A2A2A, 0xFFC8C8C8),
  success: (0xFF2F7D6B, 0xFF7FB98A),
  successBg: (0xFFE7F0E6, 0xFF21332B),
  warning: (0xFFC98A2E, 0xFFE0A94E),
  warningBg: (0xFFFBEFDC, 0xFF33291A),
  error: (0xFFB04A2F, 0xFFE0785A),
  errorBg: (0xFFF8E4DC, 0xFF3A241E),
  purple: (0xFF6B4E9E, 0xFF9E86C9),
  blue: (0xFF37628F, 0xFF6E9BC9),
  orange: (0xFFBB5F1F, 0xFFDD8A4A),
  electrum: (0xFF1E8FC9, 0xFF5CB6E6),
  surfaceAccent: (0xFFF0F0F0, 0xFF2E2E2E),
  purpleBg: (0xFFEFE9F8, 0xFF2A2440),
  blueBg: (0xFFE6EEF7, 0xFF1E2A3A),
  orangeBg: (0xFFF9E8D6, 0xFF3A2A18),
  electrumBg: (0xFFDDF0FB, 0xFF152F3E),
);

/// Brand colour tokens. Install a [BrandPalette] once from the app's `main()`.
class BrandColors {
  BrandColors._();

  static BrandPalette _palette = _fallbackPalette;
  static bool _dark = false;
  static bool get isDark => _dark;

  /// Install the app's palette. Call once in `main()` before `runApp`.
  static void install(BrandPalette palette) => _palette = palette;

  /// Point the tokens at the light or dark palette. Cheap; safe to call every
  /// build. Only flips on an actual theme change (which rebuilds the tree).
  static void setBrightness(Brightness brightness) => _dark = brightness == Brightness.dark;

  static Color _pick((int, int) token) => Color(_dark ? token.$2 : token.$1);

  // Grounds & warm surfaces
  static Color get paper => _pick(_palette.paper); // screen bg
  static Color get card => _pick(_palette.card); // raised list-item cards
  static Color get surfaceSunken => _pick(_palette.surfaceSunken); // fields, 2ndary btns, tiles
  static Color get surfaceTinted => _pick(_palette.surfaceTinted); // segmented-control track
  static Color get surfaceMuted => _pick(_palette.surfaceMuted); // disabled fills, neutral pills
  static Color get hairline => _pick(_palette.hairline); // dividers inside cards
  static Color get border => _pick(_palette.border); // card / tile borders
  static Color get borderStrong => _pick(_palette.borderStrong);
  static Color get inputBorder => _pick(_palette.inputBorder);
  static Color get frameEdge => _pick(_palette.frameEdge);

  // Ink
  static Color get ink => _pick(_palette.ink);

  /// A dark chip that stays dark in both modes (with [onPrimary] text on it) —
  /// e.g. the "tap to reveal" affordance. Unlike [ink], it does not invert.
  static Color get inverseSurface => _pick(_palette.inverseSurface);
  static Color get inkMuted => _pick(_palette.inkMuted);
  static Color get inkFaint => _pick(_palette.inkFaint);
  static Color get inkDisabled => _pick(_palette.inkDisabled);

  // Brand primary (Spice: cinnamon; Skylight: burnt orange)
  static Color get primary => _pick(_palette.primary); // primary buttons, selected states
  static Color get primaryDeep => _pick(_palette.primaryDeep); // save, links, quieter primary
  static const onPrimary = Color(0xFFFFFDF6);

  // Semantic
  static Color get success => _pick(_palette.success);
  static Color get successBg => _pick(_palette.successBg);
  static Color get warning => _pick(_palette.warning);
  static Color get warningBg => _pick(_palette.warningBg);
  static Color get error => _pick(_palette.error);
  static Color get errorBg => _pick(_palette.errorBg);
  // General accent hues (Tor route glyph = purple; proxy = blue; server-kind
  // pill = orange; Bitcoin Electrum = light blue).
  static Color get purple => _pick(_palette.purple);
  static Color get blue => _pick(_palette.blue);
  static Color get orange => _pick(_palette.orange);
  static Color get electrum => _pick(_palette.electrum);

  // Accent-tile backgrounds
  static Color get surfaceAccent => _pick(_palette.surfaceAccent);
  static Color get purpleBg => _pick(_palette.purpleBg);
  static Color get blueBg => _pick(_palette.blueBg);
  static Color get orangeBg => _pick(_palette.orangeBg);
  static Color get electrumBg => _pick(_palette.electrumBg);

  // Chain brand — identical in both modes + both apps, so they stay const
  // (usable in const widgets like CoinMark).
  static const monero = Color(0xFFFF6600);
  static const bitcoin = Color(0xFFF7931A);
  static const ethereum = Color(0xFF627EEA);
  static const dai = Color(0xFFF5AC37);
  static const serai = Color(0xFF2F7D6B);
}

class BrandRadii {
  BrandRadii._();
  static const badge = 6.0;
  static const tile = 12.0;
  static const button = 16.0;
  static const field = 18.0;
  static const card = 20.0;
  static const sheet = 22.0;
  static const pill = 999.0;

  static const rTile = BorderRadius.all(Radius.circular(tile));
  static const rButton = BorderRadius.all(Radius.circular(button));
  static const rField = BorderRadius.all(Radius.circular(field));
  static const rCard = BorderRadius.all(Radius.circular(card));
  static const rPill = BorderRadius.all(Radius.circular(pill));
}

class BrandSpacing {
  BrandSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 22.0; // screen gutter
  static const xxl = 32.0;
}

class BrandMotion {
  BrandMotion._();

  /// Universal transition duration for all animated brand widgets.
  static const transition = Duration(milliseconds: 300);
}

class BrandShadows {
  BrandShadows._();
  static const soft = <BoxShadow>[
    BoxShadow(color: Color(0x142C170C), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const sheet = <BoxShadow>[
    BoxShadow(color: Color(0x382C170C), blurRadius: 40, offset: Offset(0, -10)),
  ];
}

/// Type scale. Ubuntu for UI text; Ubuntu Mono for every number, address, seed
/// word, hash and technical badge. Weights 400/500/700. The Ubuntu fonts are
/// bundled per-app (both apps ship them under the same family names).
class BrandText {
  BrandText._();
  static const _ui = 'Ubuntu';
  static const _mono = 'Ubuntu Mono';
  static const _tnum = [FontFeature.tabularFigures()];

  static TextStyle get balance => TextStyle(
    fontFamily: _mono,
    fontSize: 36,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.72, // -.02em
    height: 1,
    color: BrandColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get chainBalance => TextStyle(
    fontFamily: _mono,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 1,
    color: BrandColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get title => TextStyle(
    fontFamily: _ui,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.24,
    height: 1.2,
    color: BrandColors.ink,
  );
  static TextStyle get sheetTitle => TextStyle(
    fontFamily: _ui,
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.25,
    color: BrandColors.ink,
  );
  static TextStyle get appBar =>
      TextStyle(fontFamily: _ui, fontSize: 16, fontWeight: FontWeight.w500, color: BrandColors.ink);
  static TextStyle get listTitle => TextStyle(
    fontFamily: _ui,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.25,
    color: BrandColors.ink,
  );
  static TextStyle get body =>
      TextStyle(fontFamily: _ui, fontSize: 14, color: BrandColors.ink, height: 1.5);
  static TextStyle get bodyMuted =>
      TextStyle(fontFamily: _ui, fontSize: 14, color: BrandColors.inkMuted, height: 1.5);
  static TextStyle get caption =>
      TextStyle(fontFamily: _ui, fontSize: 12, color: BrandColors.inkMuted);
  static const buttonLabel = TextStyle(fontFamily: _ui, fontSize: 16, fontWeight: FontWeight.w500);
  static TextStyle get section => TextStyle(
    fontFamily: _mono,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.2, // .12em
    color: BrandColors.inkMuted,
  );
  static TextStyle get mono =>
      TextStyle(fontFamily: _mono, fontSize: 13, color: BrandColors.inkMuted, fontFeatures: _tnum);
  static TextStyle get amount => TextStyle(
    fontFamily: _mono,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    color: BrandColors.ink,
    fontFeatures: _tnum,
  );
}

/// Material theme built from the brand tokens. Each builder pins [BrandColors]
/// to its own brightness first; the app's `MaterialApp.builder` re-pins per
/// frame for the widget tree.
ThemeData brandLightTheme() => _brandTheme(Brightness.light);
ThemeData brandDarkTheme() => _brandTheme(Brightness.dark);

ThemeData _brandTheme(Brightness brightness) {
  BrandColors.setBrightness(brightness);
  final scheme = ColorScheme.fromSeed(
    seedColor: BrandColors.primary,
    brightness: brightness,
    primary: BrandColors.primary,
    onPrimary: BrandColors.onPrimary,
    secondary: BrandColors.primaryDeep,
    surface: BrandColors.paper,
    onSurface: BrandColors.ink,
    // Pinned, not left to the seed. Material reaches for the inverse pair for
    // SnackBars, tooltips and selection chrome, and `fromSeed` derives it from
    // the primary hue -- which is orange in both apps, so every app got a warm
    // brown chip regardless of the palette's own `inverseSurface`, and a *light*
    // one in dark mode. The palettes define the token; Material should use it.
    inverseSurface: BrandColors.inverseSurface,
    onInverseSurface: BrandColors.onPrimary,
    // The surface *container* ramp, pinned for the same reason. Material 3
    // paints dialogs, menus, chips and bottom sheets from these rather than
    // from [surface], and `fromSeed` tints them from the primary hue -- which
    // is orange in both apps. Skylight's ramp came out byte-identical to
    // Spice's (#FCEAE4, #F6E4DE, #F1DFD9) against a cool #F2F6FA surface, so
    // its Export Logs dialog rendered cream inside a blue app.
    surfaceContainerLowest: BrandColors.paper,
    surfaceContainerLow: BrandColors.card,
    surfaceContainer: BrandColors.surfaceSunken,
    surfaceContainerHigh: BrandColors.surfaceTinted,
    surfaceContainerHighest: BrandColors.surfaceMuted,
    // Secondary text, dividers and outlines on those surfaces.
    onSurfaceVariant: BrandColors.inkMuted,
    outline: BrandColors.border,
    outlineVariant: BrandColors.hairline,
    // Material's default error red is a generic #BA1A1A, not the brand's.
    error: BrandColors.error,
    onError: BrandColors.onPrimary,
    errorContainer: BrandColors.errorBg,
    onErrorContainer: BrandColors.error,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: BrandColors.paper,
    fontFamily: 'Ubuntu',
  );
}
