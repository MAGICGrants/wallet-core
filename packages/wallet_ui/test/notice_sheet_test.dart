import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// A notice is a bottom sheet on a phone and the centered modal on desktop,
/// and its one button closes it.
void main() {
  tearDown(() => debugIsDesktopModalOverride = null);

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showNoticeSheet(
                  context: context,
                  icon: Icons.cloud_off_outlined,
                  title: 'No backup found',
                  body: 'No backup of this wallet in iCloud.',
                  closeLabel: 'OK',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('on a phone: a bottom sheet with a labelled close button', (tester) async {
    debugIsDesktopModalOverride = false;
    await open(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(SheetHandle), findsOneWidget);
    expect(find.text('No backup found'), findsOneWidget);
    expect(find.text('No backup of this wallet in iCloud.'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('on desktop: the centered modal card', (tester) async {
    debugIsDesktopModalOverride = true;
    await open(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(DesktopModalCard), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopModalCard), findsNothing);
  });
}
