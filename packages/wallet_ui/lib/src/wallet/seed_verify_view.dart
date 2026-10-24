import 'dart:math';

import 'package:flutter/material.dart';
import 'package:wallet_domain/wallet_domain.dart' show SeedCheckStore;

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_screen_header.dart';
import '../design/notice_sheet.dart';
import '../design/seed_grid.dart';
import '../onboarding/seed_word_slot.dart';

/// The outcome of one try at [SeedVerifier.check]. [unavailable] means the
/// seed could not be read to compare against, which is not counted as a wrong
/// try.
enum SeedCheckOutcome { verified, wrong, locked, unavailable }

/// Asks for a few words of the seed phrase at random positions and checks them
/// against the wallet's seed, without ever showing the seed.
///
/// The seed is read through [loadWords] only for the moment of a check (and
/// once at the start, for its length) and the list is cleared right after;
/// the words never reach the screen, a log or storage. Wrong tries are counted
/// in [SeedCheckStore], so leaving the screen does not reset them; at
/// [maxFailures] the outcome is [SeedCheckOutcome.locked] and the caller locks
/// the app.
class SeedVerifier {
  SeedVerifier({
    required this.loadWords,
    this.wordsAsked = 3,
    this.maxFailures = 3,
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  /// The wallet's seed words, in order; null when the seed cannot be read.
  final Future<List<String>?> Function() loadWords;
  final int wordsAsked;
  final int maxFailures;
  final Random _random;
  final DateTime Function() _clock;

  int _wordCount = 0;
  int _failures = 0;
  List<int> _positions = const [];

  /// Zero-based positions of the words asked for now, in order.
  List<int> get positions => _positions;

  /// Wrong tries left before the app locks.
  int get triesLeft => maxFailures - _failures;

  /// Reads the seed's length and the wrong tries so far, and picks the first
  /// positions. False when the seed cannot be read.
  Future<bool> start() async {
    final words = await loadWords();
    if (words == null || words.length < wordsAsked) return false;
    _wordCount = words.length;
    _clear(words);
    _failures = (await SeedCheckStore.read()).failures;
    _pick();
    return true;
  }

  /// Checks [answers], one typed word per entry of [positions].
  Future<SeedCheckOutcome> check(List<String> answers) async {
    final words = await loadWords();
    if (words == null || words.length != _wordCount) {
      if (words != null) _clear(words);
      return SeedCheckOutcome.unavailable;
    }
    var right = answers.length == _positions.length;
    if (right) {
      for (var i = 0; i < _positions.length; i++) {
        if (_normalize(answers[i]) != _normalize(words[_positions[i]])) right = false;
      }
    }
    _clear(words);

    if (right) {
      await SeedCheckStore.markVerified(_clock());
      _failures = 0;
      return SeedCheckOutcome.verified;
    }
    // The count held here as well as the stored one, so a keystore that will
    // not take the write cannot hold the count below the lock.
    _failures = max(_failures + 1, await SeedCheckStore.recordFailure());
    if (_failures >= maxFailures) {
      await SeedCheckStore.resetFailures();
      _failures = 0;
      return SeedCheckOutcome.locked;
    }
    _pick();
    return SeedCheckOutcome.wrong;
  }

  /// New random positions, never the same set as the last.
  void _pick() {
    final previous = _positions;
    List<int> next;
    do {
      final chosen = <int>{};
      while (chosen.length < wordsAsked) {
        chosen.add(_random.nextInt(_wordCount));
      }
      next = chosen.toList()..sort();
    } while (_wordCount > wordsAsked && _same(next, previous));
    _positions = next;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _normalize(String word) => word.trim().toLowerCase();

  /// Drops the words from the list the caller handed over. Dart strings
  /// cannot be overwritten, but nothing keeps a reference to them after this.
  static void _clear(List<String> words) {
    try {
      words.fillRange(0, words.length, '');
    } on UnsupportedError {
      // A fixed or unmodifiable list: nothing to clear in place.
    }
  }
}

/// Translated strings for [SeedVerifyView].
class SeedVerifyLabels {
  final String title;

  /// "Input words 3, 9 and 14 of your seed phrase below." One-based.
  final String Function(List<int> positions) subtitle;
  final String verifyButton;
  final String wrongTitle;

  /// "Three other words are asked for now. 2 tries left before the app locks."
  final String Function(int triesLeft) wrongBody;
  final String tryAgain;

  /// Shown when the seed cannot be read.
  final String unavailable;

  const SeedVerifyLabels({
    required this.title,
    required this.subtitle,
    required this.verifyButton,
    required this.wrongTitle,
    required this.wrongBody,
    required this.tryAgain,
    required this.unavailable,
  });
}

/// The seed check page: the restore screen's word slots, but only the few
/// [SeedVerifier] asks for, and no words shown anywhere.
///
/// A wrong answer slides up a notice and asks for other words; the last wrong
/// answer calls [onLocked] instead, even if the page has been closed by then,
/// so the app binds that callback up front ([onLocked] must not need this
/// page's context). [onVerified] runs after a correct answer.
class SeedVerifyView extends StatefulWidget {
  final SeedVerifyLabels labels;
  final SeedVerifier verifier;
  final VoidCallback onVerified;
  final VoidCallback onLocked;

  /// Content only, for the desktop's centered modal: no page, header or back
  /// button (the modal has its own close).
  final bool embedded;

  const SeedVerifyView({
    super.key,
    required this.labels,
    required this.verifier,
    required this.onVerified,
    required this.onLocked,
    this.embedded = false,
  });

  @override
  State<SeedVerifyView> createState() => _SeedVerifyViewState();
}

class _SeedVerifyViewState extends State<SeedVerifyView> {
  late final List<TextEditingController> _controllers = List.generate(
    widget.verifier.wordsAsked,
    (_) => TextEditingController(),
  );
  late final List<FocusNode> _nodes = List.generate(widget.verifier.wordsAsked, (_) => FocusNode());

  bool? _ready;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final ok = await widget.verifier.start();
    if (!mounted) return;
    setState(() => _ready = ok);
    if (ok) _nodes.first.requestFocus();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.clear();
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  bool get _filled => _controllers.every((c) => c.text.trim().isNotEmpty);

  Future<void> _verify() async {
    if (_checking || !_filled) return;
    setState(() => _checking = true);
    final outcome = await widget.verifier.check([for (final c in _controllers) c.text]);
    // The lock goes ahead even if the page is gone by now; the app binds it
    // before the check starts.
    if (outcome == SeedCheckOutcome.locked) {
      widget.onLocked();
      if (mounted) setState(() => _checking = false);
      return;
    }
    if (!mounted) return;
    for (final c in _controllers) {
      c.clear();
    }
    setState(() => _checking = false);
    switch (outcome) {
      case SeedCheckOutcome.verified:
        widget.onVerified();
      case SeedCheckOutcome.locked:
        break;
      case SeedCheckOutcome.unavailable:
        setState(() => _ready = false);
      case SeedCheckOutcome.wrong:
        FocusManager.instance.primaryFocus?.unfocus();
        await showNoticeSheet(
          context: context,
          icon: Icons.error_outline,
          iconBg: BrandColors.errorBg,
          iconColor: BrandColors.error,
          title: widget.labels.wrongTitle,
          body: widget.labels.wrongBody(widget.verifier.triesLeft),
          closeLabel: widget.labels.tryAgain,
        );
        if (mounted) _nodes.first.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final positions = widget.verifier.positions;
    final cols = seedGridColumns(context);

    final List<Widget> content;
    if (_ready == null) {
      content = [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    } else if (_ready == false) {
      content = [Text(labels.unavailable, style: BrandText.bodyMuted)];
    } else {
      content = [
        Text(labels.subtitle([for (final p in positions) p + 1]), style: BrandText.bodyMuted),
        const SizedBox(height: BrandSpacing.lg),
        for (var r = 0; r * cols < positions.length; r++) ...[
          if (r > 0) const SizedBox(height: 9),
          Row(
            children: [
              for (var c = 0; c < cols; c++) ...[
                if (c > 0) const SizedBox(width: 9),
                Expanded(
                  child: r * cols + c < positions.length
                      ? _slot(r * cols + c, positions[r * cols + c])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ];
    }

    final button = _ready == true
        ? ListenableBuilder(
            listenable: Listenable.merge(_controllers),
            builder: (context, _) => BrandButton(
              label: labels.verifyButton,
              loading: _checking,
              onPressed: (!_checking && _filled) ? _verify : null,
            ),
          )
        : null;

    final Widget view;
    if (widget.embedded) {
      view = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(labels.title, style: BrandText.sheetTitle),
          const SizedBox(height: BrandSpacing.md),
          ...content,
          if (button != null) ...[const SizedBox(height: BrandSpacing.xl), button],
        ],
      );
    } else {
      view = Scaffold(
        backgroundColor: BrandColors.paper,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: BrandSpacing.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: BrandSpacing.sm),
                    BrandScreenHeader(
                      onBack: () {
                        if (!_checking) Navigator.maybePop(context);
                      },
                      center: Text(labels.title, style: BrandText.appBar),
                    ),
                    const SizedBox(height: BrandSpacing.lg),
                    Expanded(child: ListView(children: content)),
                    const SizedBox(height: BrandSpacing.md),
                    ?button,
                    const SizedBox(height: BrandSpacing.sm),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // No leaving while a check runs: the answer must reach the wrong-try
    // count and, at the last try, the lock.
    return PopScope(canPop: !_checking, child: view);
  }

  Widget _slot(int i, int position) {
    return SeedWordSlot(
      // Keyed on the position so a new set of words gets fresh slots.
      key: ValueKey('$i-$position'),
      index: position + 1,
      controller: _controllers[i],
      focusNode: _nodes[i],
      validate: (_) => true,
      isLast: i == _controllers.length - 1,
      onChanged: (_) {},
      onSubmitted: () {
        if (i + 1 < _nodes.length) {
          _nodes[i + 1].requestFocus();
        } else {
          _verify();
        }
      },
    );
  }
}
