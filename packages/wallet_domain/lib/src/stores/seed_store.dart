import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:wallet_infra/wallet_infra.dart';

import '../seed/seed.dart';

/// On-disk store for the user's seed, encrypted with the wallet password
/// (AES-256-GCM via [WalletFileCrypto]). Lives beside the wallet files at
/// `${appDir}/master_seed`.
///
/// Purpose: lets a coin be added to an existing wallet in a later app version.
/// On unlock the wallet manager reads the seed and bootstraps any registered
/// coin whose own wallet file is missing.
///
/// **Format v2 tags the seed's encoding.** v1 assumed BIP39, which is
/// set by the app's seed policy. v1 blobs still read, as BIP39.
/// **v3 stores the [RestorePoint]** so a height restore re-bootstraps from the
/// same height; v1/v2 carried only a date and read back as [RestorePoint.date].
class SeedStore {
  SeedStore._();

  static const _fileName = 'master_seed';
  static const _currentVersion = 3;

  static Future<File> _file() async {
    final appDir = await getAppDir();
    return File('${appDir.path}/$_fileName');
  }

  static Future<bool> exists() async => (await _file()).exists();

  static Future<void> save({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {
    final body = jsonEncode({
      'v': _currentVersion,
      'format': seed.format.name,
      'mnemonic': seed.mnemonic,
      if (seed.passphrase.isNotEmpty) 'passphrase': seed.passphrase,
      'restore': from.toJson(),
    });
    final file = await _file();
    await file.writeAsString(await WalletFileCrypto.encryptToBase64(body, password));
  }

  /// Decrypts and returns the stored seed, or null when no file exists.
  ///
  /// Throws on a decryption or format error, which the caller should treat as
  /// "wrong password".
  static Future<({SeedSource seed, RestorePoint from})?> load(String password) async {
    final file = await _file();
    if (!await file.exists()) return null;
    final blob = await file.readAsString();
    // Captured out here: static state does not cross into the spawned isolate.
    final kdf = WalletFileCrypto.kdf;
    return Isolate.run(() => _decrypt(blob, password, kdf));
  }

  static Future<({SeedSource seed, RestorePoint from})> _decrypt(
    String blob,
    String password,
    Pbkdf2Kdf kdf,
  ) async {
    final body =
        jsonDecode(await WalletFileCrypto.decryptFromBase64(blob, password, kdf: kdf))
            as Map<String, dynamic>;

    final mnemonic = body['mnemonic'] as String;
    final passphrase = body['passphrase'] as String? ?? '';

    // v1 predates the format tag and was always BIP39.
    final version = body['v'] as int? ?? 1;
    final formatName = version >= 2 ? body['format'] as String? : SeedFormat.bip39.name;

    final format = SeedFormat.values.firstWhere(
      (f) => f.name == formatName,
      orElse: () => throw FormatException('Unknown seed format: $formatName'),
    );

    final seed = switch (format) {
      SeedFormat.bip39 => Bip39Seed(mnemonic, passphrase: passphrase),
      SeedFormat.polyseed => PolyseedSeed(mnemonic, passphrase: passphrase),
      SeedFormat.moneroLegacy => MoneroLegacySeed(mnemonic, passphrase: passphrase),
    };

    // v3 stores the restore point; v1/v2 carried only a date.
    final restoreJson = body['restore'] as Map<String, dynamic>?;
    final from = restoreJson != null
        ? RestorePoint.fromJson(restoreJson)
        : RestorePoint.date(
            DateTime.tryParse(body['restore_date_iso'] as String? ?? '') ?? DateTime.now(),
          );

    return (seed: seed, from: from);
  }

  static Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
