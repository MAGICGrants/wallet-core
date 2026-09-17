import 'dart:io';

import '../paths.dart';
import '../storage/preferences.dart';
import '../storage/wallet_password.dart';

/// In-memory secret store. **Tests only**; it offers no protection whatsoever.
class MemorySecretStore extends SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// In-memory preference store. **Tests only.**
class MemoryPreferenceStore extends PreferenceStore {
  final Map<String, Object> values = {};

  @override
  Future<Object?> read(String key) async => values[key];

  /// A list is stored as `List<dynamic>`, which is what `shared_preferences`
  /// hands back: it decodes off the platform channel untyped and casts inside
  /// `getStringList`. Keeping a `List<String>` here made a reader that tested
  /// `value is List<String>` pass in tests and fail on a device.
  @override
  Future<void> write(String key, Object value) async =>
      values[key] = value is List<String> ? List<dynamic>.from(value) : value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// Serves every directory from one root. **Tests only.**
class FixedDirectories extends DirectoryProvider {
  const FixedDirectories(this.root);

  final Directory root;

  @override
  Future<Directory> applicationDocuments() async => root;

  @override
  Future<Directory?> externalStorage() async => root;

  /// On every platform, including Linux and Windows. See [DirectoryProvider.appRoot].
  @override
  Future<Directory?> appRoot() async => root;
}
