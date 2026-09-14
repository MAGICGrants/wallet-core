import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// iOS anchors the share sheet to the control that opened it, and share_plus
/// rejects a share whose `sharePositionOrigin` is missing or empty. Because
/// nothing awaits that share, a rejection is silent: the header's share button
/// simply does nothing. So the view has to hand the callback a usable rect --
/// the button's own, not the screen's.
Widget _harness({required ValueChanged<Rect?>? onShare, bool ready = true}) => MaterialApp(
  home: ReceiveView(
    labels: const ReceiveLabels(title: 'Receive', copyAddress: 'Copy address'),
    onBack: () {},
    onShare: onShare,
    ready: ready,
    coinSymbol: 'XMR',
    iconAsset: 'assets/icons/monero.svg',
    // Null so the card (and its SVG) stays out of the widget test.
    coinName: null,
    blockchainSubtitle: null,
    address:
        '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge',
    qrHeading: 'Subaddress #1',
    onCopy: () {},
  ),
);

void main() {
  testWidgets('the share callback gets the share button\'s own rect', (tester) async {
    Rect? captured;
    var calls = 0;

    await tester.pumpWidget(
      _harness(
        onShare: (origin) {
          captured = origin;
          calls++;
        },
      ),
    );

    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pump();

    expect(calls, 1);

    // Non-empty, or the plugin rejects the share.
    expect(captured, isNotNull);
    expect(captured!.isEmpty, isFalse);

    // The button's rect, not the whole screen's: a popover anchored to the
    // screen would point at nothing in particular.
    final screen = tester.getRect(find.byType(MaterialApp));
    expect(screen.contains(captured!.topLeft), isTrue);
    expect(screen.contains(captured!.bottomRight), isTrue);
    expect(captured!.width, lessThan(screen.width));
    expect(captured!.height, lessThan(screen.height));

    // And it is the rect of the button the user actually tapped -- its whole
    // 44pt tap target, not just the 36pt circle drawn inside it.
    expect(captured, tester.getRect(_shareButton));
  });

  testWidgets('no share button until the address resolves', (tester) async {
    await tester.pumpWidget(_harness(onShare: (_) {}, ready: false));
    expect(tester.widget<IconCircleButton>(_shareButton).onPressed, isNull);
  });

  testWidgets('a null onShare hides the share button', (tester) async {
    await tester.pumpWidget(_harness(onShare: null));
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });
}

final _shareButton = find.ancestor(
  of: find.byIcon(Icons.ios_share),
  matching: find.byType(IconCircleButton),
);
