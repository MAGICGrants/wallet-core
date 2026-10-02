import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Tapping the QR, or the hint under it, grows the code in place so a payer's
/// camera can read it from further off. The view only reports the tap; the app
/// owns the state (and whatever else it does then, such as raising brightness).
const _enlarge = 'Tap to enlarge and brighten';
const _shrink = 'Tap to shrink';
// Found with find.textContaining: the hint's icon is an inline span in its text.

// A Monero subaddress: the longest address the view shows, so the densest QR.
const _address =
    '86sKbrPqWd3zN7vH2mLjT5xFcY9gA4eR1uQ8oBkXwZ6nV3iJpS7tD2hC5fM9aG4yE1rL8qU6bW3xK7zN2vT5jH9dP4sF1';

/// Hosts the view with its enlarge state held here, as an app would hold it.
class _Host extends StatefulWidget {
  final bool toggleable;
  final void Function()? onToggled;

  const _Host({this.toggleable = true, this.onToggled});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  var enlarged = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: ReceiveView(
      labels: const ReceiveLabels(
        title: 'Receive',
        copyAddress: 'Copy address',
        enlargeQr: _enlarge,
        shrinkQr: _shrink,
      ),
      onBack: () {},
      ready: true,
      coinSymbol: 'XMR',
      iconAsset: 'assets/icons/monero.svg',
      // Null so the card (and its SVG) stays out of the widget test.
      coinName: null,
      blockchainSubtitle: null,
      tabLabels: const ['Subaddress', 'Primary address'],
      address: _address,
      qrHeading: 'Subaddress #3',
      onCopy: () {},
      qrEnlarged: enlarged,
      onToggleQr: widget.toggleable
          ? () {
              setState(() => enlarged = !enlarged);
              widget.onToggled?.call();
            }
          : null,
    ),
  );
}

/// A phone-shaped surface, in logical pixels.
void _useScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Size _qrSize(WidgetTester tester) => tester.getSize(find.byType(QrImageView));

void main() {
  testWidgets('the QR itself toggles the enlarge state', (tester) async {
    _useScreen(tester, const Size(375, 812));
    var toggles = 0;
    await tester.pumpWidget(_Host(onToggled: () => toggles++));

    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(find.textContaining(_shrink), findsOneWidget);

    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();
    expect(toggles, 2);
    expect(find.textContaining(_enlarge), findsOneWidget);
  });

  testWidgets('the hint text toggles it too, and says what the next tap does', (tester) async {
    _useScreen(tester, const Size(375, 812));
    var toggles = 0;
    await tester.pumpWidget(_Host(onToggled: () => toggles++));

    expect(find.textContaining(_enlarge), findsOneWidget);
    await tester.tap(find.textContaining(_enlarge));
    await tester.pumpAndSettle();
    expect(toggles, 1);

    expect(find.textContaining(_shrink), findsOneWidget);
    await tester.tap(find.textContaining(_shrink));
    await tester.pumpAndSettle();
    expect(toggles, 2);
    expect(find.textContaining(_enlarge), findsOneWidget);
  });

  testWidgets('an enlarged QR fills the card\'s width on a phone', (tester) async {
    _useScreen(tester, const Size(375, 812));
    await tester.pumpWidget(const _Host());
    expect(_qrSize(tester), const Size.square(200));

    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();

    // 375 wide, less the list gutters (16 each side), the card border (1) and
    // enlarged padding (12), less the proportional quiet zone: floor(317/1.1).
    expect(_qrSize(tester), const Size.square(288));
    expect(tester.takeException(), isNull, reason: 'no overflow at full size');

    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();
    expect(_qrSize(tester), const Size.square(200), reason: 'shrinks back');
  });

  testWidgets('in landscape it stops at the viewport\'s height, all of it on screen', (
    tester,
  ) async {
    _useScreen(tester, const Size(812, 375));
    await tester.pumpWidget(const _Host());

    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();

    final qr = tester.getRect(find.byType(QrImageView));
    final list = tester.getRect(find.byType(ListView));
    expect(qr.width, greaterThan(200));
    expect(qr.height, lessThan(list.height), reason: 'capped by height, not width');
    // Scrolled into view after growing, rather than left hanging off the bottom.
    expect(qr.top, greaterThanOrEqualTo(list.top));
    expect(qr.bottom, lessThanOrEqualTo(list.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the quiet zone grows with the code', (tester) async {
    _useScreen(tester, const Size(375, 812));
    await tester.pumpWidget(const _Host());

    double margin() {
      final panel = tester.getRect(
        find.ancestor(of: find.byType(QrImageView), matching: find.byType(AnimatedContainer)),
      );
      return tester.getRect(find.byType(QrImageView)).left - panel.left;
    }

    expect(margin(), 10, reason: 'unchanged at the normal size');
    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();
    // 5% of the side, in whole pixels: 14 at 288.
    expect(margin(), (_qrSize(tester).width * 0.05).floorToDouble());
    expect(margin(), greaterThan(10));
  });

  testWidgets('a null onToggleQr keeps the QR fixed and hides the hint', (tester) async {
    _useScreen(tester, const Size(375, 812));
    await tester.pumpWidget(const _Host(toggleable: false));

    expect(find.textContaining(_enlarge), findsNothing);
    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();
    expect(_qrSize(tester), const Size.square(200));
  });

  testWidgets('switching address tabs while enlarged keeps it enlarged', (tester) async {
    _useScreen(tester, const Size(375, 812));
    await tester.pumpWidget(const _Host());

    await tester.tap(find.byType(QrImageView));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Primary address'));
    await tester.pumpAndSettle();

    expect(_qrSize(tester), const Size.square(288));
    expect(find.textContaining(_shrink), findsOneWidget);
  });
}
