/// The shared security-key screens: Settings > Advanced Security, setting keys
/// up, and unlocking with a key or the recovery phrase; and App Lock's checks
/// that guard secrets and settings ([passAppLock], [AppLockGate]), and the
/// locks driven by the app's lifecycle ([AppLockLifecycle]).
///
/// An app installs [SecurityKeysUi] with its name, logo, home route and
/// [WalletManager], adds [FhseLocalizations.delegate] to its
/// localizationsDelegates, and routes to [GuardedAdvancedSecurityScreen] (not
/// the bare [AdvancedSecurityScreen], which asks for nothing) and
/// [SecurityKeyUnlockScreen]. See README.md.
library;

export 'src/l10n/fhse_localizations.dart';
export 'src/ui/advanced_security_gate.dart';
export 'src/ui/app_lock.dart';
export 'src/ui/app_lock_gate.dart';
export 'src/ui/app_lock_lifecycle.dart';
export 'src/ui/advanced_security_screen.dart';
export 'src/ui/security_key_flow.dart';
export 'src/ui/security_key_setup_screen.dart';
export 'src/ui/security_key_unlock_screen.dart';
export 'src/ui/security_keys_app.dart';
