import 'package:flutter/material.dart';

import 'key_reveal_view.dart';

/// Translated strings for [LwsKeysView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class LwsKeysLabels {
  final String title;
  final String description;
  final String primaryAddressLabel;
  final String viewKeyLabel;
  final String restoreHeightLabel;
  final String reveal;
  final String warning;

  const LwsKeysLabels({
    required this.title,
    required this.description,
    required this.primaryAddressLabel,
    required this.viewKeyLabel,
    required this.restoreHeightLabel,
    required this.reveal,
    required this.warning,
  });
}

/// Shows a Monero wallet's LWS details (primary address, secret view key,
/// restore height) so the user can whitelist the wallet on a light-wallet
/// server. A thin specialization of [KeyRevealView]: the secret view key is the
/// only blurred field. Each app supplies [onCopy], and optionally a back action
/// (settings) or a [footer] continue button (onboarding).
class LwsKeysView extends StatelessWidget {
  final LwsKeysLabels labels;
  final String primaryAddress;
  final String secretViewKey;
  final String restoreHeight;
  final Widget? headerIcon;
  final void Function(String value) onCopy;
  final VoidCallback? onBack;
  final Widget? footer;
  final bool largeTitle;

  const LwsKeysView({
    super.key,
    required this.labels,
    required this.primaryAddress,
    required this.secretViewKey,
    required this.restoreHeight,
    required this.onCopy,
    this.headerIcon,
    this.onBack,
    this.footer,
    this.largeTitle = false,
  });

  @override
  Widget build(BuildContext context) {
    return KeyRevealView(
      title: labels.title,
      description: labels.description,
      warning: labels.warning,
      revealLabel: labels.reveal,
      headerIcon: headerIcon,
      onCopy: onCopy,
      onBack: onBack,
      footer: footer,
      largeTitle: largeTitle,
      fields: [
        KeyRevealField(label: labels.primaryAddressLabel, value: primaryAddress),
        KeyRevealField(label: labels.viewKeyLabel, value: secretViewKey, revealable: true),
        KeyRevealField(label: labels.restoreHeightLabel, value: restoreHeight),
      ],
    );
  }
}
