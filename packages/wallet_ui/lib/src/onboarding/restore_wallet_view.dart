import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_screen_header.dart';
import '../design/brand_segmented.dart';
import '../design/icon_circle_button.dart';
import '../design/seed_grid.dart';
import '../design/section_header.dart';
import '../design/step_dots.dart';

/// One selectable seed format in the restore screen. Drives how many word slots
/// the grid shows and (optionally) per-word validation.
///
/// [fixedWordCount] pins the grid length (16 polyseed, 25 legacy). When null the
/// option is variable-length and [lengthOptions] populates an inline length
/// selector (bip39: 12/15/18/21/24), starting at [defaultLength]. [isValidWord]
/// flags out-of-wordlist words in red (bip39); null disables per-word checks.
/// [suggestWord] powers the optional "did you mean" hint for a bad word.
class SeedTypeOption {
  final String id;
  final String label;
  final int? fixedWordCount;
  final List<int>? lengthOptions;
  final int? defaultLength;
  final bool Function(String word)? isValidWord;
  final String? Function(String word)? suggestWord;

  /// Whole-phrase check run once every slot holds a valid word — returns an
  /// error message to show (and block restore), or null when the phrase is good.
  /// Used for bip39's checksum. Null skips the check.
  final String? Function(String mnemonic)? mnemonicError;

  const SeedTypeOption({
    required this.id,
    required this.label,
    this.fixedWordCount,
    this.lengthOptions,
    this.defaultLength,
    this.isValidWord,
    this.suggestWord,
    this.mnemonicError,
  });

  /// Initial slot count when the option is selected.
  int get initialLength => fixedWordCount ?? defaultLength ?? (lengthOptions?.first ?? 12);
}

/// Translated strings for [RestoreWalletView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class RestoreWalletLabels {
  final String title;
  final String subtitle;
  final String seedLength;
  final String paste;
  final String restoreButton;
  final String Function(int position) badWord;
  final String Function(String word) didYouMean;

  const RestoreWalletLabels({
    required this.title,
    required this.subtitle,
    required this.seedLength,
    required this.paste,
    required this.restoreButton,
    required this.badWord,
    required this.didYouMean,
  });
}

/// Lets the app push words into the grid (e.g. from a QR scan) without owning
/// the controllers. Attach with [RestoreWalletView.controller]; call [setWords].
class RestoreWalletController {
  _RestoreWalletViewState? _state;

  /// Replaces the grid contents; adjusts the selected length to fit when the
  /// active type is variable and [words] matches one of its length options.
  void setWords(List<String> words) => _state?._setWords(words);

  void _attach(_RestoreWalletViewState s) => _state = s;
  void _detach(_RestoreWalletViewState s) {
    if (_state == s) _state = null;
  }
}

/// Shared restore-wallet onboarding step. A seed-type selector (hidden when only
/// one type is supplied — the Spice case) drives an adaptive per-word grid; an
/// injected [restorePointFields] slot below the grid carries each app's own
/// restore-height/date UI. Per-word bad-word highlighting runs only for types
/// with an [SeedTypeOption.isValidWord]. [onRestore] receives the space-joined
/// words plus the selected type id; the app validates and restores using its own
/// restore-point state.
///
/// Presentational: owns word controllers, selected type and (bip39) length; the
/// app supplies strings, the restore-point widget and callbacks. StepDots show
/// only when [stepCount]/[stepIndex] are both set (otherwise a plain title).
class RestoreWalletView extends StatefulWidget {
  final RestoreWalletLabels labels;
  final List<SeedTypeOption> seedTypes;
  final Widget restorePointFields;
  final VoidCallback? onScan;
  final ValueChanged<String>? onSeedTypeChanged;
  final void Function(String mnemonic, String seedTypeId) onRestore;

  /// Extra gate the app can add on top of "all slots filled / valid" (e.g. Spice
  /// requires the scan-from date to be chosen). Null means always allowed.
  final bool Function()? canRestore;
  final bool restoring;
  final RestoreWalletController? controller;
  final int? stepCount;
  final int? stepIndex;

  const RestoreWalletView({
    super.key,
    required this.labels,
    required this.seedTypes,
    required this.restorePointFields,
    required this.onRestore,
    this.onScan,
    this.onSeedTypeChanged,
    this.canRestore,
    this.restoring = false,
    this.controller,
    this.stepCount,
    this.stepIndex,
  });

  @override
  State<RestoreWalletView> createState() => _RestoreWalletViewState();
}

class _RestoreWalletViewState extends State<RestoreWalletView> {
  // Allocated at the max slot count so changing type/length never disposes or
  // creates controllers mid-tree; slots past [_count] just aren't shown.
  late final int _maxWords = widget.seedTypes
      .map((t) => t.fixedWordCount ?? (t.lengthOptions?.reduce((a, b) => a > b ? a : b) ?? 12))
      .fold<int>(1, (a, b) => a > b ? a : b);

  late final List<TextEditingController> _controllers = List.generate(
    _maxWords,
    (_) => TextEditingController(),
  );
  late final List<FocusNode> _nodes = List.generate(_maxWords, (_) => FocusNode());

  late int _typeIndex = 0;
  late int _count = widget.seedTypes[_typeIndex].initialLength;

  SeedTypeOption get _type => widget.seedTypes[_typeIndex];

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  List<String> _readWords() => [
    for (var i = 0; i < _count; i++) _controllers[i].text.trim().toLowerCase(),
  ];

  bool _valid(String w) => _type.isValidWord?.call(w) ?? true;

  /// First left-behind (unfocused) word failing per-word validation.
  int? _firstBad(List<String> words) {
    if (_type.isValidWord == null) return null;
    for (var i = 0; i < _count; i++) {
      if (words[i].isNotEmpty && !_valid(words[i]) && !_nodes[i].hasFocus) return i;
    }
    return null;
  }

  /// All slots filled and, when the type validates words, all words valid.
  bool _allFilledValid(List<String> words) => words.every((w) => w.isNotEmpty && _valid(w));

  /// Whole-phrase error once every word is valid (e.g. bip39 checksum), else null.
  String? _mnemonicError(List<String> words) {
    if (_type.mnemonicError == null || !_allFilledValid(words)) return null;
    return _type.mnemonicError!(words.join(' '));
  }

  void _setCount(int n) {
    if (n != _count) setState(() => _count = n);
  }

  void _selectType(int index) {
    if (index == _typeIndex) return;
    setState(() {
      _typeIndex = index;
      _count = _type.initialLength;
    });
    widget.onSeedTypeChanged?.call(_type.id);
  }

  void _setWords(List<String> words) => _applyTokens(words);

  /// Detects the seed type from the token count (across all offered types),
  /// switches to it, then fills the grid. Shared by paste and QR scan.
  void _applyTokens(List<String> tokens) {
    int? match;
    for (var i = 0; i < widget.seedTypes.length; i++) {
      final t = widget.seedTypes[i];
      if (t.fixedWordCount == tokens.length ||
          (t.lengthOptions?.contains(tokens.length) ?? false)) {
        match = i;
        break;
      }
    }
    setState(() {
      if (match != null) {
        _typeIndex = match;
        _count = _type.fixedWordCount ?? tokens.length;
      }
      for (var i = 0; i < _maxWords; i++) {
        _controllers[i].text = (i < tokens.length && i < _count) ? tokens[i] : '';
      }
    });
    if (match != null) widget.onSeedTypeChanged?.call(_type.id);
  }

  /// Splits pasted/space-separated input across the slots from [i] onward.
  void _onSlotChanged(int i, String value) {
    if (RegExp(r'\s').hasMatch(value)) {
      final tokens = value.trim().split(RegExp(r'\s+'));
      for (var k = 0; k < tokens.length && i + k < _count; k++) {
        _controllers[i + k].text = tokens[k];
      }
      final next = (i + tokens.length).clamp(0, _count - 1);
      _nodes[next].requestFocus();
      _controllers[next].selection = TextSelection.collapsed(
        offset: _controllers[next].text.length,
      );
    }
    // No setState — the changed controllers notify the slot + footer listeners.
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _applyTokens(text.split(RegExp(r'\s+')));
  }

  Widget _buildSlot(int i) {
    return _WordSlot(
      key: ValueKey(i),
      index: i + 1,
      controller: _controllers[i],
      focusNode: _nodes[i],
      validate: _valid,
      isLast: i == _count - 1,
      onChanged: (v) => _onSlotChanged(i, v),
      onSubmitted: () {
        if (i + 1 < _count) _nodes[i + 1].requestFocus();
      },
    );
  }

  void _restore() {
    if (widget.restoring) return;
    widget.onRestore(_readWords().join(' '), _type.id);
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final cols = seedGridColumns(context);
    final showSteps = widget.stepCount != null && widget.stepIndex != null;
    final type = _type;

    // The slots, notice, and Restore button react to typing via their own
    // listeners — a keystroke never rebuilds the whole screen.
    final reactive = Listenable.merge([
      for (var i = 0; i < _count; i++) _controllers[i],
      for (var i = 0; i < _count; i++) _nodes[i],
    ]);

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: BrandSpacing.sm),
        BrandScreenHeader(
          onBack: () => Navigator.maybePop(context),
          center: showSteps
              ? StepDots(count: widget.stepCount!, index: widget.stepIndex!)
              : Text(labels.title, style: BrandText.appBar),
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onScan != null) ...[
                IconCircleButton(icon: Icons.qr_code_scanner_rounded, onPressed: widget.onScan!),
                const SizedBox(width: 6),
              ],
              Tooltip(
                message: labels.paste,
                child: IconCircleButton(icon: Icons.content_paste_rounded, onPressed: _paste),
              ),
            ],
          ),
        ),
        const SizedBox(height: BrandSpacing.lg),
        if (widget.seedTypes.length > 1) ...[
          BrandSegmented(
            labels: [for (final t in widget.seedTypes) t.label],
            selectedIndex: _typeIndex,
            onSelect: _selectType,
            dense: true,
          ),
          const SizedBox(height: BrandSpacing.md),
        ],
        if (type.lengthOptions != null && type.fixedWordCount == null) ...[
          Row(
            children: [
              SectionHeader(label: labels.seedLength, padding: EdgeInsets.zero),
              const Spacer(),
              _SeedLengthSelector(
                lengths: type.lengthOptions!,
                selected: _count,
                onSelect: _setCount,
              ),
            ],
          ),
          const SizedBox(height: BrandSpacing.md),
        ],
        Text(labels.subtitle, style: BrandText.bodyMuted),
        const SizedBox(height: BrandSpacing.lg),
        Expanded(
          child: ListView(
            children: [
              // Rows sized to their content; 3 columns, or 2 on narrow screens.
              // A short last row is padded with empty slots.
              for (var r = 0; r * cols < _count; r++) ...[
                if (r > 0) const SizedBox(height: 9),
                Row(
                  children: [
                    for (var c = 0; c < cols && r * cols + c < _count; c++) ...[
                      if (c > 0) const SizedBox(width: 9),
                      Expanded(child: _buildSlot(r * cols + c)),
                    ],
                  ],
                ),
              ],
              ListenableBuilder(
                listenable: reactive,
                builder: (context, _) {
                  final words = _readWords();
                  final bad = _firstBad(words);
                  final Widget notice;
                  if (bad != null) {
                    notice = _BadWordNotice(
                      message: labels.badWord(bad + 1),
                      suggestion: type.suggestWord?.call(words[bad]),
                      suggestionText: labels.didYouMean,
                    );
                  } else if (_mnemonicError(words) case final err?) {
                    notice = _BadWordNotice(
                      message: err,
                      suggestion: null,
                      suggestionText: (_) => '',
                    );
                  } else {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: BrandSpacing.md),
                    child: notice,
                  );
                },
              ),
              const SizedBox(height: BrandSpacing.lg),
              widget.restorePointFields,
            ],
          ),
        ),
        // Keep the Restore button off the restore-point card when the words make
        // the list scroll (small screens / 2-column layout).
        const SizedBox(height: BrandSpacing.md),
        ListenableBuilder(
          listenable: reactive,
          builder: (context, _) {
            final words = _readWords();
            final ready =
                _allFilledValid(words) &&
                _mnemonicError(words) == null &&
                (widget.canRestore?.call() ?? true);
            return BrandButton(
              label: labels.restoreButton,
              loading: widget.restoring,
              onPressed: (!widget.restoring && ready) ? _restore : null,
            );
          },
        ),
        const SizedBox(height: BrandSpacing.sm),
      ],
    );

    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BrandSpacing.xl),
              child: column,
            ),
          ),
        ),
      ),
    );
  }
}

/// Self-managing slot: it listens to its own controller/focus and rebuilds only
/// itself, so typing in one slot never rebuilds the others.
class _WordSlot extends StatefulWidget {
  final int index;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool Function(String) validate;
  final bool isLast;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  const _WordSlot({
    super.key,
    required this.index,
    required this.controller,
    required this.focusNode,
    required this.validate,
    required this.isLast,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  State<_WordSlot> createState() => _WordSlotState();
}

class _WordSlotState extends State<_WordSlot> {
  bool _filled = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _apply(_derive());
    widget.controller.addListener(_onChange);
    widget.focusNode.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    widget.focusNode.removeListener(_onChange);
    super.dispose();
  }

  // A word is flagged red only when its slot is not focused (typed or pasted,
  // then left) — never while it's being edited.
  (bool, bool) _derive() {
    final w = widget.controller.text.trim().toLowerCase();
    final filled = w.isNotEmpty;
    return (filled, filled && !widget.focusNode.hasFocus && !widget.validate(w));
  }

  void _apply((bool, bool) v) {
    _filled = v.$1;
    _error = v.$2;
  }

  void _onChange() {
    final v = _derive();
    if (v.$1 != _filled || v.$2 != _error) setState(() => _apply(v));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // The field box is text-tight; make the whole slot (incl. padding) focus it.
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.focusNode.requestFocus(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        decoration: BoxDecoration(
          color: _filled ? BrandColors.card : BrandColors.surfaceSunken,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _error ? BrandColors.error : BrandColors.border, width: 1),
        ),
        child: Row(
          // Bottom-align so the smaller number sits on the word's baseline.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                widget.index.toString().padLeft(2, '0'),
                style: TextStyle(
                  fontFamily: 'Ubuntu Mono',
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: BrandColors.inkDisabled,
                ),
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onSubmitted(),
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: widget.isLast ? TextInputAction.done : TextInputAction.next,
                cursorColor: BrandColors.primary,
                // Force the field box down to the text height so it doesn't add
                // vertical padding (which made the slot tall + misaligned the no.).
                strutStyle: const StrutStyle(forceStrutHeight: true, height: 1, fontSize: 13.5),
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: _error ? BrandColors.error : BrandColors.ink,
                ),
                decoration: const InputDecoration(
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Segmented control for the seed length — a tinted track with the selected
/// number lifted onto a white pill.
class _SeedLengthSelector extends StatelessWidget {
  final List<int> lengths;
  final int selected;
  final ValueChanged<int> onSelect;

  const _SeedLengthSelector({
    required this.lengths,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: BrandColors.surfaceTinted,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 3,
        children: [
          for (final n in lengths)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(n),
              child: AnimatedContainer(
                duration: BrandMotion.transition,
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: n == selected ? BrandColors.paper : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '$n',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: n == selected ? BrandColors.ink : BrandColors.inkMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BadWordNotice extends StatelessWidget {
  final String message;
  final String? suggestion;
  final String Function(String) suggestionText;

  const _BadWordNotice({
    required this.message,
    required this.suggestion,
    required this.suggestionText,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: BrandColors.error),
        const SizedBox(width: BrandSpacing.sm),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: BrandText.caption.copyWith(color: BrandColors.error),
              children: [
                TextSpan(text: message),
                if (suggestion != null)
                  TextSpan(
                    text: ' ${suggestionText(suggestion!)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
