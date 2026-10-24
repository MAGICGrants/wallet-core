import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_ui/wallet_ui.dart';

import '../fhse_vault.dart' show KeyVerification, SecurityKeyAuthenticator;
import '../parity/hmac_parity.dart';
import '../security_key_service.dart';

/// Debug builds only: reads a key's hmac-secret over [HmacParity.salt] through
/// this platform's backend, to compare with other platforms and with
/// `tool/hmac_parity.sh` (libfido2). Reached from Advanced Security.
///
/// Developer tooling, so its text is not localized. It never touches the
/// wallet, its FHSE file or its keys' labels.
class HmacParityScreen extends StatefulWidget {
  const HmacParityScreen({super.key, this.authenticator, this.systemPrompts, this.status});

  /// For tests; [SecurityKeyService.instance] otherwise.
  final SecurityKeyAuthenticator? authenticator;
  final bool? systemPrompts;
  final Stream<SecurityKeyStatus>? status;

  @override
  State<HmacParityScreen> createState() => _HmacParityScreenState();
}

class _HmacParityScreenState extends State<HmacParityScreen> {
  final _pin = TextEditingController();
  final _credential = TextEditingController();
  late final HmacParity _parity;
  late final bool _systemPrompts;
  StreamSubscription<SecurityKeyStatus>? _statusSub;

  bool _fingerprint = false;
  bool _busy = false;
  SecurityKeyStatus? _status;
  String? _error;
  HmacParityResult? _result;

  @override
  void initState() {
    super.initState();
    _parity = HmacParity(widget.authenticator ?? SecurityKeyService.instance);
    _systemPrompts = widget.systemPrompts ?? SecurityKeyService.instance.systemPrompts;
    _statusSub = (widget.status ?? SecurityKeyService.instance.status).listen((status) {
      if (mounted) setState(() => _status = status);
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _pin.dispose();
    _credential.dispose();
    super.dispose();
  }

  KeyVerification? _verification() {
    if (_systemPrompts) return const KeyVerification.system();
    if (_fingerprint) return const KeyVerification.builtIn();
    final pin = _pin.text;
    if (pin.isEmpty) {
      setState(() => _error = 'Enter the key’s PIN.');
      return null;
    }
    return KeyVerification.pin(pin);
  }

  Future<void> _run(Future<HmacParityResult> Function(KeyVerification) call) async {
    final verification = _verification();
    if (verification == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _status = null;
    });
    try {
      final result = await call(verification);
      if (!mounted) return;
      setState(() {
        _result = result;
        _credential.text = base64Encode(result.credentialId);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _enroll() => _run(_parity.enroll);

  void _assert() {
    final id = HmacParity.parseCredentialId(_credential.text);
    if (id == null) {
      setState(() => _error = 'Paste a credential id (base64 or hex).');
      return;
    }
    _run((verification) => _parity.assertCredential(id, verification));
  }

  Future<void> _copy() async {
    final result = _result;
    if (result == null) return;
    await Clipboard.setData(ClipboardData(text: '${result.report()}\n\n${result.libfido2Command}'));
    if (mounted) showBrandToast(context, 'Copied');
  }

  String get _statusText => switch (_status) {
    SecurityKeyStatus.waitingForKey => 'Connect the security key.',
    SecurityKeyStatus.keyConnected => 'Key connected.',
    SecurityKeyStatus.processing => 'Working…',
    SecurityKeyStatus.touchNeeded => 'Touch the security key.',
    SecurityKeyStatus.fingerprintNeeded => 'Touch the fingerprint sensor.',
    null => 'Working…',
  };

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: BrandScreenHeader(
                    onBack: () => Navigator.pop(context),
                    center: Text(
                      'hmac-secret parity test',
                      style: BrandText.appBar.copyWith(fontSize: 16),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        BrandCard(
                          padding: const EdgeInsets.all(BrandSpacing.lg),
                          child: Text(
                            'Debug builds only. Reads a security key’s hmac-secret over a fixed, '
                            'published test salt (never a wallet’s) through ${HmacParity.platformBackend}. '
                            'Create a test credential here, or paste one made on another device or '
                            'by tool/hmac_parity.sh, and compare the hmac-secret lines: they must '
                            'match byte for byte. This screen does not touch the wallet.',
                            style: BrandText.body,
                          ),
                        ),
                        const SizedBox(height: BrandSpacing.lg),
                        if (_systemPrompts)
                          Text(
                            'Windows asks for the PIN or fingerprint itself.',
                            style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
                          )
                        else ...[
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('Use the key’s fingerprint', style: BrandText.body),
                            value: _fingerprint,
                            onChanged: _busy ? null : (v) => setState(() => _fingerprint = v),
                          ),
                          if (!_fingerprint)
                            BrandTextField(
                              controller: _pin,
                              label: 'Security key PIN',
                              obscureText: true,
                              keyboardType: TextInputType.visiblePassword,
                            ),
                        ],
                        const SizedBox(height: BrandSpacing.md),
                        BrandButton(
                          label: 'Create credential',
                          icon: Icons.add,
                          loading: _busy,
                          onPressed: _busy ? () {} : _enroll,
                        ),
                        const SizedBox(height: BrandSpacing.lg),
                        BrandTextField(
                          controller: _credential,
                          label: 'Credential id (base64 or hex)',
                          maxLines: 3,
                        ),
                        const SizedBox(height: BrandSpacing.md),
                        BrandButton.outline(
                          label: 'Read credential',
                          icon: Icons.key_outlined,
                          loading: _busy,
                          onPressed: _busy ? () {} : _assert,
                        ),
                        if (_busy) ...[
                          const SizedBox(height: BrandSpacing.md),
                          Text(_statusText, style: BrandText.body, textAlign: TextAlign.center),
                          TextButton(
                            onPressed: () => SecurityKeyService.instance.cancel(),
                            child: const Text('Cancel'),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: BrandSpacing.md),
                          Text(_error!, style: BrandText.body.copyWith(color: BrandColors.error)),
                        ],
                        if (result != null) ...[
                          const SizedBox(height: BrandSpacing.lg),
                          BrandCard(
                            padding: const EdgeInsets.all(BrandSpacing.lg),
                            child: SelectableText(
                              '${result.report()}\n\n${result.libfido2Command}',
                              style: BrandText.body.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                          const SizedBox(height: BrandSpacing.sm),
                          BrandButton.outline(label: 'Copy', icon: Icons.copy, onPressed: _copy),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
