import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The desktop home's arrangement: the side card beside the wide column when
/// there is room, under it when not, and the wide column alone once the side
/// card is gone.
void main() {
  Widget card(String name, {double height = 80}) =>
      SizedBox(key: ValueKey(name), height: height, child: Text(name));

  Future<void> show(
    WidgetTester tester, {
    required double width,
    Widget? side,
    List<Widget> full = const [],
  }) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopHomeLayout(
            balance: const Text('balance'),
            actions: DesktopHomeActions(
              receiveLabel: 'Receive',
              sendLabel: 'Send',
              swapLabel: 'Swap',
              onReceive: () {},
              onSend: () {},
              onSwap: () {},
            ),
            status: const Text('Synced'),
            wide: [card('incoming'), card('chart')],
            side: side,
            full: full,
          ),
        ),
      ),
    );
  }

  Rect rectOf(WidgetTester tester, String name) => tester.getRect(find.byKey(ValueKey(name)));

  testWidgets('the side card sits beside the wide column', (tester) async {
    await show(tester, width: 1100, side: card('checklist'));
    final incoming = rectOf(tester, 'incoming');
    final checklist = rectOf(tester, 'checklist');
    expect(checklist.top, incoming.top);
    expect(checklist.left, greaterThan(incoming.right));
    expect(incoming.width, greaterThan(checklist.width));
    expect(rectOf(tester, 'chart').top, greaterThan(incoming.bottom));
  });

  testWidgets('a narrow window puts the side card underneath', (tester) async {
    await show(tester, width: 640, side: card('checklist'));
    final chart = rectOf(tester, 'chart');
    final checklist = rectOf(tester, 'checklist');
    expect(checklist.top, greaterThan(chart.bottom));
    expect(checklist.width, chart.width);
  });

  testWidgets('without a side card the wide column takes the whole width', (tester) async {
    await show(tester, width: 1100, full: [card('full')]);
    final incoming = rectOf(tester, 'incoming');
    final full = rectOf(tester, 'full');
    expect(incoming.width, full.width);
    expect(full.top, greaterThan(rectOf(tester, 'chart').bottom));
  });

  testWidgets('the status sits above the balance, the actions beside it', (tester) async {
    await show(tester, width: 1100);
    final status = tester.getRect(find.text('Synced'));
    final balance = tester.getRect(find.text('balance'));
    final send = tester.getRect(find.text('Send'));
    expect(status.bottom, lessThanOrEqualTo(balance.top));
    expect(send.left, greaterThan(balance.right));
    expect(find.text('Receive'), findsOneWidget);
    expect(find.text('Swap'), findsOneWidget);
  });
}
