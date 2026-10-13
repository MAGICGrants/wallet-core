import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show BiometricAuth, BiometricAuthResult;

import '../design/brand.dart';

/// Device re-authentication in front of a screen that reveals secrets (seed,
/// spend/view keys), applied at the route level so the wrapped screen — and its
/// secret-reading `initState` — is only built after the prompt passes.
///
/// Must wrap the route, not sit inside the screen's `build`: any route (Settings,
/// coin settings, a deep link) then goes through the same gate, and no caller can
/// be trusted to have authenticated first. Prompts only when app lock is on
/// (see [BiometricAuth.authenticateIfAppLockEnabled]), and only on mobile.
class ReauthGate extends StatefulWidget {
  final String reason;
  final Widget child;

  const ReauthGate({super.key, required this.reason, required this.child});

  @override
  State<ReauthGate> createState() => _ReauthGateState();
}

class _ReauthGateState extends State<ReauthGate> {
  bool _authed = false;

  @override
  void initState() {
    super.initState();
    _authenticate();
  }

  Future<void> _authenticate() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      if (mounted) setState(() => _authed = true);
      return;
    }
    final result = await BiometricAuth.authenticateIfAppLockEnabled(reason: widget.reason);
    if (!mounted) return;
    if (result == BiometricAuthResult.authenticated) {
      setState(() => _authed = true);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  Widget build(BuildContext context) => _authed
      ? widget.child
      // Opaque ground until authed, so nothing sensitive renders behind the prompt.
      : ColoredBox(color: BrandColors.paper, child: const SizedBox.expand());
}
