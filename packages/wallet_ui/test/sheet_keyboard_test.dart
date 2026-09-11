import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Logical pixels of on-screen keyboard to simulate.
const _keyboard = 300.0;

Widget _host() => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showBrandSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => const Padding(
              padding: EdgeInsets.all(20),
              child: TextField(key: Key('field')),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a sheet with a text field stays clear of the keyboard', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final dpr = tester.view.devicePixelRatio;
    final screenHeight = tester.view.physicalSize.height / dpr;
    double fieldBottom() => tester.getBottomLeft(find.byKey(const Key('field'))).dy;

    // No keyboard: the sheet sits against the bottom edge as usual.
    expect(fieldBottom(), greaterThan(screenHeight - _keyboard));

    // Raise the keyboard. `tester.view.viewInsets` is in physical pixels.
    // Without the viewInsets padding in showBrandSheet the sheet does not move,
    // leaving the field behind the keyboard and invisible -- the bug this guards.
    tester.view.viewInsets = FakeViewPadding(bottom: _keyboard * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    expect(
      fieldBottom(),
      lessThanOrEqualTo(screenHeight - _keyboard),
      reason: 'the field must sit above the keyboard, not behind it',
    );
  });
}
