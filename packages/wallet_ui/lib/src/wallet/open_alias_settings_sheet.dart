import 'package:flutter/material.dart';
import 'package:wallet_domain/wallet_domain.dart' show OpenAliasMode;
import 'package:wallet_infra/wallet_infra.dart' show TorMode, TorSettingsService;

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/mode_select_card.dart';
import '../design/section_header.dart';
import '../design/sheet.dart';

/// The OpenAlias sheet's strings, from the app's own l10n.
class OpenAliasSettingsLabels {
  const OpenAliasSettingsLabels({
    required this.title,
    required this.subtitle,
    required this.modeLabel,
    required this.torOnly,
    required this.torOnlyDesc,
    required this.clearnet,
    required this.clearnetDesc,
    required this.disabled,
    required this.disabledDesc,
    required this.save,
    required this.cancel,
  });

  final String title;
  final String subtitle;
  final String modeLabel;
  final String torOnly;
  final String torOnlyDesc;
  final String clearnet;
  final String clearnetDesc;
  final String disabled;
  final String disabledDesc;
  final String save;
  final String cancel;
}

/// How OpenAlias names are looked up, laid out like the price display sheet:
/// Tor-only, clearnet-only or disabled ([OpenAliasMode]). Resolves to `true`
/// when the user saved a change.
///
/// With Tor turned off the Tor-only card is hidden, since no lookup could use
/// it, and a saved Tor-only choice shows as clearnet until the user saves.
Future<bool?> showOpenAliasSettingsSheet(
  BuildContext context, {
  required OpenAliasSettingsLabels labels,
}) {
  return showBrandSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _OpenAliasSettingsSheet(labels: labels),
  );
}

class _OpenAliasSettingsSheet extends StatefulWidget {
  const _OpenAliasSettingsSheet({required this.labels});

  final OpenAliasSettingsLabels labels;

  @override
  State<_OpenAliasSettingsSheet> createState() => _OpenAliasSettingsSheetState();
}

class _OpenAliasSettingsSheetState extends State<_OpenAliasSettingsSheet> {
  OpenAliasMode _mode = OpenAliasMode.torOnly;
  bool _loaded = false;

  bool get _torOff => TorSettingsService.sharedInstance.torMode == TorMode.disabled;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mode = await OpenAliasMode.load();
    if (!mounted) return;
    setState(() {
      _mode = (_torOff && mode == OpenAliasMode.torOnly) ? OpenAliasMode.clearnet : mode;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    await _mode.save();
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _card(OpenAliasMode mode, String title, String description) => ModeSelectCard(
    title: title,
    description: description,
    selected: _mode == mode,
    onTap: () => setState(() => _mode = mode),
  );

  @override
  Widget build(BuildContext context) {
    final l = widget.labels;
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
                          icon: Icons.alternate_email,
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
                            const SizedBox(height: BrandSpacing.md),
                            if (!_torOff) ...[
                              _card(OpenAliasMode.torOnly, l.torOnly, l.torOnlyDesc),
                              const SizedBox(height: BrandSpacing.md),
                            ],
                            _card(OpenAliasMode.clearnet, l.clearnet, l.clearnetDesc),
                            const SizedBox(height: BrandSpacing.md),
                            _card(OpenAliasMode.disabled, l.disabled, l.disabledDesc),
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
