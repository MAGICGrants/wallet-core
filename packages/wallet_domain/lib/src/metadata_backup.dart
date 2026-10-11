import 'crypto_wallet.dart';
import 'seed/seed.dart';
import 'tx/tx_details.dart';

/// What a backup holds for one outgoing payment, in the wallet's own terms.
class BackedUpPayment {
  const BackedUpPayment({required this.recipients, required this.txKey});

  /// Who the payment went to, change excluded.
  final List<TxRecipient> recipients;

  /// The transaction secret key as `Wallet_getTxKey` returns it (hex), or empty.
  final String txKey;
}

/// The seed-keyed metadata backup, as the rest of the core sees it.
///
/// The seam keeps `wallet_domain` free of the backup's format and storage, the
/// way [AliasResolver] keeps it free of OpenAlias: the app installs
/// `wallet_backup`'s service in `main()`, on the UI isolate only. Background
/// isolates leave it null, so nothing they do writes a backup file; they have
/// no seed to key one with anyway.
///
/// Every call is fire-and-forget from the caller's side. A backup that cannot
/// be written must never block a send, an unlock or an address-book edit.
abstract class MetadataBackup {
  static MetadataBackup? instance;

  /// Opens the backup for [seed] and syncs it: after an unlock that read the
  /// stored seed, and after [restored] from a seed, when it also starts a new
  /// device id and reads every location first.
  ///
  /// A 25-word seed has no backup (it *is* the spend key); the service records
  /// that it is unavailable and returns.
  Future<void> open(SeedSource seed, {required List<CryptoWallet> wallets, bool restored = false});

  /// Forgets the keys. The wallet is locked or closing.
  Future<void> close();

  /// The wallet is being deleted: removes every local copy (including
  /// Android's Auto Backup folder). Copies in iCloud stay; they are sealed and
  /// are what a later restore reads.
  Future<void> deleteLocal();

  /// The address book was saved.
  void contactsChanged();

  /// [wallet]'s transaction history was re-read.
  void historyChanged(CryptoWallet wallet);

  /// [wallet] just broadcast [txid]. Called right after the broadcast returns,
  /// as the plan's interim rule while monero_c cannot give the transaction
  /// keys before it.
  void outgoingPaymentSent(
    CryptoWallet wallet, {
    required String txid,
    required int accountIndex,
    required BigInt fee,
    required List<TxRecipient> recipients,
    required String txKey,
  });

  /// What the backup holds for [txid], for a history entry that lost its
  /// destinations or key (a wallet restored from its seed has neither).
  BackedUpPayment? outgoingPayment(CryptoWallet wallet, String txid);
}
