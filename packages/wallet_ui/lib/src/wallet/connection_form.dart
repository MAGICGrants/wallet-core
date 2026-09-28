import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/brand_segmented.dart';
import '../design/section_header.dart';
import 'connection_pills.dart';

/// Which test-card state the [ConnectionFormView] renders. The wrapper maps its
/// own flags onto this so the view holds no test logic of its own:
/// - [startingTor] — built-in Tor still bootstrapping; takes over the action.
/// - [idle] — not yet tested; shows the "Test connection" button.
/// - [testing] — a probe is in flight; shows a spinner + Stop.
/// - [success] — the last probe reached the server (green result card).
/// - [failure] — the last probe failed (red result card).
enum ConnectionTestState { startingTor, idle, testing, success, failure }

/// One optional checkbox row below the Tor toggle (background / foreground sync).
/// Apps/modes without sync options pass an empty list.
class ConnectionSyncRow {
  final String label;
  final String help;
  final bool checked;
  final ValueChanged<bool> onToggle;

  const ConnectionSyncRow({
    required this.label,
    required this.help,
    required this.checked,
    required this.onToggle,
  });
}

/// Plain strings the [ConnectionFormView] renders. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class ConnectionFormLabels {
  final String proxyPortLabel;
  final String proxyPortHint;
  final String useTorLabel;
  final String startingTorTitle;

  final String testButton;
  final String testStop;
  final String testingTitle;
  final String testingDetail;
  final String testAgain;

  final String resultWorksTitle;
  final String resultFailedTitle;
  final String resultFailedDetail;

  const ConnectionFormLabels({
    required this.proxyPortLabel,
    required this.proxyPortHint,
    required this.useTorLabel,
    required this.startingTorTitle,
    required this.testButton,
    required this.testStop,
    required this.testingTitle,
    required this.testingDetail,
    required this.testAgain,
    required this.resultWorksTitle,
    required this.resultFailedTitle,
    required this.resultFailedDetail,
  });
}

/// Presentational connection-settings form shared by Spice and Skylight. Owns
/// no state — the app wrapper keeps every controller and all
/// test/save/network logic and passes state + callbacks down. Renders: an
/// optional connection-type segmented control (hidden when ≤1 option), a
/// floating-label address field (mono, with an optional QR trailing button),
/// an inline error line, a proxy-port field (disabled under Tor), a Use-Tor
/// check row with route pills, optional sync check rows, the test card, and a
/// Save button (optionally pinned to the bottom of a scroll view).
class ConnectionFormView extends StatelessWidget {
  final ConnectionFormLabels labels;

  // Address field.
  final String addressLabel;
  final String addressHint;
  final TextEditingController addressController;
  final ValueChanged<String> onAddressChanged;
  final VoidCallback? onScan;
  final String? errorMessage;

  // Proxy port field.
  final TextEditingController proxyController;
  final ValueChanged<String> onProxyChanged;
  final bool proxyEnabled;

  // Connection-type segmented control (hidden when length ≤ 1).
  final List<String> connectionTypeLabels;
  final int selectedTypeIndex;
  final ValueChanged<int> onSelectType;

  // Use-Tor row. Route pills are derived from these strings via the shared
  // [connectionRoutePills] helper.
  final bool useTor;
  final bool torDisabled;
  final VoidCallback onToggleTor;
  final String pillProxyPort;
  final String pillAddress;

  final List<ConnectionSyncRow> syncRows;

  // Test card.
  final ConnectionTestState testState;
  final VoidCallback onTest;
  final VoidCallback onStopTest;
  final VoidCallback onTestAgain;

  /// Only shown on the success card: a detail line (how the probe reached the
  /// server) and an optional trailing latency string ("42 ms").
  final String successDetail;
  final String? successLatency;

  // Save.
  final String saveButtonLabel;
  final bool canSave;
  final VoidCallback onSave;
  final bool pinnedSave;

  /// Hide the built-in Save button — the host renders its own (e.g. the desktop
  /// onboarding footer's Continue button sits beside Back).
  final bool showSave;

  const ConnectionFormView({
    super.key,
    required this.labels,
    required this.addressLabel,
    required this.addressHint,
    required this.addressController,
    required this.onAddressChanged,
    required this.errorMessage,
    required this.proxyController,
    required this.onProxyChanged,
    required this.proxyEnabled,
    required this.connectionTypeLabels,
    required this.selectedTypeIndex,
    required this.onSelectType,
    required this.useTor,
    required this.torDisabled,
    required this.onToggleTor,
    required this.pillProxyPort,
    required this.pillAddress,
    required this.testState,
    required this.onTest,
    required this.onStopTest,
    required this.onTestAgain,
    required this.successDetail,
    required this.saveButtonLabel,
    required this.canSave,
    required this.onSave,
    this.onScan,
    this.successLatency,
    this.syncRows = const [],
    this.pinnedSave = false,
    this.showSave = true,
  });

  List<Widget> _routePills() =>
      connectionRoutePills(useTor: useTor, proxyPort: pillProxyPort, address: pillAddress);

  Widget _buildTestCard() {
    switch (testState) {
      case ConnectionTestState.startingTor:
        return _StatusRowCard(leading: const _Spinner(), title: labels.startingTorTitle);
      case ConnectionTestState.idle:
        return Align(
          alignment: Alignment.center,
          child: BrandButton.secondary(
            label: labels.testButton,
            icon: Icons.wifi,
            onPressed: onTest,
            expand: false,
            dense: true,
          ),
        );
      case ConnectionTestState.testing:
        return _StatusRowCard(
          leading: const _Spinner(),
          title: labels.testingTitle,
          detail: labels.testingDetail,
          trailing: BrandButton.ghost(
            label: labels.testStop,
            dense: true,
            expand: false,
            onPressed: onStopTest,
          ),
        );
      case ConnectionTestState.success:
        return _ResultCard(
          icon: Icon(Icons.check, size: 13, color: BrandColors.success),
          iconBg: BrandColors.successBg,
          title: labels.resultWorksTitle,
          trailing: successLatency,
          detail: successDetail,
          onTestAgain: onTestAgain,
          testAgainLabel: labels.testAgain,
        );
      case ConnectionTestState.failure:
        return _ResultCard.failure(
          title: labels.resultFailedTitle,
          detail: labels.resultFailedDetail,
          onTestAgain: onTestAgain,
          testAgainLabel: labels.testAgain,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = <Widget>[
      if (connectionTypeLabels.length > 1) ...[
        BrandSegmented(
          labels: connectionTypeLabels,
          selectedIndex: selectedTypeIndex.clamp(0, connectionTypeLabels.length - 1),
          onSelect: onSelectType,
        ),
        const SizedBox(height: 20),
      ],
      _InsetField(
        label: addressLabel,
        controller: addressController,
        hint: addressHint,
        mono: true,
        keyboardType: TextInputType.url,
        onChanged: onAddressChanged,
        trailing: onScan != null
            ? _FieldIconButton(icon: Icons.qr_code_2, onPressed: onScan!)
            : null,
      ),
      if (errorMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text(errorMessage!, style: BrandText.caption.copyWith(color: BrandColors.error)),
        ),
      const SizedBox(height: 16),
      _InsetField(
        label: labels.proxyPortLabel,
        controller: proxyController,
        hint: labels.proxyPortHint,
        mono: true,
        number: true,
        enabled: proxyEnabled,
        onChanged: onProxyChanged,
      ),
      const SizedBox(height: 4),
      _CheckRow(
        checked: useTor,
        onTap: torDisabled ? null : onToggleTor,
        label: labels.useTorLabel,
        trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: _routePills()),
      ),
      for (final row in syncRows)
        _CheckRow(
          checked: row.checked,
          onTap: () => row.onToggle(!row.checked),
          label: row.label,
          help: row.help,
        ),
      const SizedBox(height: 16),
      _buildTestCard(),
    ];

    final saveButton = BrandButton(label: saveButtonLabel, onPressed: canSave ? onSave : null);

    if (pinnedSave) {
      return Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: content,
              ),
            ),
          ),
          if (showSave)
            Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 8), child: saveButton),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [...content, if (showSave) ...[const SizedBox(height: 16), saveButton]],
    );
  }
}

/// Bordered inset field with an optional floating label sitting on the border.
class _InsetField extends StatelessWidget {
  final String? label;
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final bool mono;
  final bool number;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;

  const _InsetField({
    required this.controller,
    required this.hint,
    this.label,
    this.enabled = true,
    this.mono = false,
    this.number = false,
    this.keyboardType,
    this.onChanged,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    // Disabled state dims the whole field via Opacity below, so the text keeps
    // its normal colour here.
    final field = TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: number ? TextInputType.number : keyboardType,
      textInputAction: TextInputAction.done,
      inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
      strutStyle: const StrutStyle(forceStrutHeight: true, height: 1.1, fontSize: 13.5),
      style: TextStyle(
        fontFamily: mono ? 'Ubuntu Mono' : 'Ubuntu',
        fontSize: 13.5,
        height: 1,
        color: BrandColors.ink,
      ),
      decoration: InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
        hintText: hint,
        hintStyle: TextStyle(
          fontFamily: mono ? 'Ubuntu Mono' : 'Ubuntu',
          fontSize: 13.5,
          height: 1,
          color: BrandColors.inkMuted,
        ),
      ),
    );

    final box = BrandCard(
      radius: 14,
      borderColor: BrandColors.inputBorder,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Row(
        children: [
          Expanded(child: field),
          ?trailing,
        ],
      ),
    );

    final content = label == null
        ? box
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(label: label!, padding: const EdgeInsets.only(left: 2, bottom: 9)),
              box,
            ],
          );

    // Dim the whole field when disabled (e.g. the proxy port while Use Tor is on).
    return enabled ? content : Opacity(opacity: 0.45, child: content);
  }
}

/// Small icon button that sits inside a field's trailing slot (QR scan).
class _FieldIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _FieldIconButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tappable(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Icon(icon, size: 20, color: BrandColors.primaryDeep),
      ),
    );
  }
}

/// A square check + label row (Use Tor, sync toggles), with optional trailing
/// pills or a "?" help affordance.
class _CheckRow extends StatelessWidget {
  final bool checked;
  final VoidCallback? onTap;
  final String label;
  final String? help;
  final Widget? trailing;

  const _CheckRow({
    required this.checked,
    required this.onTap,
    required this.label,
    this.help,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          // Tap target is the check + label; vertical padding here sets the row
          // height (no extra slop on the box, which was bloating the gaps).
          Tappable(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: checked ? BrandColors.primary : BrandColors.card,
                      borderRadius: BorderRadius.circular(6),
                      border: checked ? null : Border.all(color: BrandColors.inputBorder),
                    ),
                    child: checked
                        ? const Icon(Icons.check, size: 15, color: BrandColors.onPrimary)
                        : null,
                  ),
                  const SizedBox(width: 11),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: enabled ? BrandColors.ink : BrandColors.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (help != null) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: help!,
              triggerMode: TooltipTriggerMode.tap,
              child: Container(
                width: 17,
                height: 17,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: BrandColors.inputBorder, width: 1.4),
                ),
                child: Text(
                  '?',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: BrandColors.inkMuted,
                  ),
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// White card container for the test-result states.
class _TestCard extends StatelessWidget {
  final Widget child;
  const _TestCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return BrandCard(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(15, 4, 15, 10),
      child: child,
    );
  }
}

/// 22px spinner used in the "starting Tor" / "testing" states.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(
        strokeWidth: 2.4,
        color: BrandColors.primaryDeep,
        backgroundColor: BrandColors.border,
      ),
    );
  }
}

/// A leading + title (+ detail / trailing) row card, used for the Tor-starting
/// and test-running states.
class _StatusRowCard extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? detail;
  final Widget? trailing;

  const _StatusRowCard({required this.leading, required this.title, this.detail, this.trailing});

  @override
  Widget build(BuildContext context) {
    return _TestCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.only(top: 8, bottom: detail != null ? 10 : 8),
            decoration: detail != null
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: BrandColors.hairline)),
                  )
                : null,
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: BrandColors.ink,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(
                detail!,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: BrandColors.inkMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Test finished — success (green) or failure (red).
class _ResultCard extends StatelessWidget {
  final Widget? icon;
  final Color? iconBg;
  final String title;
  final String? trailing;
  final String detail;
  final VoidCallback onTestAgain;
  final String testAgainLabel;
  final bool isFailure;

  const _ResultCard({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.detail,
    required this.onTestAgain,
    required this.testAgainLabel,
    this.trailing,
  }) : isFailure = false;

  const _ResultCard.failure({
    required this.title,
    required this.detail,
    required this.onTestAgain,
    required this.testAgainLabel,
  }) : icon = null,
       iconBg = null,
       trailing = null,
       isFailure = true;

  @override
  Widget build(BuildContext context) {
    final titleColor = isFailure ? BrandColors.error : BrandColors.ink;
    return _TestCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.only(top: 8, bottom: isFailure ? 4 : 10),
            decoration: isFailure
                ? null
                : BoxDecoration(
                    border: Border(bottom: BorderSide(color: BrandColors.hairline)),
                  ),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFailure ? BrandColors.errorBg : iconBg,
                  ),
                  child: isFailure ? Icon(Icons.close, size: 13, color: BrandColors.error) : icon,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: TextStyle(
                      fontFamily: 'Ubuntu Mono',
                      fontSize: 11.5,
                      height: 1,
                      fontWeight: FontWeight.w500,
                      color: BrandColors.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: isFailure ? 2 : 10, bottom: isFailure ? 8 : 4),
            child: Text(
              detail,
              style: TextStyle(
                fontSize: isFailure ? 12 : 12.5,
                height: isFailure ? 1.5 : 1.45,
                color: isFailure ? BrandColors.error : BrandColors.inkMuted,
              ),
            ),
          ),
          if (isFailure)
            BrandButton(label: testAgainLabel, dense: true, onPressed: onTestAgain)
          else
            Align(
              alignment: Alignment.centerRight,
              child: BrandButton.secondary(
                label: testAgainLabel,
                dense: true,
                expand: false,
                onPressed: onTestAgain,
              ),
            ),
        ],
      ),
    );
  }
}
