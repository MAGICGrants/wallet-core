import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Not a real seed: placeholder words, so nothing here is a phrase anyone uses.
const _words = [
  'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', //
  'india', 'juliet', 'kilo', 'lima', 'mike', 'november', 'oscar', 'papa',
];

/// The seed check: random positions, a check against the stored words that
/// leaves nothing behind, wrong tries that survive leaving the screen, and a
/// lock at the third.
void main() {
  late MemorySecretStore secrets;
  final day = DateTime.utc(2026, 10, 19);

  setUp(() {
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    SharedPreferencesService.store = MemoryPreferenceStore();
  });

  tearDown(() {
    WalletSecrets.resetForTesting();
    SharedPreferencesService.resetForTesting();
  });

  /// Each load hands out a fresh list, as reading the seed store does; the
  /// lists are kept so a test can see what was left in them.
  ({SeedVerifier verifier, List<List<String>> loads}) make({int seed = 1}) {
    final loads = <List<String>>[];
    final verifier = SeedVerifier(
      loadWords: () async {
        final words = [..._words];
        loads.add(words);
        return words;
      },
      random: Random(seed),
      clock: () => day,
    );
    return (verifier: verifier, loads: loads);
  }

  List<String> right(SeedVerifier v) => [for (final p in v.positions) _words[p]];
  List<String> wrong(SeedVerifier v) => [for (final _ in v.positions) 'zulu'];

  test('asks for three different positions within the seed, in order', () async {
    for (var seed = 0; seed < 50; seed++) {
      final v = make(seed: seed).verifier;
      expect(await v.start(), isTrue);
      expect(v.positions.length, 3);
      expect(v.positions.toSet().length, 3);
      expect(v.positions, orderedEquals([...v.positions]..sort()));
      expect(v.positions.every((p) => p >= 0 && p < _words.length), isTrue);
    }
  });

  test('uses a secure random generator unless one is given', () async {
    final v = SeedVerifier(loadWords: () async => [..._words]);
    expect(await v.start(), isTrue);
    expect(v.positions.length, 3);
  });

  test('the right words verify, and are recorded with the day', () async {
    final v = make().verifier;
    await v.start();
    expect(await v.check(right(v)), SeedCheckOutcome.verified);
    final state = await SeedCheckStore.read();
    expect(state.isCurrent(day), isTrue);
    expect(state.failures, 0);
  });

  test('case and surrounding spaces do not matter', () async {
    final v = make().verifier;
    await v.start();
    final typed = [for (final w in right(v)) '  ${w.toUpperCase()} '];
    expect(await v.check(typed), SeedCheckOutcome.verified);
  });

  test('the seed is cleared from every list it was read into', () async {
    final m = make();
    await m.verifier.start();
    await m.verifier.check(right(m.verifier));
    await m.verifier.check(wrong(m.verifier));
    expect(m.loads, hasLength(3));
    for (final list in m.loads) {
      expect(list.every((w) => w.isEmpty), isTrue);
    }
  });

  test('a wrong answer asks for other words and counts the try', () async {
    final v = make().verifier;
    await v.start();
    final before = v.positions;
    expect(await v.check(wrong(v)), SeedCheckOutcome.wrong);
    expect(v.positions, isNot(orderedEquals(before)));
    expect(v.triesLeft, 2);
    expect((await SeedCheckStore.read()).failures, 1);
  });

  test('one wrong word among right ones is still wrong', () async {
    final v = make().verifier;
    await v.start();
    final answers = right(v)..[1] = 'zulu';
    expect(await v.check(answers), SeedCheckOutcome.wrong);
  });

  test('the third wrong answer locks, and the count starts over', () async {
    final v = make().verifier;
    await v.start();
    expect(await v.check(wrong(v)), SeedCheckOutcome.wrong);
    expect(await v.check(wrong(v)), SeedCheckOutcome.wrong);
    expect(await v.check(wrong(v)), SeedCheckOutcome.locked);
    expect((await SeedCheckStore.read()).failures, 0);
  });

  test('leaving the screen does not reset the wrong tries', () async {
    final first = make().verifier;
    await first.start();
    await first.check(wrong(first));
    await first.check(wrong(first));

    final again = make(seed: 7).verifier;
    await again.start();
    expect(again.triesLeft, 1);
    expect(await again.check(wrong(again)), SeedCheckOutcome.locked);
  });

  test('a seed that cannot be read at check time is not a wrong try', () async {
    var reads = 0;
    final v = SeedVerifier(
      loadWords: () async => ++reads == 1 ? [..._words] : null,
      random: Random(3),
    );
    await v.start();
    expect(await v.check(right(v)), SeedCheckOutcome.unavailable);
    expect((await SeedCheckStore.read()).failures, 0);
    expect(v.triesLeft, 3);
  });

  test('the lock still comes when the keystore will not save the count', () async {
    WalletSecrets.store = _ReadOnlySecrets();
    final v = make().verifier;
    await v.start();
    expect(await v.check(wrong(v)), SeedCheckOutcome.wrong);
    expect(await v.check(wrong(v)), SeedCheckOutcome.wrong);
    expect(await v.check(wrong(v)), SeedCheckOutcome.locked);
  });

  test('a seed that cannot be read does not start', () async {
    final v = SeedVerifier(loadWords: () async => null);
    expect(await v.start(), isFalse);
  });

  group('SeedVerifyView', () {
    const labels = SeedVerifyLabels(
      title: 'Verify Seed Phrase',
      subtitle: _subtitle,
      verifyButton: 'Verify',
      wrongTitle: "Those words don't match",
      wrongBody: _wrongBody,
      tryAgain: 'Try again',
      unavailable: 'Unavailable',
    );

    Future<({SeedVerifier verifier, List<String> events})> open(WidgetTester tester) async {
      final events = <String>[];
      final verifier = make().verifier;
      await tester.pumpWidget(
        MaterialApp(
          home: SeedVerifyView(
            labels: labels,
            verifier: verifier,
            onVerified: () => events.add('verified'),
            onLocked: () => events.add('locked'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (verifier: verifier, events: events);
    }

    Future<void> answer(WidgetTester tester, List<String> words) async {
      final fields = find.byType(TextField);
      for (var i = 0; i < words.length; i++) {
        await tester.enterText(fields.at(i), words[i]);
      }
      // The button enables on the next frame.
      await tester.pump();
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows only the positions asked for, never a word', (tester) async {
      final o = await open(tester);
      final p = o.verifier.positions;
      expect(find.text('Input words ${p[0] + 1}, ${p[1] + 1} and ${p[2] + 1}.'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      for (final w in _words) {
        expect(find.textContaining(w), findsNothing);
      }
    });

    testWidgets('a wrong answer slides up a notice, then asks for new words', (tester) async {
      final o = await open(tester);
      final before = o.verifier.positions;
      await answer(tester, wrong(o.verifier));

      expect(find.text("Those words don't match"), findsOneWidget);
      expect(find.text('2 left'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text("Those words don't match"), findsNothing);
      expect(o.verifier.positions, isNot(orderedEquals(before)));
      for (final f in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(f.controller!.text, isEmpty, reason: 'the wrong words are cleared');
      }
      expect(o.events, isEmpty);
    });

    testWidgets('the right words verify', (tester) async {
      final o = await open(tester);
      await answer(tester, right(o.verifier));
      expect(o.events, ['verified']);
    });

    testWidgets('embedded, as in the desktop modal, it is the content alone', (tester) async {
      final events = <String>[];
      final verifier = make().verifier;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 480,
                child: SeedVerifyView(
                  labels: labels,
                  verifier: verifier,
                  embedded: true,
                  onVerified: () => events.add('verified'),
                  onLocked: () => events.add('locked'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsOneWidget, reason: 'only the host page');
      expect(find.byType(BrandScreenHeader), findsNothing);
      expect(find.text('Verify Seed Phrase'), findsOneWidget);
      await answer(tester, right(verifier));
      expect(events, ['verified']);
    });

    testWidgets('three wrong answers lock', (tester) async {
      final o = await open(tester);
      for (var i = 0; i < 2; i++) {
        await answer(tester, wrong(o.verifier));
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
      }
      await answer(tester, wrong(o.verifier));
      expect(o.events, ['locked']);
    });
  });
}

class _ReadOnlySecrets extends MemorySecretStore {
  @override
  Future<void> write(String key, String value) async => throw StateError('read only');
}

String _subtitle(List<int> p) => 'Input words ${p[0]}, ${p[1]} and ${p[2]}.';
String _wrongBody(int left) => '$left left';
