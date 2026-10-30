import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// App Lock over the app rather than on its stack: a screen under it that
/// finishes something after the return and pops itself must not take App Lock
/// with it.
void main() {
  late ValueNotifier<bool> shown;
  late GlobalKey<NavigatorState> navigator;
  late BuildContext coveredContext;

  setUp(() {
    shown = ValueNotifier(false);
    navigator = GlobalKey<NavigatorState>();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => AppLockCover(
          shown: shown,
          cover: (context) => Scaffold(
            body: Column(
              children: [
                const Text('App Lock'),
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const Text('recovery phrase sheet'),
                  ),
                  child: const Text('use recovery phrase'),
                ),
              ],
            ),
          ),
          child: child!,
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          coveredContext = context;
          return const Scaffold(body: TextField(autofocus: true));
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a covered screen popping itself leaves App Lock up', (tester) async {
    await pumpApp(tester);
    shown.value = true;
    await tester.pumpAndSettle();
    expect(find.text('App Lock'), findsOneWidget);

    // A send that finishes after the return.
    Navigator.of(coveredContext).pop();
    await tester.pumpAndSettle();

    expect(find.text('App Lock'), findsOneWidget);
    expect(
      navigator.currentState!.canPop(),
      isFalse,
      reason: 'the pop took the screen, not App Lock',
    );

    shown.value = false;
    await tester.pumpAndSettle();
    expect(find.text('App Lock'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('the app under it takes no focus or taps', (tester) async {
    await pumpApp(tester);
    final field = find.byType(TextField);
    bool fieldFocused() =>
        tester.state<EditableTextState>(find.byType(EditableText)).widget.focusNode.hasFocus;
    expect(fieldFocused(), isTrue);

    shown.value = true;
    await tester.pumpAndSettle();
    expect(fieldFocused(), isFalse);
    expect(field.hitTestable(), findsNothing);
  });

  testWidgets('the cover opens sheets on a navigator of its own', (tester) async {
    await pumpApp(tester);
    shown.value = true;
    await tester.pumpAndSettle();

    await tester.tap(find.text('use recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text('recovery phrase sheet'), findsOneWidget);
    expect(navigator.currentState!.canPop(), isTrue, reason: "nothing was pushed on the app's own");
  });
}
