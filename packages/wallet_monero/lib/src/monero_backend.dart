/// The FFI seam.
///
/// `MoneroWallet` talks to monero_c only through this interface. That is the
/// single change that makes the Monero layer testable: with the real
/// implementation every method needs a dylib, a wallet file on disk and often a
/// network, so the paths that have actually caused bugs; a mode/file mismatch,
/// a restore onto an existing file, a double open; could only be exercised by
/// hand.
///
/// Two implementations: [FfiMoneroBackend] (the real calls) and
/// `FakeMoneroBackend` (scriptable, records calls, can be told to fail with a
/// specific `errorString`).
library;

/// Opaque handle to a native object.
///
/// Carries the FFI address for the real backend and a synthetic id for the
/// fake, so nothing above this layer ever sees a `Pointer`.
class NativeHandle {
  const NativeHandle(this.id);

  final int id;

  @override
  bool operator ==(Object other) => other is NativeHandle && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'NativeHandle($id)';
}

/// One transaction as monero_c reports it, before it becomes a `TxDetails`.
class NativeTxInfo {
  const NativeTxInfo({
    required this.direction,
    required this.hash,
    required this.amount,
    required this.fee,
    required this.timestamp,
    required this.blockHeight,
    required this.confirmations,
    required this.subaddrAccount,
    required this.subaddrIndex,
    required this.isPending,
    required this.isFailed,
    required this.paymentId,
    required this.txKey,
    this.destinations = const [],
  });

  final int direction;
  final String hash;

  /// Piconero. Never a double.
  final BigInt amount;
  final BigInt fee;

  final int timestamp;
  final int blockHeight;
  final int confirmations;
  final int subaddrAccount;
  final String subaddrIndex;

  /// Where an outgoing transaction paid, as `(address, piconero)` pairs.
  ///
  /// Recorded only for transactions this wallet sent itself: both wallet2 and
  /// LWSF write the destinations when they build the transaction, and neither
  /// can recover them from the chain afterwards. So this is empty for an
  /// incoming transaction, and for an outgoing one that was sent from another
  /// device on the same seed.
  final List<({String address, BigInt amount})> destinations;
  final bool isPending;
  final bool isFailed;
  final String paymentId;

  /// Monero transaction secret key, for the sender to prove the payment to a
  /// third party. Empty for incoming transactions and for any this wallet did
  /// not create; wallet2 only stores the key for transactions it signed.
  ///
  /// **Not the payment ID.** Both apps put this in `TxDetails.key` and Skylight
  /// shows it on the transaction screen for the user to copy; the relocation
  /// filled that field with `paymentId` instead, which proves nothing and is a
  /// linking identifier rather than a proof.
  final String txKey;
}

/// The four sync and balance figures, read together in one isolate hop.
class NativeWalletStats {
  const NativeWalletStats({
    required this.synchronized,
    required this.blockChainHeight,
    required this.balance,
    required this.unlockedBalance,
  });

  final bool synchronized;
  final int blockChainHeight;
  final BigInt balance;
  final BigInt unlockedBalance;
}

/// Which manager factory built a wallet.
///
/// LWS uses the LWSF manager, a full node uses wallet2. A wallet object is
/// bound to the factory that made it, which is why switching modes needs a
/// re-open rather than just a new address.
enum MoneroManagerKind { lws, node }

/// monero_c's `BackgroundSyncType`.
///
/// Wrapped in an enum because the C header's third constant is missing the
/// `Wallet` prefix the other two have; it is `BackgroundSync_CustomPassword`,
/// not `WalletBackgroundSync_CustomPassword`; so the inconsistency stops here
/// rather than being repeated at every call site.
enum MoneroBackgroundSyncType {
  off(0),

  /// The background cache is encrypted with the wallet password. **Not used
  /// here**: sharing the password is the whole thing this feature exists to
  /// avoid, and it is what LWSF hardcodes (`lwsf/src/wallet.h`) whether or not
  /// anything was set up.
  reusePassword(1),

  /// The background cache gets its own password, and its own keys file with no
  /// spend key in it at all. This is the one we use.
  customPassword(2);

  const MoneroBackgroundSyncType(this.value);

  final int value;

  static MoneroBackgroundSyncType fromValue(int value) =>
      values.firstWhere((t) => t.value == value, orElse: () => off);
}

abstract class MoneroBackend {
  const MoneroBackend();

  // ----- Manager -----

  Future<NativeHandle> getWalletManager(MoneroManagerKind kind);

  Future<bool> walletExists(NativeHandle manager, String path);

  Future<String> managerErrorString(NativeHandle manager);

  Future<int> blockchainHeight(NativeHandle manager);

  Future<NativeHandle> openWallet(
    NativeHandle manager, {
    required String path,
    required String password,
  });

  /// The word-list factory: 25-word legacy, or a BIP39 phrase already converted
  /// to one.
  ///
  /// [networkType] defaults to mainnet, which is what the apps ship. It is
  /// parameterised so the Monero test wallets can be built on stagenet from
  /// seeds committed in the clear, matching the polyseed factory below.
  Future<NativeHandle> recoveryWallet(
    NativeHandle manager, {
    required String mnemonic,
    required String seedOffset,
    required int restoreHeight,
    required String password,
    required String path,
    int networkType = 0,
  });

  /// The polyseed factory; the path that makes a polyseed restore possible.
  ///
  /// [newWallet] is the most dangerous flag in this layer: it tells the backend
  /// the seed has no history, so both backends skip the rescan. Set it for a
  /// seed that *does* have history and the wallet comes up permanently empty,
  /// with no error.
  Future<NativeHandle> createWalletFromPolyseed(
    NativeHandle manager, {
    required String mnemonic,
    required String seedOffset,
    required int restoreHeight,
    required String path,
    required String password,
    required bool newWallet,
    required int kdfRounds,
    int networkType = 0,
  });

  Future<bool> closeWallet(NativeHandle manager, NativeHandle wallet, {required bool store});

  // ----- Wallet -----

  Future<String> walletErrorString(NativeHandle wallet);
  Future<int> walletStatus(NativeHandle wallet);

  Future<void> init(
    NativeHandle wallet, {
    required String daemonAddress,
    required String proxyAddress,
    required bool useSsl,
    required bool lightWallet,
  });

  Future<void> connectToDaemon(NativeHandle wallet);
  Future<int> connected(NativeHandle wallet);
  Future<bool> synchronized(NativeHandle wallet);

  Future<int> blockChainHeight(NativeHandle wallet);
  Future<int> daemonBlockChainHeight(NativeHandle wallet);

  /// Sync flag, scanned height and both balances in one isolate hop.
  ///
  /// These four are read together on every refresh cycle and two of them on
  /// every fast poll. Individually they are four `Isolate.run` spawns for four
  /// local wallet2 reads; the reads are the cheap part.
  ///
  /// Deliberately excludes the daemon height, which is the one figure here that
  /// can cost a network round trip; see [daemonBlockChainHeight].
  Future<NativeWalletStats> walletStats(NativeHandle wallet, {int accountIndex = 0});

  // ----- Background sync (node mode only) -----

  /// Writes the view-only background wallet beside the main one.
  ///
  /// With [MoneroBackgroundSyncType.customPassword] this creates
  /// `<path>.background` and `<path>.background.keys`, the latter holding the
  /// account with `forget_spend_key()` applied; **no spend key at all**, not
  /// an encrypted one, and records the derived background key inside the main
  /// keys file so the main wallet can keep the cache up to date.
  ///
  /// Three things about it are traps:
  ///
  /// - It throws if [walletPassword] equals [backgroundCachePassword].
  /// - It is **not idempotent** for `customPassword`: wallet2 short-circuits a
  ///   no-change call for the other two types and never for this one, so
  ///   calling it again deletes and rewrites both files and resets the
  ///   background cache, discarding whatever it had scanned. Check
  ///   [getBackgroundSyncType] first.
  /// - It must never be called in LWS mode. LWSF hardcodes a
  ///   `ReusePassword` answer and implements none of this, so the call would
  ///   quietly do nothing while implying a protection that is not there.
  Future<bool> setupBackgroundSync(
    NativeHandle wallet, {
    required MoneroBackgroundSyncType type,
    required String walletPassword,
    required String backgroundCachePassword,
  });

  /// What [setupBackgroundSync] last configured, read back off the keys file.
  ///
  /// Also stands in for `Wallet_isBackgroundSyncing`, whose Dart binding exists
  /// but whose symbol the built library does not export; calling that one
  /// fails at symbol lookup.
  Future<MoneroBackgroundSyncType> getBackgroundSyncType(NativeHandle wallet);

  /// True when the open wallet *is* the background cache, i.e. it was opened
  /// from `<path>.background` and holds no spend key.
  ///
  /// Used as a post-open assertion rather than a branch: a background run that
  /// believes it opened the view-only file and did not has silently taken the
  /// spend key into a process with no user present.
  Future<bool> isBackgroundWallet(NativeHandle wallet);

  Future<void> refresh(NativeHandle wallet);
  Future<void> startRefresh(NativeHandle wallet);
  Future<void> pauseRefresh(NativeHandle wallet);
  Future<void> setAutoRefreshInterval(NativeHandle wallet, int millis);

  Future<bool> store(NativeHandle wallet);

  Future<BigInt> balance(NativeHandle wallet, {int accountIndex = 0});
  Future<BigInt> unlockedBalance(NativeHandle wallet, {int accountIndex = 0});

  Future<String> address(NativeHandle wallet, {int accountIndex = 0, int addressIndex = 0});

  Future<String> seed(NativeHandle wallet, {String seedOffset = ''});
  Future<String> getPolyseed(NativeHandle wallet, {String passphrase = ''});

  /// Private view key.
  ///
  /// Needed by the LWS subaddress probe, which is the only thing in this layer
  /// that sends it anywhere: `upsert_subaddrs` asks the light-wallet server to
  /// provision a subaddress, and the server needs the view key to scan for it.
  /// Never log this, not truncated, not hashed.
  Future<String> secretViewKey(NativeHandle wallet);

  /// Key export for the "secret keys" screen. Highly sensitive; never log.
  Future<String> secretSpendKey(NativeHandle wallet);
  Future<String> publicViewKey(NativeHandle wallet);
  Future<String> publicSpendKey(NativeHandle wallet);

  Future<int> getRefreshFromBlockHeight(NativeHandle wallet);
  Future<void> setRefreshFromBlockHeight(NativeHandle wallet, int height);

  Future<void> setCaFilePath(NativeHandle wallet, String path);

  /// Present only in `magicgrants/monero_c`, which is why the build pins that
  /// fork.
  Future<BigInt?> estimateTransactionFee(
    NativeHandle wallet, {
    required List<String> destinations,
    required List<BigInt> amounts,
    int priority = 0,
  });

  // ----- Transactions -----

  Future<NativeHandle> history(NativeHandle wallet);
  Future<void> historyRefresh(NativeHandle history);

  /// Reads the whole transaction list in **one** isolate hop.
  ///
  /// Replaces a `historyCount` call followed by one `historyTransaction` per
  /// index. That shape cost N isolate spawns and N `Wallet_getTxKey` lookups
  /// per read, on the 20-second refresh cycle, forever, and it is the ×N
  /// multiplier rather than the per-hop cost that made it matter.
  ///
  /// [wallet] is needed alongside [history] because the transaction key comes
  /// off the wallet, not off the history entry.
  ///
  /// [knownTxKeys] maps transaction hash to an already-known key, so a key is
  /// fetched once per transaction over the wallet's life instead of once per
  /// read. [withTxKeys] false skips the lookup altogether, which is **required**
  /// for a background (view-only) wallet: `WalletImpl::getTxKey` refuses the
  /// call there and leaves an error on the wallet's global status for every
  /// transaction it is asked about.
  Future<List<NativeTxInfo>> historyTransactions(
    NativeHandle wallet,
    NativeHandle history, {
    Map<String, String> knownTxKeys = const {},
    bool withTxKeys = true,
  });

  Future<NativeHandle> createTransaction(
    NativeHandle wallet, {
    required List<String> destinations,
    required List<BigInt> amounts,
    required bool isSweepAll,
    required int mixinCount,
    int priority = 0,
    int subaddrAccount = 0,
  });

  Future<BigInt> pendingTxAmount(NativeHandle tx);
  Future<BigInt> pendingTxFee(NativeHandle tx);
  Future<int> pendingTxStatus(NativeHandle tx);
  Future<String> pendingTxErrorString(NativeHandle tx);
  Future<bool> commitPendingTx(NativeHandle tx);
}
