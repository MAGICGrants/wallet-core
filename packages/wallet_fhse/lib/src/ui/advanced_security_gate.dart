import 'package:flutter/material.dart';

import '../l10n/fhse_localizations.dart';
import 'advanced_security_screen.dart';
import 'app_lock_gate.dart';

/// Settings > Advanced Security, which needs a passing App Lock
/// ([AppLockGate]) every time it opens, however recently App Lock was passed.
///
/// The screen can turn security keys off, set them up again, add one, or
/// lengthen the lock, so a phone or computer left unlocked must not be enough.
/// (Opening the app already needed a key; this guards the screen that can
/// remove that need.) Apps route `/advanced_security` here.
class GuardedAdvancedSecurityScreen extends StatelessWidget {
  const GuardedAdvancedSecurityScreen({super.key, this.child = const AdvancedSecurityScreen()});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppLockGate(
      reason: FhseLocalizations.of(context).advancedSecurityAuthReason,
      child: child,
    );
  }
}
