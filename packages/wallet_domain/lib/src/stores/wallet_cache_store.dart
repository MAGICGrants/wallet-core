import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:wallet_infra/wallet_infra.dart';

/// Per-coin encrypted cache of display data; balances, transaction history,
/// raw tx blobs, per-scripthash state.
///
/// Encrypted at rest with the wallet password (AES-256-GCM via
/// [WalletFileCrypto]), the same scheme as [SeedStore]. Lives at
/// `${appDir}/<coin>_cache`.
///
/// Note what this is for, because it differs by coin: Monero's own
/// wallet file already holds an encrypted cache of balances and history, so
/// here the store mainly serves display state needed before that file is
/// opened. For coins with no native encrypted cache (Bitcoin, Ethereum) it
/// is the only thing standing between this data and the disk.
class WalletCacheStore {
  WalletCacheStore._();

  static Future<File> _file(String coinSymbol) async {
    final appDir = await getAppDir();
    return File('${appDir.path}/${coinSymbol.toLowerCase()}_cache');
  }

  /// Decrypts and returns the cache.
  ///
  /// Returns an empty map when there is no file, the blob is not a valid
  /// envelope, or it cannot be decrypted. A cache is derived data; an
  /// unreadable one must degrade to "no cache" and re-sync, never throw into
  /// a caller that is just trying to show a balance.
  static Future<Map<String, dynamic>> load(String coinSymbol, String password) async {
    final file = await _file(coinSymbol);
    if (!await file.exists()) return {};

    final blob = await file.readAsString();
    if (!WalletFileCrypto.isValidEncryptedBlobBase64(blob)) return {};

    // Captured out here on purpose: static state does not cross into the
    // spawned isolate, so the injected backend would revert to the default
    // inside and every decrypt would fail.
    final kdf = WalletFileCrypto.kdf;

    try {
      final json = await Isolate.run(
        () => WalletFileCrypto.decryptFromBase64(blob, password, kdf: kdf),
      );
      final decoded = jsonDecode(json);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  /// Encrypts and writes the cache.
  ///
  /// **Off the calling isolate**, for the same reason [load] is, and it was
  /// not, which made the pair asymmetric in the expensive direction. The
  /// envelope's AES-256-GCM is pure Dart (`GCMBlockCipher(AESEngine())`)
  /// whichever KDF is installed, so a 58 KiB cache measured at ~36 ms of
  /// encryption on an M-series Mac under the VM, before the key derivation on
  /// top. That ran on whatever isolate called it, which for the app is the UI
  /// isolate: a visible jank, on a timer.
  ///
  /// The gate on `cachePut` means this now happens when something actually
  /// changed rather than every refresh cycle, but a send still triggers one and
  /// there is no reason to pay for it on the isolate drawing the screen.
  static Future<void> save(String coinSymbol, Map<String, dynamic> data, String password) async {
    final file = await _file(coinSymbol);
    final json = jsonEncode(data);
    // Captured out here on purpose: static state does not cross into the
    // spawned isolate, so the injected backend would revert to the default
    // inside, the same trap [load] documents.
    final kdf = WalletFileCrypto.kdf;
    final blob = await Isolate.run(
      () => WalletFileCrypto.encryptToBase64(json, password, kdf: kdf),
    );
    await file.writeAsString(blob);
  }

  static Future<void> delete(String coinSymbol) async {
    final file = await _file(coinSymbol);
    if (await file.exists()) await file.delete();
  }
}
