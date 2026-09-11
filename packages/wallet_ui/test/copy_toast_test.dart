import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart' show SecureClipboard;
import 'package:wallet_ui/wallet_ui.dart';

Widget _host() => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showCopyToast(context, 'Copied to clipboard'),
          child: const Text('copy'),
        ),
      ),
    ),
  ),
);

void main() {
  tearDown(() => SecureClipboard.systemConfirmsCopyForTesting = null);

  testWidgets('shows the toast where the platform confirms nothing', (tester) async {
    SecureClipboard.systemConfirmsCopyForTesting = false;
    await tester.pumpWidget(_host());
    await tester.tap(find.text('copy'));
    await tester.pumpAndSettle();

    expect(find.text('Copied to clipboard'), findsOneWidget);
  });

  testWidgets('stays silent where the platform shows its own confirmation', (tester) async {
    // Android 13+: the OS already showed a "Copied" pill, so a second one would
    // tell the user the same thing twice in two different shapes.
    SecureClipboard.systemConfirmsCopyForTesting = true;
    await tester.pumpWidget(_host());
    await tester.tap(find.text('copy'));
    await tester.pumpAndSettle();

    expect(find.text('Copied to clipboard'), findsNothing);
  });
}
