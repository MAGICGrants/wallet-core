import 'dart:async';
import 'dart:io';

import '../logging.dart';
import '../storage/preferences.dart';
import 'tor_service.dart';

enum TorMode { builtIn, external, disabled }

/// Preference keys owned by `wallet_infra`.
///
/// The string values must not change: they are what the shipped apps already
/// wrote, and renaming one silently resets that setting for every existing
/// user. App-level keys (theme, fiat currency, contacts…) stay in the app.
class InfraPreferenceKeys {
  InfraPreferenceKeys._();

  static const torMode = 'torMode';
  static const torSocksPort = 'torSocksPort';
  static const torUseOrbot = 'torUseOrbot';
  static const verboseLoggingEnabled = 'verboseLoggingEnabled';
}

class TorSettingsService {
  static final TorSettingsService sharedInstance = TorSettingsService._();

  TorSettingsService._();

  TorMode _torMode = TorMode.builtIn;
  String _socksPort = '9050';
  bool _useOrbot = false;

  TorMode get torMode => _torMode;
  String get socksPort => _socksPort;
  bool get useOrbot => _useOrbot;

  Future<void>? _loaded;

  /// Loads the persisted settings once, and only once.
  ///
  /// [loadSettings] is called at startup so the synchronous [torMode] getter is
  /// populated for the UI, but nothing awaits it. [getProxy] awaits this instead
  /// of trusting that ordering: a connection opened before startup finishes
  /// would otherwise route on the constructed defaults — built-in Tor on 9050 —
  /// whatever the user actually chose.
  Future<void> ensureLoaded() => _loaded ??= loadSettings();

  Future<void> loadSettings() async {
    final torModeString = await SharedPreferencesService.get<String>(InfraPreferenceKeys.torMode);
    final socksPortString = await SharedPreferencesService.get<String>(
      InfraPreferenceKeys.torSocksPort,
    );
    final useOrbotValue = await SharedPreferencesService.get<bool>(InfraPreferenceKeys.torUseOrbot);

    if (torModeString != null) _torMode = torModeFromString(torModeString);
    if (socksPortString != null) _socksPort = socksPortString;
    if (useOrbotValue != null) _useOrbot = useOrbotValue;
  }

  Future<void> save({required TorMode torMode, String? socksPort, bool? useOrbot}) async {
    _torMode = torMode;
    await SharedPreferencesService.set<String>(
      InfraPreferenceKeys.torMode,
      torModeToString(torMode),
    );

    if (socksPort != null) {
      _socksPort = socksPort;
      await SharedPreferencesService.set<String>(InfraPreferenceKeys.torSocksPort, socksPort);
    }

    if (useOrbot != null) {
      _useOrbot = useOrbot;
      await SharedPreferencesService.set<bool>(InfraPreferenceKeys.torUseOrbot, useOrbot);
    }
  }

  /// The SOCKS proxy to route through, or null when Tor is unavailable.
  ///
  /// Null rather than a hang: callers treat it as "Tor unavailable" and refuse
  /// to connect. Awaiting an unbounded `waitUntilConnected()` here means a
  /// Tor that never comes up blocks the caller forever instead of failing
  /// closed. Failing closed is the point; a connection that silently fell
  /// back to clearnet would be far worse than one that did not happen.
  Future<({InternetAddress host, int port})?> getProxy() async {
    await ensureLoaded();
    switch (_torMode) {
      case TorMode.builtIn:
        if (!await TorService.sharedInstance.waitUntilConnected()) return null;
        return TorService.sharedInstance.getProxyInfo();
      case TorMode.external:
        // `int.parse` threw here on an unusable saved port. That was inert
        // while nothing loaded the persisted settings; now that something does,
        // the throw escapes `_connectImpl` before it can latch
        // `_torRequirementBroken`, so the reconnect timer retried forever with
        // nothing shown to the user. Null is the "Tor unavailable" answer every
        // caller already handles.
        final port = int.tryParse(_socksPort.trim());
        if (port == null || port < 1 || port > 65535) {
          unawaited(log(LogLevel.error, 'External Tor SOCKS port is not usable: "$_socksPort"'));
          return null;
        }
        return (host: InternetAddress.loopbackIPv4, port: port);
      case TorMode.disabled:
        return null;
    }
  }

  /// Test-only: restores defaults between cases.
  void resetForTesting() {
    _torMode = TorMode.builtIn;
    _socksPort = '9050';
    _useOrbot = false;
    _loaded = null;
  }

  static String torModeToString(TorMode mode) => switch (mode) {
    TorMode.builtIn => 'builtIn',
    TorMode.external => 'external',
    TorMode.disabled => 'disabled',
  };

  /// Unknown values fall back to [TorMode.builtIn], the private default. A
  /// corrupt preference must never silently disable Tor.
  static TorMode torModeFromString(String modeString) => switch (modeString) {
    'external' => TorMode.external,
    'disabled' => TorMode.disabled,
    _ => TorMode.builtIn,
  };
}
