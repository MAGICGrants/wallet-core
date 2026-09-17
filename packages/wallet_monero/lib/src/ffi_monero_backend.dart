// monero.dart marks almost its entire surface `@Deprecated("TODO")`. That is
// the generator's marker for "generated but not yet exercised", not a real
// deprecation; there is no replacement API.
// ignore_for_file: deprecated_member_use

import 'dart:ffi';
import 'dart:isolate';

import 'package:monero/monero.dart' as monero;

import 'monero_backend.dart';

/// The real [MoneroBackend]: monero_c over FFI.
///
/// Every call crosses into `Isolate.run` with the handle passed as a plain
/// integer address. That is not incidental; a native call can block for
/// seconds (a daemon handshake over Tor, a wallet open, a PBKDF2-backed
/// keystore read), and doing it on the UI isolate janks the app. Pointers are
/// not sendable across isolates, so the address is what travels.
///
/// This class holds no state beyond the handles it hands out; all of it lives
/// in native memory.
class FfiMoneroBackend extends MoneroBackend {
  const FfiMoneroBackend();

  // ----- Manager -----

  @override
  Future<NativeHandle> getWalletManager(MoneroManagerKind kind) async {
    // Two distinct factories. A wallet object is bound to the one that built
    // it, so an LWS↔node switch needs a re-open, not just a new address.
    final address = await Isolate.run(() {
      final wm = kind == MoneroManagerKind.node
          ? monero.WalletManagerFactory_getWalletManager()
          : monero.WalletManagerFactory_getLWSFWalletManager();
      return wm.address;
    });
    return NativeHandle(address);
  }

  @override
  Future<bool> walletExists(NativeHandle manager, String path) {
    final wm = manager.id;
    return Isolate.run(() => monero.WalletManager_walletExists(Pointer.fromAddress(wm), path));
  }

  @override
  Future<String> managerErrorString(NativeHandle manager) {
    final wm = manager.id;
    return Isolate.run(() => monero.WalletManager_errorString(Pointer.fromAddress(wm)));
  }

  @override
  Future<int> blockchainHeight(NativeHandle manager) {
    final wm = manager.id;
    return Isolate.run(() => monero.WalletManager_blockchainHeight(Pointer.fromAddress(wm)));
  }

  @override
  Future<NativeHandle> openWallet(
    NativeHandle manager, {
    required String path,
    required String password,
  }) async {
    final wm = manager.id;
    final address = await Isolate.run(
      () => monero.WalletManager_openWallet(
        Pointer.fromAddress(wm),
        path: path,
        password: password,
      ).address,
    );
    return NativeHandle(address);
  }

  @override
  Future<NativeHandle> recoveryWallet(
    NativeHandle manager, {
    required String mnemonic,
    required String seedOffset,
    required int restoreHeight,
    required String password,
    required String path,
    int networkType = 0,
  }) async {
    final wm = manager.id;
    final address = await Isolate.run(
      () => monero.WalletManager_recoveryWallet(
        Pointer.fromAddress(wm),
        mnemonic: mnemonic,
        seedOffset: seedOffset,
        restoreHeight: restoreHeight,
        password: password,
        path: path,
        networkType: networkType,
      ).address,
    );
    return NativeHandle(address);
  }

  @override
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
  }) async {
    final wm = manager.id;
    final address = await Isolate.run(
      () => monero.WalletManager_createWalletFromPolyseed(
        Pointer.fromAddress(wm),
        path: path,
        password: password,
        networkType: networkType,
        mnemonic: mnemonic,
        seedOffset: seedOffset,
        newWallet: newWallet,
        restoreHeight: restoreHeight,
        kdfRounds: kdfRounds,
      ).address,
    );
    return NativeHandle(address);
  }

  @override
  Future<bool> closeWallet(NativeHandle manager, NativeHandle wallet, {required bool store}) {
    final wm = manager.id;
    final w = wallet.id;
    return Isolate.run(
      () =>
          monero.WalletManager_closeWallet(Pointer.fromAddress(wm), Pointer.fromAddress(w), store),
    );
  }

  // ----- Wallet -----

  @override
  Future<String> walletErrorString(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_errorString(Pointer.fromAddress(w)));
  }

  @override
  Future<int> walletStatus(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_status(Pointer.fromAddress(w)));
  }

  @override
  Future<void> init(
    NativeHandle wallet, {
    required String daemonAddress,
    required String proxyAddress,
    required bool useSsl,
    required bool lightWallet,
  }) async {
    final w = wallet.id;
    await Isolate.run(
      () => monero.Wallet_init(
        Pointer.fromAddress(w),
        daemonAddress: daemonAddress,
        proxyAddress: proxyAddress,
        useSsl: useSsl,
        lightWallet: lightWallet,
      ),
    );
  }

  @override
  bool addressValid(String address, int networkType) =>
      monero.Wallet_addressValid(address, networkType);

  @override
  Future<void> connectToDaemon(NativeHandle wallet) async {
    final w = wallet.id;
    await Isolate.run(() => monero.Wallet_connectToDaemon(Pointer.fromAddress(w)));
  }

  @override
  Future<int> connected(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_connected(Pointer.fromAddress(w)));
  }

  @override
  Future<bool> synchronized(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_synchronized(Pointer.fromAddress(w)));
  }

  @override
  Future<int> blockChainHeight(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_blockChainHeight(Pointer.fromAddress(w)));
  }

  @override
  Future<int> daemonBlockChainHeight(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_daemonBlockChainHeight(Pointer.fromAddress(w)));
  }

  @override
  Future<NativeWalletStats> walletStats(NativeHandle wallet, {int accountIndex = 0}) async {
    final w = wallet.id;
    // One hop for all four. Every one of them is a local wallet2 read, so the
    // isolate spawn dominated the call before this existed, and two of them
    // are read again on the fast poll.
    return Isolate.run(() {
      final ptr = Pointer<Void>.fromAddress(w);
      return NativeWalletStats(
        synchronized: monero.Wallet_synchronized(ptr),
        blockChainHeight: monero.Wallet_blockChainHeight(ptr),
        balance: BigInt.from(monero.Wallet_balance(ptr, accountIndex: accountIndex)),
        unlockedBalance: BigInt.from(
          monero.Wallet_unlockedBalance(ptr, accountIndex: accountIndex),
        ),
      );
    });
  }

  // ----- Background sync -----

  @override
  Future<bool> setupBackgroundSync(
    NativeHandle wallet, {
    required MoneroBackgroundSyncType type,
    required String walletPassword,
    required String backgroundCachePassword,
  }) {
    final w = wallet.id;
    final typeValue = type.value;
    return Isolate.run(
      () => monero.Wallet_setupBackgroundSync(
        Pointer.fromAddress(w),
        backgroundSyncType: typeValue,
        walletPassword: walletPassword,
        backgroundCachePassword: backgroundCachePassword,
      ),
    );
  }

  @override
  Future<MoneroBackgroundSyncType> getBackgroundSyncType(NativeHandle wallet) async {
    final w = wallet.id;
    final raw = await Isolate.run(
      () => monero.Wallet_getBackgroundSyncType(Pointer.fromAddress(w)),
    );
    return MoneroBackgroundSyncType.fromValue(raw);
  }

  @override
  Future<bool> isBackgroundWallet(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_isBackgroundWallet(Pointer.fromAddress(w)));
  }

  @override
  Future<void> refresh(NativeHandle wallet) async {
    final w = wallet.id;
    await Isolate.run(() => monero.Wallet_refresh(Pointer.fromAddress(w)));
  }

  @override
  Future<void> startRefresh(NativeHandle wallet) async {
    final w = wallet.id;
    await Isolate.run(() => monero.Wallet_startRefresh(Pointer.fromAddress(w)));
  }

  @override
  Future<void> pauseRefresh(NativeHandle wallet) async {
    final w = wallet.id;
    await Isolate.run(() => monero.Wallet_pauseRefresh(Pointer.fromAddress(w)));
  }

  @override
  Future<void> setAutoRefreshInterval(NativeHandle wallet, int millis) async {
    final w = wallet.id;
    await Isolate.run(
      () => monero.Wallet_setAutoRefreshInterval(Pointer.fromAddress(w), millis: millis),
    );
  }

  @override
  Future<bool> store(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_store(Pointer.fromAddress(w)));
  }

  @override
  Future<BigInt> balance(NativeHandle wallet, {int accountIndex = 0}) async {
    final w = wallet.id;
    final raw = await Isolate.run(
      () => monero.Wallet_balance(Pointer.fromAddress(w), accountIndex: accountIndex),
    );
    return BigInt.from(raw);
  }

  @override
  Future<BigInt> unlockedBalance(NativeHandle wallet, {int accountIndex = 0}) async {
    final w = wallet.id;
    final raw = await Isolate.run(
      () => monero.Wallet_unlockedBalance(Pointer.fromAddress(w), accountIndex: accountIndex),
    );
    return BigInt.from(raw);
  }

  @override
  Future<String> address(NativeHandle wallet, {int accountIndex = 0, int addressIndex = 0}) {
    final w = wallet.id;
    return Isolate.run(
      () => monero.Wallet_address(
        Pointer.fromAddress(w),
        accountIndex: accountIndex,
        addressIndex: addressIndex,
      ),
    );
  }

  @override
  Future<String> seed(NativeHandle wallet, {String seedOffset = ''}) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_seed(Pointer.fromAddress(w), seedOffset: seedOffset));
  }

  @override
  Future<String> getPolyseed(NativeHandle wallet, {String passphrase = ''}) {
    final w = wallet.id;
    return Isolate.run(
      () => monero.Wallet_getPolyseed(Pointer.fromAddress(w), passphrase: passphrase),
    );
  }

  @override
  Future<String> secretViewKey(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_secretViewKey(Pointer.fromAddress(w)));
  }

  @override
  Future<String> secretSpendKey(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_secretSpendKey(Pointer.fromAddress(w)));
  }

  @override
  Future<String> publicViewKey(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_publicViewKey(Pointer.fromAddress(w)));
  }

  @override
  Future<String> publicSpendKey(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_publicSpendKey(Pointer.fromAddress(w)));
  }

  @override
  Future<int> getRefreshFromBlockHeight(NativeHandle wallet) {
    final w = wallet.id;
    return Isolate.run(() => monero.Wallet_getRefreshFromBlockHeight(Pointer.fromAddress(w)));
  }

  @override
  Future<void> setRefreshFromBlockHeight(NativeHandle wallet, int height) async {
    final w = wallet.id;
    await Isolate.run(
      () => monero.Wallet_setRefreshFromBlockHeight(
        Pointer.fromAddress(w),
        refresh_from_block_height: height,
      ),
    );
  }

  @override
  Future<void> setCaFilePath(NativeHandle wallet, String path) async {
    final w = wallet.id;
    await Isolate.run(() => monero.Wallet_setCaFilePath(Pointer.fromAddress(w), path));
  }

  @override
  Future<BigInt?> estimateTransactionFee(
    NativeHandle wallet, {
    required List<String> destinations,
    required List<BigInt> amounts,
    int priority = 0,
  }) async {
    final w = wallet.id;
    final ints = amounts.map((a) => a.toInt()).toList(growable: false);
    final raw = await Isolate.run(
      () => monero.Wallet_estimateTransactionFee(
        Pointer.fromAddress(w),
        dstAddr: destinations,
        amounts: ints,
        pendingTransactionPriority: priority,
      ),
    );
    // 0 means the backend could not estimate, never a real fee.
    return raw > 0 ? BigInt.from(raw) : null;
  }

  // ----- Transactions -----

  @override
  Future<NativeHandle> history(NativeHandle wallet) async {
    final w = wallet.id;
    final address = await Isolate.run(() => monero.Wallet_history(Pointer.fromAddress(w)).address);
    return NativeHandle(address);
  }

  @override
  Future<void> historyRefresh(NativeHandle history) async {
    final h = history.id;
    await Isolate.run(() => monero.TransactionHistory_refresh(Pointer.fromAddress(h)));
  }

  @override
  Future<List<NativeTxInfo>> historyTransactions(
    NativeHandle wallet,
    NativeHandle history, {
    Map<String, String> knownTxKeys = const {},
    bool withTxKeys = true,
  }) {
    final h = history.id;
    final w = wallet.id;
    // One isolate hop for the whole list: the count, every transaction's dozen
    // accessors, and whichever keys are not already known. Before this it was
    // one hop per transaction plus one for the count, on the refresh cycle.
    return Isolate.run(() {
      final historyPtr = Pointer<Void>.fromAddress(h);
      final walletPtr = Pointer<Void>.fromAddress(w);
      final count = monero.TransactionHistory_count(historyPtr);
      final out = <NativeTxInfo>[];
      for (var i = 0; i < count; i++) {
        final tx = monero.TransactionHistory_transaction(historyPtr, index: i);
        final hash = monero.TransactionInfo_hash(tx);
        final transferCount = monero.TransactionInfo_transfers_count(tx);
        final destinations = [
          for (var t = 0; t < transferCount; t++)
            (
              address: monero.TransactionInfo_transfers_address(tx, t),
              amount: BigInt.from(monero.TransactionInfo_transfers_amount(tx, t)),
            ),
        ];
        out.add(
          NativeTxInfo(
            direction: monero.TransactionInfo_direction(tx) == monero.TransactionInfo_Direction.In
                ? 0
                : 1,
            hash: hash,
            amount: BigInt.from(monero.TransactionInfo_amount(tx)),
            fee: BigInt.from(monero.TransactionInfo_fee(tx)),
            timestamp: monero.TransactionInfo_timestamp(tx),
            blockHeight: monero.TransactionInfo_blockHeight(tx),
            confirmations: monero.TransactionInfo_confirmations(tx),
            subaddrAccount: monero.TransactionInfo_subaddrAccount(tx),
            subaddrIndex: monero.TransactionInfo_subaddrIndex(tx),
            isPending: monero.TransactionInfo_isPending(tx),
            isFailed: monero.TransactionInfo_isFailed(tx),
            paymentId: monero.TransactionInfo_paymentId(tx),
            // The key comes off the wallet, not the entry, which is why this
            // method takes the wallet handle. Asked for at most once per
            // transaction: an incoming transaction never has one, and
            // `WalletImpl::getTxKey` answers a miss by writing "no tx keys
            // found for this txid" onto the wallet's *global* error status, so
            // asking again every cycle also clobbers whatever else was there.
            txKey: !withTxKeys
                ? ''
                : (knownTxKeys[hash] ?? monero.Wallet_getTxKey(walletPtr, txid: hash)),
            destinations: destinations,
          ),
        );
      }
      return out;
    });
  }

  @override
  Future<NativeHandle> createTransaction(
    NativeHandle wallet, {
    required List<String> destinations,
    required List<BigInt> amounts,
    required bool isSweepAll,
    required int mixinCount,
    int priority = 0,
    int subaddrAccount = 0,
  }) async {
    final w = wallet.id;
    final ints = amounts.map((a) => a.toInt()).toList(growable: false);
    final address = await Isolate.run(
      () => monero.Wallet_createTransactionMultDest(
        Pointer.fromAddress(w),
        dstAddr: destinations,
        isSweepAll: isSweepAll,
        amounts: ints,
        mixinCount: mixinCount,
        pendingTransactionPriority: priority,
        subaddr_account: subaddrAccount,
      ).address,
    );
    return NativeHandle(address);
  }

  @override
  Future<BigInt> pendingTxAmount(NativeHandle tx) async {
    final t = tx.id;
    return BigInt.from(
      await Isolate.run(() => monero.PendingTransaction_amount(Pointer.fromAddress(t))),
    );
  }

  @override
  Future<BigInt> pendingTxFee(NativeHandle tx) async {
    final t = tx.id;
    return BigInt.from(
      await Isolate.run(() => monero.PendingTransaction_fee(Pointer.fromAddress(t))),
    );
  }

  @override
  Future<int> pendingTxStatus(NativeHandle tx) {
    final t = tx.id;
    return Isolate.run(() => monero.PendingTransaction_status(Pointer.fromAddress(t)));
  }

  @override
  Future<String> pendingTxErrorString(NativeHandle tx) {
    final t = tx.id;
    return Isolate.run(() => monero.PendingTransaction_errorString(Pointer.fromAddress(t)));
  }

  @override
  Future<bool> commitPendingTx(NativeHandle tx) {
    final t = tx.id;
    return Isolate.run(
      () =>
          monero.PendingTransaction_commit(Pointer.fromAddress(t), filename: '', overwrite: false),
    );
  }
}
