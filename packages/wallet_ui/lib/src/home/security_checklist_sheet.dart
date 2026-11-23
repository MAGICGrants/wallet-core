import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/settings_group.dart';
import '../design/sheet.dart';
import 'security_checklist.dart';

/// The Security Checklist card's strings, from the app's own l10n.
class SecurityChecklistSheetLabels {
  const SecurityChecklistSheetLabels({
    required this.title,
    required this.subtitle,
    required this.homeSection,
    required this.showOnHome,
    required this.showOnHomeDesc,
    required this.stepsSection,
    required this.done,
    required this.notDone,
    required this.seedDone,
    required this.steps,
    required this.save,
    required this.cancel,
  });

  final String title;
  final String subtitle;
  final String homeSection;
  final String showOnHome;
  final String showOnHomeDesc;
  final String stepsSection;
  final String done;
  final String notDone;

  /// A done recovery phrase step, which opens again when the check expires.
  final String seedDone;

  /// The steps' names, as the home card shows them.
  final SecurityChecklistLabels steps;
  final String save;
  final String cancel;
}

/// Settings' Security Checklist card: whether the home shows the checklist
/// at all, and a switch for each step that applies here, laid out like the
/// OpenAlias and price display cards. Nothing changes until Save, which
/// stores the [SecurityChecklistSettings] and resolves to `true`; Cancel
/// closes it as it was.
///
/// [checklist] reads where each step stands; the card refreshes it and leaves
/// disposing it to the caller.
Future<bool?> showSecurityChecklistSheet(
  BuildContext context, {
  required SecurityChecklist checklist,
  required SecurityChecklistSheetLabels labels,
}) {
  return showBrandSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SecurityChecklistSheet(checklist: checklist, labels: labels),
  );
}

class _SecurityChecklistSheet extends StatefulWidget {
  const _SecurityChecklistSheet({required this.checklist, required this.labels});

  final SecurityChecklist checklist;
  final SecurityChecklistSheetLabels labels;

  @override
  State<_SecurityChecklistSheet> createState() => _SecurityChecklistSheetState();
}

class _SecurityChecklistSheetState extends State<_SecurityChecklistSheet> {
  bool _showOnHome = true;
  final Set<SecurityStep> _stepsOff = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Read straight from storage, not from the checklist: a checklist whose
    // steps could not be read keeps its defaults, and saving those would undo
    // what the user chose before.
    final saved = await SecurityChecklistSettings.load();
    await widget.checklist.refresh();
    if (!mounted) return;
    setState(() {
      _showOnHome = saved.showOnHome;
      _stepsOff.addAll(saved.stepsOff);
      _loaded = true;
    });
  }

  Future<void> _save() async {
    await SecurityChecklistSettings(showOnHome: _showOnHome, stepsOff: {..._stepsOff}).save();
    if (mounted) Navigator.of(context).pop(true);
  }

  String _detail(SecurityStep step, bool done) {
    final l = widget.labels;
    if (!done) return l.notDone;
    return step == SecurityStep.verifySeed ? l.seedDone : l.done;
  }

  void _setStep(SecurityStep step, bool on) {
    setState(() {
      if (on) {
        _stepsOff.remove(step);
      } else {
        _stepsOff.add(step);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.labels;
    // Steps that do not apply here are not offered; a choice saved for one
    // elsewhere stays as it was.
    final steps = widget.checklist.steps ?? const <SecurityStep, bool>{};
    // Desktop modal: the card owns the edge padding.
    final hpad = isDesktopModal ? 0.0 : 22.0;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight(context)),
        child: Padding(
          padding: EdgeInsets.only(top: isDesktopModal ? 0 : 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Padding(
                padding: EdgeInsets.fromLTRB(hpad, 0, hpad, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SheetIcon(
                          icon: Icons.shield_outlined,
                          bg: BrandColors.surfaceAccent,
                          color: BrandColors.primaryDeep,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Semantics(
                            header: true,
                            namesRoute: true,
                            child: Text(l.title, style: BrandText.sheetTitle),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    // Its own node, so the sheet's heading stays the title alone.
                    Semantics(
                      container: true,
                      child: Text(
                        l.subtitle,
                        style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: hpad),
                  child: !_loaded
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SettingsGroup(
                              label: l.homeSection,
                              tiles: [
                                SettingsToggleTile(
                                  title: l.showOnHome,
                                  description: l.showOnHomeDesc,
                                  value: _showOnHome,
                                  onChanged: (on) => setState(() => _showOnHome = on),
                                ),
                              ],
                            ),
                            if (steps.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              SettingsGroup(
                                label: l.stepsSection,
                                tiles: [
                                  for (final MapEntry(key: step, value: done) in steps.entries)
                                    SettingsToggleTile(
                                      title: l.steps.of(step),
                                      description: _detail(step, done),
                                      value: !_stepsOff.contains(step),
                                      onChanged: (on) => _setStep(step, on),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(hpad, 18, hpad, 8),
                child: SheetActions(
                  primary: BrandButton(label: l.save, onPressed: _loaded ? _save : null),
                  secondary: BrandButton.ghost(
                    label: l.cancel,
                    color: BrandColors.inkMuted,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
