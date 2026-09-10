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
  static const String notificationsEnabled = 'notificationsEnabled';
  static const String backgroundSyncEnabled = 'backgroundSyncEnabled';
  static const String foregroundSyncEnabled = 'foregroundSyncEnabled';
  static const String backgroundSyncIntervalMinutes = 'backgroundSyncIntervalMinutes';
  static const String appLockEnabled = 'appLockEnabled';
  static const String verboseLoggingEnabled = 'verboseLoggingEnabled';
  static const String contacts = 'contacts';
  static const String torMode = 'torMode';
  static const String torSocksPort = 'torSocksPort';
  static const String torUseOrbot = 'torUseOrbot';
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
    return value is T ? value : null;
  }

  static Future<void> set<T>(String key, T value) async {
    if (value == null) return remove(key);
    await store.write(key, value as Object);
  }

  static Future<void> remove(String key) => store.remove(key);
}
