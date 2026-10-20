import 'package:flutter/material.dart';
import 'package:wallet_domain/wallet_domain.dart' show AppSession;
import 'package:wallet_ui/wallet_ui.dart';

import '../l10n/fhse_localizations.dart';
import 'app_lock.dart';
import 'security_key_flow.dart';
import 'security_keys_app.dart';

/// Opens a wallet whose password is behind security keys: after a cold start,
/// and after "Fully lock after" has run out. Comes after App Lock, so the
/// device's own lock is checked first.
///
/// Key first, like a browser's security-key prompt: connect and touch the
/// key, enter its PIN (or touch a YubiKey Bio's sensor), touch it again.
class SecurityKeyUnlockScreen extends StatelessWidget {
  const SecurityKeyUnlockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = FhseLocalizations.of(context);
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: BrandColors.paper,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: BrandSpacing.xl,
                  vertical: BrandSpacing.xxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: SecurityKeysUi.config.logo(context)),
                    const SizedBox(height: BrandSpacing.xl),
                    SecurityKeyFlow(
                      enrolling: false,
                      large: true,
                      registeredKeys: registeredSecurityKeys,
                      useKey: (verification, key) async {
                        await unlockWithSecurityKey(context, verification, key);
                        return null;
                      },
                      onDone: () {
                        // The key was the last lock: screens and payment links
                        // that wait for the user may go ahead ([AppSession]).
                        AppSession.markUnlocked();
                        Navigator.pushNamedAndRemoveUntil(
                          context,
                          SecurityKeysUi.config.homeRoute,
                          (route) => false,
                        );
                      },
                    ),
                    const SizedBox(height: BrandSpacing.sm),
                    BrandButton.ghost(
                      label: i18n.securityKeyLostKeys,
                      onPressed: () => _showLostKeys(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showLostKeys(BuildContext context) async {
    final i18n = FhseLocalizations.of(context);
    final useSeed = await showConfirmSheet(
      context: context,
      icon: Icons.key_off_outlined,
      iconBg: BrandColors.warningBg,
      iconColor: BrandColors.warning,
      title: i18n.securityKeyLostKeys,
      body: i18n.securityKeyLostKeysBody,
      confirmLabel: i18n.securityKeyUseRecoveryPhrase,
      cancelLabel: i18n.securityKeysCancel,
    );
    if (!useSeed || !context.mounted) return;
    final opened = await showRecoveryPhraseSheet(context, unlock: unlockWithRecoveryPhrase);
    if (!opened || !context.mounted) return;
    showBrandToast(context, i18n.securityKeyRecoveredToast);
    AppSession.markUnlocked();
    Navigator.pushNamedAndRemoveUntil(context, SecurityKeysUi.config.homeRoute, (route) => false);
  }
}
