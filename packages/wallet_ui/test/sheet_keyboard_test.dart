import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Logical pixels of on-screen keyboard and of top safe area to simulate.
/// `FakeViewPadding` takes physical pixels, hence the `* dpr` at every call.
const _keyboard = 150.0;
const _topInset = 59.0;

Widget _host({required WidgetBuilder sheet}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () =>
              showBrandSheet<void>(context: context, isScrollControlled: true, builder: sheet),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  // These assert the mobile bottom-sheet path; force it on the desktop test host.
  setUp(() => debugIsDesktopModalOverride = false);
  tearDown(() => debugIsDesktopModalOverride = null);

  testWidgets('a sheet with a text field sits on the keyboard, not above it', (tester) async {
    final dpr = tester.view.devicePixelRatio;
    final screenHeight = tester.view.physicalSize.height / dpr;

    await tester.pumpWidget(
      _host(
        sheet: (_) => const Padding(
          padding: EdgeInsets.all(20),
          child: TextField(key: Key('field')),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    double sheetBottom() => tester.getBottomLeft(find.byKey(const Key('field'))).dy + 20;

    // No keyboard: the sheet sits against the bottom edge as usual.
    expect(sheetBottom(), moreOrLessEquals(screenHeight, epsilon: 1));

    tester.view.viewInsets = FakeViewPadding(bottom: _keyboard * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    // Exactly one keyboard height, not two. `showBrandSheet` owns the inset, and
    // a sheet body that adds its own as well floats a whole keyboard clear of
    // the keyboard -- a void beneath it, its top off the screen. The old
    // `lessThanOrEqualTo` assertion let that through, which is how it shipped.
    expect(
      sheetBottom(),
      moreOrLessEquals(screenHeight - _keyboard, epsilon: 1),
      reason: 'the sheet must sit on the keyboard, not a keyboard-height above it',
    );
  });

  testWidgets('a sheet that asks for more room than there is stops at the safe area', (
    tester,
  ) async {
    final dpr = tester.view.devicePixelRatio;
    final screenHeight = tester.view.physicalSize.height / dpr;

    tester.view.padding = FakeViewPadding(top: _topInset * dpr);
    tester.view.viewPadding = FakeViewPadding(top: _topInset * dpr);
    tester.view.viewInsets = FakeViewPadding(bottom: _keyboard * dpr);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        sheet: (context) => ConstrainedBox(
          // More rows than fit, the way a contact sheet with every coin does.
          constraints: BoxConstraints(maxHeight: maxSheetHeight(context)),
          child: ListView(
            key: const Key('list'),
            children: [for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('row $i'))],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final top = tester.getTopLeft(find.byKey(const Key('list'))).dy;
    final bottom = tester.getBottomLeft(find.byKey(const Key('list'))).dy;

    expect(top, greaterThanOrEqualTo(_topInset - 1), reason: 'the sheet ran under the status bar');
    expect(
      bottom,
      moreOrLessEquals(screenHeight - _keyboard, epsilon: 1),
      reason: 'the sheet must end where the keyboard begins',
    );
  });
}
