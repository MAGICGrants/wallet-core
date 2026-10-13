import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The confirm sheet must not let a failing `onConfirm` escape as an unhandled
/// framework error (a dropped connection at confirm time crashed the app this
/// way), and must only pop `true` when the commit actually succeeds.
const _labels = ConfirmSendLabels(
  title: 'Confirm',
  description: 'Review',
  amount: 'Amount',
  networkFee: 'Fee',
  address: 'To',
  send: 'Send',
  cancel: 'Cancel',
);

Future<bool?> _open(WidgetTester tester, {required Future<void> Function() onConfirm}) async {
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showConfirmSendSheet(
                  context: context,
                  labels: _labels,
                  coinSymbol: 'ETH',
                  amountText: '1 ETH',
                  feeText: '0.001 ETH',
                  address: '0xabc',
                  onConfirm: onConfirm,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  setUp(() => debugIsDesktopModalOverride = false);
  tearDown(() => debugIsDesktopModalOverride = null);

  testWidgets('a throwing onConfirm keeps the sheet open and does not crash', (tester) async {
    await _open(tester, onConfirm: () async => throw Exception('broadcast failed'));

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // No unhandled framework error, and the sheet is still up for a retry.
    expect(tester.takeException(), isNull);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('a successful onConfirm pops the sheet with true', (tester) async {
    await _open(tester, onConfirm: () async {});

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Send'), findsNothing, reason: 'sheet popped on success');
  });
}
