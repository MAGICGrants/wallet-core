import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Preference keys common to every app built on wallet-core. Shared so the two
/// apps can never drift on a key string (a typo would silently orphan a
/// setting). Apps add their own keys in an app-side class alongside these.
///
/// Wallet-scoped keys (connection endpoint, restore height, subaddress state)
/// are NOT here; those are namespaced per coin by `CryptoWallet.prefKey`.
class SettingsKeys {
  const SettingsKeys._();

  static const String language = 'language';
  static const String theme = 'theme';
  static const String fiatCurrency = 'fiatCurrency';
  static const String fiatApiMode = 'fiatApiMode';
  static const String fiatRate = 'fiatRate';
  // Marks that the fiat API was turned off *by* disabling global Tor (not by the
  // user), so re-enabling Tor can restore it.
  static const String fiatAutoDisabledByTor = 'fiatAutoDisabledByTor';

  /// How OpenAlias names are looked up: an `OpenAliasMode` name.
  static const String openAliasMode = 'openAliasMode';
  // The unit the send screen's amount was last typed in: `coin` or `fiat`.
  static const String sendAmountUnit = 'sendAmountUnit';

  /// Whether a background run announces the payments it finds. It decides
  /// nothing about whether runs happen; [syncFrequency] does.
  static const String notificationsEnabled = 'notificationsEnabled';

  /// "Sync Frequency": a [SyncFrequency] name.
  static const String syncFrequency = 'syncFrequency';
  static const String backgroundSyncIntervalMinutes = 'backgroundSyncIntervalMinutes';

  /// The logging setting ("Diagnostic Logs"): logging on or off. Stored
  /// under its old name, so the setting survives the rename.
  static const String loggingEnabled = 'verboseLoggingEnabled';
  static const String contacts = 'contacts';
  static const String torMode = 'torMode';
  static const String torSocksPort = 'torSocksPort';
  static const String torUseOrbot = 'torUseOrbot';
  // Store review (StoreReview): a send made the user eligible, and the day the
  // store was last asked. The day, not the moment -- this store is plaintext.
  static const String storeReviewEligible = 'storeReviewEligible';
  static const String storeReviewLastAskedDay = 'storeReviewLastAskedDay';
}

/// Non-secret key/value storage.
///
/// Injected for the same reason as [DirectoryProvider]: `shared_preferences`
/// is a plugin, so anything calling it directly cannot be exercised under
/// `flutter test`. Nearly every persisted wallet setting goes through here.
///
/// Nothing secret belongs in this store; it is plaintext on every platform.
/// Connection endpoints, restore heights and subaddress indices live here and
/// are linkable metadata. Keys and passwords go to `secureStorage`.
abstract class PreferenceStore {
  const PreferenceStore();

  Future<Object?> read(String key);

  Future<void> write(String key, Object value);

  Future<void> remove(String key);
}

class SharedPreferencesStore extends PreferenceStore {
  const SharedPreferencesStore();

  @override
  Future<Object?> read(String key) async => (await SharedPreferences.getInstance()).get(key);

  @override
  Future<void> write(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    switch (value) {
      case final bool v:
        await prefs.setBool(key, v);
      case final String v:
        await prefs.setString(key, v);
      case final int v:
        await prefs.setInt(key, v);
      case final double v:
        await prefs.setDouble(key, v);
      case final List<String> v:
        await prefs.setStringList(key, v);
      default:
        throw ArgumentError('Unsupported preference type: ${value.runtimeType}');
    }
  }

  @override
  Future<void> remove(String key) async => (await SharedPreferences.getInstance()).remove(key);
}

/// In-memory store. For tests.
// `MemoryPreferenceStore` lives in `package:wallet_infra/testing.dart`.

/// Static facade over the installed [PreferenceStore].
///
/// Keeps the shape the apps already call (`SharedPreferencesService.get<bool>`)
/// so their call sites port unchanged.
class SharedPreferencesService {
  SharedPreferencesService._();

  static PreferenceStore store = const SharedPreferencesStore();

  static void resetForTesting() => store = const SharedPreferencesStore();

  /// Returns null when the key is absent **or** holds a different type.
  ///
  /// The inherited implementation switched on the type literal `T`, which
  /// needed `// ignore: type_literal_in_constant_pattern` at every branch and
  /// silently returned null for `List<String>`. Filtering the read value by
  /// type is both shorter and total.
  static Future<T?> get<T>(String key) async {
    final value = await store.read(key);
    if (value is T) return value;

    // A string list does not arrive as a `List<String>`. `shared_preferences`
    // decodes it off the platform channel into a `List<dynamic>` and casts on
    // the way out of `getStringList`, so `value is List<String>` is false for
    // every list ever written — which silently turned "the user has contacts"
    // into "the user has none". Casting here rather than at the call site keeps
    // `get<List<String>>` meaning what it says.
    if (value is List && <String>[] is T) {
      final strings = value.whereType<String>().toList(growable: false);
      return strings.length == value.length ? strings as T : null;
    }

    return null;
  }

  static Future<void> set<T>(String key, T value) async {
    if (value == null) return remove(key);
    await store.write(key, value as Object);
  }

  static Future<void> remove(String key) => store.remove(key);
}

/// How the wallets sync while nobody has the app open ("Sync Frequency").
///
/// What each choice runs, per platform and per coin, is laid out in
/// wallet_background's README.
enum SyncFrequency {
  /// Android only: the Continuous Sync foreground service keeps every coin with
  /// a server connected and syncing, behind a persistent notification.
  continuous,

  /// Scheduled background runs: light checks on any network, and full scans
  /// (a Monero node) only while charging.
  periodic,

  /// Nothing runs without the user; wallets sync only while the app is open.
  off;

  /// The choices this platform offers, in the order the setting lists them.
  /// Desktop has no background runs at all.
  static List<SyncFrequency> get available => switch (syncFrequencyPlatform) {
    'android' => values,
    'ios' => const [periodic, off],
    _ => const [off],
  };
}

/// The platform [SyncFrequency.available] answers for. Tests run on a desktop
/// host and set it to the phone they are modelling.
@visibleForTesting
String syncFrequencyPlatform = Platform.operatingSystem;

/// The user's [SyncFrequency], or [SyncFrequency.periodic] when nothing is
/// stored. A choice this platform cannot run (Continuous restored onto an
/// iPhone, say) reads as the nearest one it can.
Future<SyncFrequency> loadSyncFrequency() async {
  final stored = await SharedPreferencesService.get<String>(SettingsKeys.syncFrequency);
  final value = SyncFrequency.values.asNameMap()[stored] ?? SyncFrequency.periodic;
  final available = SyncFrequency.available;
  if (available.contains(value)) return value;
  return available.contains(SyncFrequency.periodic) ? SyncFrequency.periodic : SyncFrequency.off;
}

Future<void> saveSyncFrequency(SyncFrequency frequency) =>
    SharedPreferencesService.set<String>(SettingsKeys.syncFrequency, frequency.name);

/// Moves the two old toggles (Background Sync and Continuous Sync, which lived
/// on the Monero node setup screen) onto [SyncFrequency], once. Call at launch,
/// before anything reads the setting.
///
/// Continuous Sync on becomes [SyncFrequency.continuous]; Background Sync or
/// notifications on become [SyncFrequency.periodic]. An existing install with
/// all of them off stays [SyncFrequency.off]: Periodic would start background
/// connections to its servers that it never had. A fresh install gets the
/// default, written down so a later launch (with a wallet by then) does not
/// mistake it for an existing install with everything off.
Future<void> migrateLegacySyncSettings({required bool existingInstall}) async {
  const backgroundKey = 'backgroundSyncEnabled';
  const continuousKey = 'foregroundSyncEnabled';
  if (await SharedPreferencesService.get<String>(SettingsKeys.syncFrequency) == null) {
    final background = await SharedPreferencesService.get<bool>(backgroundKey) ?? false;
    final continuous = await SharedPreferencesService.get<bool>(continuousKey) ?? false;
    final notifications =
        await SharedPreferencesService.get<bool>(SettingsKeys.notificationsEnabled) ?? false;
    await saveSyncFrequency(
      continuous
          ? SyncFrequency.continuous
          : (background || notifications)
          ? SyncFrequency.periodic
          : existingInstall
          ? SyncFrequency.off
          : SyncFrequency.periodic,
    );
  }
  await SharedPreferencesService.remove(backgroundKey);
  await SharedPreferencesService.remove(continuousKey);
}

/// Whether anything runs without the user: any [SyncFrequency] but off.
///
/// Every such run is view-only (Monero's view-only background copy, the LWS
/// view key, a Bitcoin xpub, an Ethereum address), so while this is on that
/// material is kept ready, whether or not security keys are.
Future<bool> unattendedRunsEnabled() async => await loadSyncFrequency() != SyncFrequency.off;
