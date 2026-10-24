import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show SyncFrequency, loadSyncFrequency;

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/mode_select_card.dart';
import '../design/section_header.dart';
import '../design/sheet.dart';

/// The Sync Frequency sheet's strings, from the app's own l10n.
class SyncFrequencyLabels {
  const SyncFrequencyLabels({
    required this.title,
    required this.subtitle,
    required this.modeLabel,
    required this.continuous,
    required this.continuousDesc,
    required this.periodic,
    required this.periodicDesc,
    required this.off,
    required this.offDesc,
    required this.save,
    required this.cancel,
  });

  final String title;
  final String subtitle;
  final String modeLabel;
  final String continuous;
  final String continuousDesc;
  final String periodic;
  final String periodicDesc;
  final String off;
  final String offDesc;
  final String save;
  final String cancel;

  String nameOf(SyncFrequency frequency) => switch (frequency) {
    SyncFrequency.continuous => continuous,
    SyncFrequency.periodic => periodic,
    SyncFrequency.off => off,
  };
}

/// How often the wallets sync while the app is closed, laid out like the
/// OpenAlias sheet: one card per [SyncFrequency] this platform offers
/// (Continuous is Android-only). Resolves to the choice when the user saves,
/// null when they cancel; applying it is the app's job (wallet_background's
/// `applySyncFrequency`), since it starts and stops services.
Future<SyncFrequency?> showSyncFrequencySheet(
  BuildContext context, {
  required SyncFrequencyLabels labels,
}) {
  return showBrandSheet<SyncFrequency>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SyncFrequencySheet(labels: labels),
  );
}

class _SyncFrequencySheet extends StatefulWidget {
  const _SyncFrequencySheet({required this.labels});

  final SyncFrequencyLabels labels;

  @override
  State<_SyncFrequencySheet> createState() => _SyncFrequencySheetState();
}

class _SyncFrequencySheetState extends State<_SyncFrequencySheet> {
  SyncFrequency _frequency = SyncFrequency.periodic;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final frequency = await loadSyncFrequency();
    if (!mounted) return;
    setState(() {
      _frequency = frequency;
      _loaded = true;
    });
  }

  String _description(SyncFrequency frequency) => switch (frequency) {
    SyncFrequency.continuous => widget.labels.continuousDesc,
    SyncFrequency.periodic => widget.labels.periodicDesc,
    SyncFrequency.off => widget.labels.offDesc,
  };

  @override
  Widget build(BuildContext context) {
    final l = widget.labels;
    // Desktop modal: the card owns the edge padding.
    final hpad = isDesktopModal ? 0.0 : 22.0;
    final options = SyncFrequency.available;

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
                          icon: Icons.sync_rounded,
                          bg: BrandColors.surfaceAccent,
                          color: BrandColors.primaryDeep,
                        ),
                        const SizedBox(width: 11),
                        Expanded(child: Text(l.title, style: BrandText.sheetTitle)),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      l.subtitle,
                      style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
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
                            SectionHeader(label: l.modeLabel),
                            for (final frequency in options) ...[
                              const SizedBox(height: BrandSpacing.md),
                              ModeSelectCard(
                                title: l.nameOf(frequency),
                                description: _description(frequency),
                                selected: _frequency == frequency,
                                onTap: () => setState(() => _frequency = frequency),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(hpad, 18, hpad, 8),
                child: SheetActions(
                  primary: BrandButton(
                    label: l.save,
                    onPressed: _loaded ? () => Navigator.of(context).pop(_frequency) : null,
                  ),
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
