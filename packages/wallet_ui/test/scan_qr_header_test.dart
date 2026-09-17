import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The scanner's title pill floats over the camera next to the back button, so
/// the two have to be the same surface. They are only the same surface if they
/// read the same tokens: the pill used to be an `inverseSurface`/`onPrimary`
/// chip, which came out inverted against the button in both apps' light themes
/// and a shade off it in both dark ones.
///
/// Every token in the probe palette is a distinct colour, so a pill wired back
/// to the wrong token cannot coincidentally match the button.
BrandPalette _probe(int seed) {
  var n = 0;
  (int, int) next() {
    n++;
    return (0xFF000000 | (seed + n * 0x010203), 0xFF000000 | (0x800000 + seed + n * 0x010203));
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

// One palette per app, each in both brightnesses: the four themes the header
// has to hold up in.
const _palettes = {'spice-like': 0x000000, 'skylight-like': 0x0A1428};

void main() {
  for (final palette in _palettes.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('scanner title matches the back button (${palette.key}, ${brightness.name})', (
        tester,
      ) async {
        BrandColors.install(_probe(palette.value));
        BrandColors.setBrightness(brightness);

        await tester.pumpWidget(
          MaterialApp(
            home: ScanQrView(title: 'Scan QR', onResult: (_) {}, onBack: () {}),
          ),
        );

        // The back button: a card-filled circle with a hairline border and an
        // ink icon.
        final button = tester.widget<Material>(
          find.descendant(of: find.byType(IconCircleButton), matching: find.byType(Material)),
        );
        final buttonBorder = (button.shape! as CircleBorder).side;
        final buttonIcon = tester.widget<Icon>(
          find.descendant(of: find.byType(IconCircleButton), matching: find.byType(Icon)),
        );

        // The title pill.
        final pill = tester.widget<Container>(
          find.ancestor(of: find.text('Scan QR'), matching: find.byType(Container)).first,
        );
        final decoration = pill.decoration! as BoxDecoration;
        final pillText = tester.widget<Text>(find.text('Scan QR'));

        expect(decoration.color, button.color, reason: 'pill fill vs back-button fill');
        expect(decoration.border!.top.color, buttonBorder.color, reason: 'pill vs button border');
        expect(pillText.style!.color, buttonIcon.color, reason: 'title text vs back-button icon');

        // And they are the shared surface tokens, not a matching pair of
        // hard-coded colours.
        expect(button.color, BrandColors.card);
        expect(buttonIcon.color, BrandColors.ink);
        expect(buttonBorder.color, BrandColors.border);
      });
    }
  }
}
