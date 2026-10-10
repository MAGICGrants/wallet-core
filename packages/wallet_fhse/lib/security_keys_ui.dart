/// The shared security-key screens: Settings > Advanced security, setting keys
/// up, and unlocking with a key or the recovery phrase.
///
/// An app installs [SecurityKeysUi] with its name, logo, home route and
/// [WalletManager], adds [FhseLocalizations.delegate] to its
/// localizationsDelegates, and routes to [AdvancedSecurityScreen] and
/// [SecurityKeyUnlockScreen]. See README.md.
library;

export 'src/l10n/fhse_localizations.dart';
export 'src/ui/advanced_security_screen.dart';
export 'src/ui/security_key_flow.dart';
export 'src/ui/security_key_setup_screen.dart';
export 'src/ui/security_key_unlock_screen.dart';
export 'src/ui/security_keys_app.dart';
