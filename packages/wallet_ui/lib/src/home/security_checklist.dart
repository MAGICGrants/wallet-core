import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show OpenAliasMode, SeedCheckStore;
import 'package:wallet_fiat/wallet_fiat.dart' show FiatApiMode, FiatRateModel;
import 'package:wallet_infra/wallet_infra.dart'
    show LogLevel, SettingsKeys, SharedPreferencesService, TorMode, TorSettingsService, log;

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

/// What the user chose for the checklist in Settings: whether the home shows
/// it at all, and the steps it leaves out. Kept on this device, like the
/// app's other settings.
///
/// A step left out stays out whatever its setting does later: turning off a
/// feature the user set up does not bring the card back for it.
@immutable
class SecurityChecklistSettings {
  const SecurityChecklistSettings({this.showOnHome = true, this.stepsOff = const {}});

  final bool showOnHome;
  final Set<SecurityStep> stepsOff;

  /// Tells every [SecurityChecklist] a save happened, so a home already on
  /// screen (beside Settings on desktop) updates without being reopened.
  static final Listenable changes = _changes;
  static final _changes = ValueNotifier<int>(0);

  static Future<SecurityChecklistSettings> load() async {
    final shown = await SharedPreferencesService.get<bool>(SettingsKeys.securityChecklistShown);
    final off = await SharedPreferencesService.get<List<String>>(
      SettingsKeys.securityChecklistStepsOff,
    );
    return SecurityChecklistSettings(
      showOnHome: shown ?? true,
      // A name this version does not know (a step since removed) is dropped.
      stepsOff: {
        for (final step in SecurityStep.values)
          if (off?.contains(step.name) ?? false) step,
      },
    );
  }

  Future<void> save() async {
    await SharedPreferencesService.set<bool>(SettingsKeys.securityChecklistShown, showOnHome);
    await SharedPreferencesService.set<List<String>>(SettingsKeys.securityChecklistStepsOff, [
      for (final step in SecurityStep.values)
        if (stepsOff.contains(step)) step.name,
    ]);
    _changes.value++;
  }

  @override
  bool operator ==(Object other) =>
      other is SecurityChecklistSettings &&
      other.showOnHome == showOnHome &&
      setEquals(other.stepsOff, stepsOff);

  @override
  int get hashCode => Object.hash(showOnHome, Object.hashAllUnordered(stepsOff));
}

/// Where each [SecurityStep] stands, read from the settings behind it, and
/// what the user chose to see of it ([SecurityChecklistSettings]).
///
/// The steps' own settings do not notify on change, so the home calls
/// [refresh] when it opens, when the app comes back to the foreground, and
/// after the user returns from a step; a saved [SecurityChecklistSettings]
/// refreshes it by itself. The two platform-bound steps are asked through
/// [autoBackupOn] and [securityKeysOn], which the app supplies from the
/// packages that own them; either answers null where its step does not apply,
/// and the step is left out.
class SecurityChecklist extends ChangeNotifier {
  SecurityChecklist({
    required this.autoBackupOn,
    required this.securityKeysOn,
    this.canVerifySeed,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    SecurityChecklistSettings.changes.addListener(_settingsSaved);
  }

  final Future<bool?> Function() autoBackupOn;
  final Future<bool?> Function() securityKeysOn;

  /// Whether this wallet has seed words the user can be asked for. False
  /// leaves [SecurityStep.verifySeed] out, for a wallet whose original words
  /// were never kept. Null means always.
  final Future<bool> Function()? canVerifySeed;
  final DateTime Function() _clock;

  Map<SecurityStep, bool>? _steps;
  SecurityChecklistSettings _settings = const SecurityChecklistSettings();
  Future<void>? _refreshing;
  bool _again = false;
  bool _disposed = false;

  /// Every step that applies here and whether each is done, the ones the user
  /// left out of the home included; null until the first [refresh] finishes.
  Map<SecurityStep, bool>? get steps => _steps;

  /// What the user chose in Settings, as of the last [refresh].
  SecurityChecklistSettings get settings => _settings;

  /// The steps the home lists: [steps] without the ones the user left out.
  Map<SecurityStep, bool>? get homeSteps {
    final steps = _steps;
    if (steps == null) return null;
    return {
      for (final MapEntry(key: step, value: done) in steps.entries)
        if (!_settings.stepsOff.contains(step)) step: done,
    };
  }

  /// Whether the home's steps are all done (or all left out), so there is
  /// nothing left to do.
  bool get allDone => homeSteps?.values.every((done) => done) ?? false;

  /// Whether the home shows the card: read, wanted, and something left to do.
  bool get shownOnHome => _steps != null && _settings.showOnHome && !allDone;

  void _settingsSaved() => refresh();

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
      final SecurityChecklistSettings settings;
      try {
        next = await _read();
        settings = await SecurityChecklistSettings.load();
      } catch (e) {
        // A setting that cannot be read leaves the card as it was.
        log(LogLevel.warn, 'Security checklist could not be read: ${e.runtimeType}');
        return;
      }
      if (_disposed) return;
      if (!mapEquals(next, _steps) || settings != _settings) {
        _steps = next;
        _settings = settings;
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
    SecurityChecklistSettings.changes.removeListener(_settingsSaved);
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

/// The home's checklist card for [checklist], or null while it is loading,
/// once every step it lists is done, and when the user turned it off, so the
/// home leaves the slot out. Tapping an open step runs [onStep] and reads the
/// checklist again when it returns.
Widget? securityChecklistCard({
  required SecurityChecklist checklist,
  required SecurityChecklistLabels labels,
  required Future<void> Function(SecurityStep step) onStep,
}) {
  final steps = checklist.homeSteps;
  if (steps == null || !checklist.shownOnHome) return null;
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
