import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

Widget _host(void Function(BuildContext) onOpen) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(onPressed: () => onOpen(context), child: const Text('open')),
      ),
    ),
  ),
);

void _open(BuildContext context, {required VoidCallback onConfirm}) => showConfirmSheet(
  context: context,
  icon: Icons.delete_outline,
  iconBg: const Color(0xFFFFE9E9),
  iconColor: const Color(0xFFD32F2F),
  title: 'Delete Wallet',
  body: 'Are you sure? You will lose access to your funds.',
  confirmLabel: 'Delete',
  cancelLabel: 'Cancel',
  onConfirm: onConfirm,
);

void main() {
  testWidgets('renders injected labels and fires onConfirm on the ghost action', (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(_host((context) => _open(context, onConfirm: () => confirmed++)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Wallet'), findsOneWidget);
    expect(find.text('Are you sure? You will lose access to your funds.'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(confirmed, 1);
    // The sheet pops itself before running onConfirm.
    expect(find.text('Delete Wallet'), findsNothing);
  });

  testWidgets('cancel dismisses without confirming', (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(_host((context) => _open(context, onConfirm: () => confirmed++)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(confirmed, 0);
    expect(find.text('Delete Wallet'), findsNothing);
  });
}
