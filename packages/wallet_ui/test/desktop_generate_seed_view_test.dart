import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The desktop seed-backup screen is where a desktop user copies down a new
/// seed, so it must show every word in full. These pin that at the smallest
/// window the apps allow (900x640), at larger text sizes, and for a word too
/// wide for any column.
void main() {
  // BIP39 words of the list's longest length, eight letters. Polyseed's English
  // words are the same list.
  const longWords = [
    'abstract',
    'attitude',
    'champion',
    'cupboard',
    'describe',
    'distance',
    'envelope',
    'february',
    'identify',
    'interest',
    'mechanic',
    'mushroom',
    'position',
    'purchase',
    'response',
    'shoulder',
  ];

  Future<void> pumpView(
    WidgetTester tester,
    List<String> words, {
    Size window = const Size(900, 640),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopGenerateSeedView(
          logo: const SizedBox(height: 52),
          title: 'Your seed',
          description: 'Write these words down, in order.',
          seedWords: words,
          birthdayLabel: 'Wallet birthday',
          birthdayReason: 'Where a restore starts scanning',
          birthdayValue: 'October 2026',
          confirmLabel: 'I wrote it down',
          passwordNote: null,
          revealLabel: 'Tap to reveal',
          // Short, because the test font draws every glyph a full em wide:
          // "Continue" would overflow the fixed-width button at 2x text, which
          // the apps' font does not.
          continueText: 'Next',
          step: 4,
          totalSteps: 5,
          onContinue: () {},
        ),
      ),
    );
    await tester.ensureVisible(find.text('Tap to reveal'));
    await tester.tap(find.text('Tap to reveal'));
    await tester.pumpAndSettle();
  }

  RenderParagraph paragraphOf(WidgetTester tester, String word) =>
      tester.renderObject<RenderParagraph>(find.text(word));

  bool onOneLine(RenderParagraph paragraph) =>
      paragraph.getMaxIntrinsicWidth(double.infinity) <= paragraph.size.width;

  for (final textScale in const [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('at the smallest window and ${textScale}x text, every word is whole on one line', (
      tester,
    ) async {
      await pumpView(tester, longWords, textScale: textScale);

      for (final word in longWords) {
        final paragraph = paragraphOf(tester, word);
        expect(paragraph.didExceedMaxLines, isFalse, reason: '"$word" is cut short');
        expect(onOneLine(paragraph), isTrue, reason: '"$word" wraps');
      }
    });
  }

  testWidgets('words that fit sit three to a row', (tester) async {
    const words = [
      'able',
      'acid',
      'also',
      'army',
      'atom',
      'aunt',
      'away',
      'axis',
      'baby',
      'bulb',
      'cage',
      'cart',
      'city',
      'clay',
      'coil',
      'crop',
    ];
    await pumpView(tester, words, window: const Size(1280, 720));

    double top(String word) => tester.getTopLeft(find.text(word)).dy;
    expect(top('acid'), top('able'));
    expect(top('also'), top('able'));
    expect(top('army'), greaterThan(top('able')));
  });

  testWidgets('a word too wide for one column wraps in full, and its cell grows to fit', (
    tester,
  ) async {
    const wide = 'abcdefghijklmnopqrstuvwxyz';
    await pumpView(tester, [wide, ...longWords.skip(1)]);

    final paragraph = paragraphOf(tester, wide);
    expect(onOneLine(paragraph), isFalse, reason: 'the word must be wider than a column');
    expect(paragraph.didExceedMaxLines, isFalse, reason: 'the word is cut short');
    expect(
      tester.getSize(find.text(wide)).height,
      greaterThan(tester.getSize(find.text('attitude')).height),
    );
  });
}
