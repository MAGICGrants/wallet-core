import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show OpenAliasMode, SeedCheckStore;
import 'package:wallet_fiat/wallet_fiat.dart' show FiatApiMode, FiatRateModel;
import 'package:wallet_infra/wallet_infra.dart' show TorMode, TorSettingsService, log, LogLevel;

import 'security_checklist_card.dart';

/// The steps of "Secure your wallet", in the order they are shown.
enum SecurityStep {
  /// The user typed the asked-for seed words correctly within the last
  /// [SeedCheckState.validFor].
  verifySeed,

  /// An automatic backup location is on: iCloud, Android Auto Backup or a
  /// sync folder. A saved backup file does not count.
  autoBackup,

  /// Tor is on, built in or external.
  tor,

  /// Neither the price source nor OpenAlias goes over clearnet: each is
  /// Tor-only or off.
  privateLookups,

  /// Security keys guard the wallet.
  securityKeys,
}

/// Where each [SecurityStep] stands, read from the settings behind it.
///
/// None of those settings notifies on change, so the home calls [refresh] when
/// it opens, when the app comes back to the foreground, and after the user
/// returns from a step. The two platform-bound steps are asked through
/// [autoBackupOn] and [securityKeysOn], which the app supplies from the
/// packages that own them; either answers null where its step does not apply,
/// and the step is left out.
class SecurityChecklist extends ChangeNotifier {
  SecurityChecklist({
    required this.autoBackupOn,
    required this.securityKeysOn,
    this.canVerifySeed,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<bool?> Function() autoBackupOn;
  final Future<bool?> Function() securityKeysOn;

  /// Whether this wallet has seed words the user can be asked for. False
  /// leaves [SecurityStep.verifySeed] out, for a wallet whose original words
  /// were never kept. Null means always.
  final Future<bool> Function()? canVerifySeed;
  final DateTime Function() _clock;

  Map<SecurityStep, bool>? _steps;
  Future<void>? _refreshing;
  bool _again = false;
  bool _disposed = false;

  /// The steps that apply here and whether each is done; null until the first
  /// [refresh] finishes.
  Map<SecurityStep, bool>? get steps => _steps;

  /// Whether there is nothing left to do (and so nothing to show).
  bool get allDone => _steps != null && _steps!.values.every((done) => done);

  /// Re-reads every step. A call while one is running runs once more after it,
  /// so a change made in between is never missed.
  Future<void> refresh() {
    if (_refreshing != null) {
      _again = true;
      return _refreshing!;
    }
    return _refreshing = _run().whenComplete(() => _refreshing = null);
  }

  Future<void> _run() async {
    do {
      _again = false;
      final Map<SecurityStep, bool> next;
      try {
        next = await _read();
      } catch (e) {
        // A setting that cannot be read leaves the card as it was.
        log(LogLevel.warn, 'Security checklist could not be read: ${e.runtimeType}');
        return;
      }
      if (_disposed) return;
      if (!mapEquals(next, _steps)) {
        _steps = next;
        notifyListeners();
      }
    } while (_again && !_disposed);
  }

  Future<Map<SecurityStep, bool>> _read() async {
    final seedProbe = canVerifySeed;
    final seedAsked = seedProbe == null || (await _ask(seedProbe) ?? false);
    final seed = seedAsked ? (await SeedCheckStore.read()).isCurrent(_clock()) : null;
    final backup = await _ask(autoBackupOn);
    final tor = TorSettingsService.sharedInstance;
    await tor.ensureLoaded();
    final fiat = await FiatRateModel.loadFiatApiMode();
    final alias = await OpenAliasMode.load();
    final keys = await _ask(securityKeysOn);
    return {
      SecurityStep.verifySeed: ?seed,
      SecurityStep.autoBackup: ?backup,
      SecurityStep.tor: tor.torMode != TorMode.disabled,
      SecurityStep.privateLookups: fiat != FiatApiMode.clearnet && alias != OpenAliasMode.clearnet,
      SecurityStep.securityKeys: ?keys,
    };
  }

  /// A step whose state cannot be read is left out rather than shown as
  /// undone, which would nag about something the user may have turned on.
  static Future<bool?> _ask(Future<bool?> Function() probe) async {
    try {
      return await probe();
    } catch (e) {
      log(LogLevel.warn, 'Security checklist step could not be read: ${e.runtimeType}');
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Translated strings for the checklist card.
class SecurityChecklistLabels {
  final String title;
  final String Function(int done, int total) progress;
  final String verifySeed;
  final String autoBackup;
  final String tor;
  final String privateLookups;
  final String securityKeys;

  const SecurityChecklistLabels({
    required this.title,
    required this.progress,
    required this.verifySeed,
    required this.autoBackup,
    required this.tor,
    required this.privateLookups,
    required this.securityKeys,
  });

  String of(SecurityStep step) => switch (step) {
    SecurityStep.verifySeed => verifySeed,
    SecurityStep.autoBackup => autoBackup,
    SecurityStep.tor => tor,
    SecurityStep.privateLookups => privateLookups,
    SecurityStep.securityKeys => securityKeys,
  };
}

/// The home's checklist card for [checklist], or null while it is loading and
/// once every step is done, so the home leaves the slot out. Tapping an open
/// step runs [onStep] and reads the checklist again when it returns.
Widget? securityChecklistCard({
  required SecurityChecklist checklist,
  required SecurityChecklistLabels labels,
  required Future<void> Function(SecurityStep step) onStep,
}) {
  final steps = checklist.steps;
  if (steps == null || checklist.allDone) return null;
  return SecurityChecklistCard(
    title: labels.title,
    progressLabel: labels.progress,
    items: [
      for (final MapEntry(key: step, value: done) in steps.entries)
        ChecklistItem(
          label: labels.of(step),
          done: done,
          onTap: () async {
            await onStep(step);
            await checklist.refresh();
          },
        ),
    ],
  );
}
