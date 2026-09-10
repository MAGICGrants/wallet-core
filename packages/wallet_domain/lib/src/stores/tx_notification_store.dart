import 'dart:convert';

import 'package:wallet_infra/wallet_infra.dart';

/// Record of which incoming transactions the user has already been told about.
///
/// Held in **secure storage**, not shared preferences, and deliberately not the
/// password-encrypted cache either.
///
/// Not preferences: these are real on-chain identifiers, and preferences are a
/// plaintext file that would tie the device to those exact transactions.
///
/// Not the encrypted cache: the UI, foreground service and background task are
/// separate isolates that all read and write this, so it needs a small slot that
/// is immediately durable. The cache costs 600k PBKDF2 rounds per read.
///
/// Limitation: on Linux every keystore key shares one read-modify-write JSON
/// blob, so a concurrent write can lose an update.
class TxNotificationState {
  const TxNotificationState({required this.cutoff, required this.announcedHashes});

  /// Unix seconds of the newest transaction already accounted for. Null when
  /// nothing has been recorded yet: a fresh install, or an upgrade from a build
  /// that tracked a plain transaction count.
  final int? cutoff;

  /// Recently announced transaction hashes, oldest first.
  final List<String> announcedHashes;

  static const empty = TxNotificationState(cutoff: null, announcedHashes: []);

  /// Redacted; this type is a list of transaction ids.
  @override
  String toString() => 'TxNotificationState(cutoff: $cutoff, ${announcedHashes.length} hashes)';
}

/// Per-coin store for [TxNotificationState].
///
/// The key is supplied by the caller rather than fixed, and callers pass
/// `CryptoWallet.prefKey('txNotificationState')`. That is what keeps Skylight on
/// the bare `txNotificationState` key it has already shipped while Spice gets
/// `xmr_`-prefixed keys per coin, so nobody has to migrate.
class TxNotificationStore {
  TxNotificationStore._();

  /// Reads the stored state, or [TxNotificationState.empty] if there is none.
  ///
  /// A failure here reads as "nothing recorded", which makes the caller reseed
  /// from the current chain. That direction is deliberate: the alternative to
  /// staying quiet is announcing a whole history at once.
  static Future<TxNotificationState> read(String key) async {
    try {
      final stored = await WalletSecrets.store.read(key);
      if (stored == null || stored.isEmpty) return TxNotificationState.empty;

      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      return TxNotificationState(
        cutoff: decoded['cutoff'] as int?,
        announcedHashes: (decoded['announcedHashes'] as List<dynamic>? ?? const []).cast<String>(),
      );
    } catch (e) {
      // Type only: a jsonDecode FormatException quotes its source, and the
      // source is a list of transaction ids.
      log(LogLevel.warn, 'Could not read transaction notification state: ${e.runtimeType}');
      return TxNotificationState.empty;
    }
  }

  static Future<void> write(String key, TxNotificationState state) async {
    try {
      await WalletSecrets.store.write(
        key,
        jsonEncode({'cutoff': state.cutoff, 'announcedHashes': state.announcedHashes}),
      );
    } catch (e) {
      log(LogLevel.warn, 'Could not save transaction notification state: ${e.runtimeType}');
    }
  }

  static Future<void> delete(String key) async {
    try {
      await WalletSecrets.store.delete(key);
    } catch (e) {
      log(LogLevel.warn, 'Could not clear transaction notification state: ${e.runtimeType}');
    }
  }
}
