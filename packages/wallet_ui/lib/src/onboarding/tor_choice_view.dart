import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_screen_header.dart';
import '../design/mode_select_card.dart';
import '../design/step_dots.dart';

/// Translated strings for [TorChoiceView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class TorChoiceLabels {
  final String title;
  final String subtitle;
  final String builtIn;
  final String builtInDesc;
  final String external;
  final String externalDesc;
  final String noTor;
  final String noTorDesc;
  final String socksPortLabel;
  final String orbotLabel;
  final String testButton;
  final String connected;
  final String testFailed;
  final String continueText;

  const TorChoiceLabels({
    required this.title,
    required this.subtitle,
    required this.builtIn,
    required this.builtInDesc,
    required this.external,
    required this.externalDesc,
    required this.noTor,
    required this.noTorDesc,
    required this.socksPortLabel,
    required this.orbotLabel,
    required this.testButton,
    required this.connected,
    required this.testFailed,
    required this.continueText,
  });
}

/// Onboarding "Tor choice" screen: a [StepDots] header plus three
/// [ModeSelectCard]s (Built-in / External / No Tor). External expands inline
/// with a SOCKS port field, an Orbot checkbox (mobile), and a connection test
/// with a live status row. Continue unlocks once a mode is picked — External
/// also requires a passing test.
///
/// Presentational only: mode is an int index (0=built-in, 1=external,
/// 2=disabled) so the view doesn't couple to any Tor enum. The view owns the
/// transient selection/port/orbot/test state; the app supplies strings, runs
/// its own [onTest] (a socks-http Tor check), and persists + navigates in
/// [onContinue].
class TorChoiceView extends StatefulWidget {
  final TorChoiceLabels labels;
  final int? initialModeIndex;
  final String initialPort;
  final bool initialUseOrbot;
  final bool isMobile;
  final Future<bool> Function(String port) onTest;
  final void Function({required int modeIndex, required String port, required bool useOrbot})
  onContinue;
  final int stepCount;
  final int stepIndex;

  const TorChoiceView({
    super.key,
    required this.labels,
    required this.onTest,
    required this.onContinue,
    required this.stepCount,
    required this.stepIndex,
    this.initialModeIndex,
    this.initialPort = '9050',
    this.initialUseOrbot = false,
    this.isMobile = false,
  });

  @override
  State<TorChoiceView> createState() => _TorChoiceViewState();
}

class _TorChoiceViewState extends State<TorChoiceView> {
  static const int _builtIn = 0;
  static const int _external = 1;
  static const int _disabled = 2;

  late int? _selected = widget.initialModeIndex;
  late final TextEditingController _portController = TextEditingController(
    text: widget.initialPort,
  );
  late bool _useOrbot = widget.initialUseOrbot;
  bool _testing = false;
  bool _tested = false;
  bool _testOk = false;

  bool get _canCommit => _selected != null && (_selected != _external || _testOk);

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() {
      _selected = index;
      _tested = false;
      _testOk = false;
    });
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _tested = true;
      _testOk = false;
    });
    try {
      final ok = await widget.onTest(_portController.text);
      if (mounted) setState(() => _testOk = ok);
    } catch (_) {
      if (mounted) setState(() => _testOk = false);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _continue() {
    widget.onContinue(modeIndex: _selected!, port: _portController.text, useOrbot: _useOrbot);
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: BrandSpacing.sm),
        BrandScreenHeader(
          onBack: () => Navigator.maybePop(context),
          center: StepDots(count: widget.stepCount, index: widget.stepIndex),
        ),
        const SizedBox(height: BrandSpacing.lg),
        Text(labels.title, style: BrandText.title),
        const SizedBox(height: BrandSpacing.sm),
        Text(labels.subtitle, style: BrandText.bodyMuted),
        const SizedBox(height: BrandSpacing.xl),
        Expanded(
          child: ListView(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ModeSelectCard(
                    title: labels.builtIn,
                    description: labels.builtInDesc,
                    selected: _selected == _builtIn,
                    radioLeading: true,
                    onTap: () => _select(_builtIn),
                  ),
                  const SizedBox(height: 9),
                  ModeSelectCard(
                    title: labels.external,
                    description: labels.externalDesc,
                    selected: _selected == _external,
                    radioLeading: true,
                    onTap: () => _select(_external),
                    expanded: _externalFields(),
                  ),
                  const SizedBox(height: 9),
                  ModeSelectCard(
                    title: labels.noTor,
                    description: labels.noTorDesc,
                    selected: _selected == _disabled,
                    radioLeading: true,
                    onTap: () => _select(_disabled),
                  ),
                ],
              ),
            ],
          ),
        ),
        BrandButton(label: labels.continueText, onPressed: _canCommit ? _continue : null),
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

  Widget _externalFields() {
    final labels = widget.labels;
    final portEnabled = !_useOrbot || !widget.isMobile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PortField(
          controller: _portController,
          label: labels.socksPortLabel,
          enabled: portEnabled,
          onChanged: () => setState(() {
            _tested = false;
            _testOk = false;
          }),
        ),
        if (widget.isMobile)
          _OrbotCheck(
            value: _useOrbot,
            label: labels.orbotLabel,
            onChanged: (v) => setState(() {
              _useOrbot = v;
              if (v) _portController.text = '9050';
              _tested = false;
              _testOk = false;
            }),
          ),
        const SizedBox(height: BrandSpacing.md),
        Row(
          children: [
            Expanded(child: _testStatus()),
            const SizedBox(width: BrandSpacing.md),
            _TestChip(label: labels.testButton, onTap: _testing ? null : _test),
          ],
        ),
      ],
    );
  }

  Widget _testStatus() {
    final labels = widget.labels;
    if (_testing) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: BrandColors.primary),
        ),
      );
    }
    if (!_tested) return const SizedBox.shrink();
    if (_testOk) {
      return Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: BrandColors.success, shape: BoxShape.circle),
          ),
          const SizedBox(width: BrandSpacing.sm),
          Text(
            labels.connected,
            style: BrandText.caption.copyWith(
              color: BrandColors.success,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Icon(Icons.error_outline, color: BrandColors.error, size: 18),
        const SizedBox(width: BrandSpacing.sm),
        Text(
          labels.testFailed,
          style: BrandText.caption.copyWith(color: BrandColors.error, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// Labeled inset field — a small-caps mono label above the value, per the
/// design (not a Material floating-label box).
class _PortField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback onChanged;

  const _PortField({
    required this.controller,
    required this.label,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 13),
      decoration: BoxDecoration(
        color: BrandColors.paper,
        borderRadius: BorderRadius.circular(BrandRadii.tile),
        border: Border.all(color: BrandColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Ubuntu Mono',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: BrandColors.inkFaint,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 14, color: BrandColors.ink),
            cursorColor: BrandColors.primary,
            decoration: const InputDecoration.collapsed(hintText: '9050'),
            onChanged: (_) => onChanged(),
          ),
        ],
      ),
    );
  }
}

/// Small compact chip for the connection test action.
class _TestChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _TestChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: BrandColors.border),
    );
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
        color: BrandColors.surfaceSunken,
        shape: shape,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: onTap,
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: BrandColors.primaryDeep,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbotCheck extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  const _OrbotCheck({required this.value, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BrandSpacing.md),
        child: Row(
          children: [
            Icon(
              value ? Icons.check_box : Icons.check_box_outline_blank,
              color: value ? BrandColors.primary : BrandColors.inkFaint,
              size: 22,
            ),
            const SizedBox(width: BrandSpacing.sm),
            Expanded(child: Text(label, style: BrandText.caption)),
          ],
        ),
      ),
    );
  }
}
