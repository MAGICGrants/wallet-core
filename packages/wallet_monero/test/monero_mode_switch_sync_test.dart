import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Switching LWS -> node rebuilds the wallet from the seed, so the node file
/// starts at the restore height with nothing scanned. What the user must not
/// see in that moment is "Synced" over an empty wallet.

const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _password = 'the-existing-password';

NativeTxInfo _tx(String hash) => NativeTxInfo(
  direction: 0,
  hash: hash,
  amount: BigInt.from(5000000000000),
  fee: BigInt.zero,
  timestamp: 1700000000,
  blockHeight: 2900000,
  confirmations: 20,
  subaddrAccount: 0,
  subaddrIndex: '0',
  isPending: false,
  isFailed: false,
  paymentId: '',
  txKey: '',
);

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mode_switch_sync');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void connect(String type) => wallet.setConnection(
    address: type == 'node' ? 'node.example.com:18081' : 'lws.example.com:18090',
    proxyPort: '',
    useTor: false,
    connectionType: type,
  );

  /// A synced LWS wallet with a balance and some history, as the user had it
  /// before touching the connection form.
  Future<void> syncedOnLws() async {
    connect('lws');
    await wallet.restoreFromSeed(
      seed: MoneroLegacySeed(_legacy25),
      from: RestorePoint.height(2800000),
      password: _password,
    );
    final path = await wallet.walletPathForType('lws');
    await File(path).writeAsString('wallet');
    backend.existingWalletPaths.add(path);

    backend.synchronizedValue = true;
    backend.walletHeight = 3000000;
    backend.chainHeight = 3000000;
    backend.balanceValue = BigInt.from(5000000000000);
    backend.unlockedBalanceValue = BigInt.from(5000000000000);
    backend.transactions = [_tx('aaa'), _tx('bbb')];

    await wallet.load();
    expect(wallet.isSynced, isTrue);
    expect(wallet.totalBalanceBaseUnits, BigInt.from(5000000000000));
    expect(wallet.txHistory, hasLength(2));
    backend.reset();
    backend.existingWalletPaths.add(path);
  }

  /// The node wallet the switch recovers: nothing scanned yet. monero_c flips
  /// `Wallet_synchronized` once its refresh thread has made a pass, which can
  /// land before the scan has caught up to the daemon.
  void freshNodeWallet({required bool reportsSynchronized}) {
    backend.synchronizedValue = reportsSynchronized;
    backend.walletHeight = 2800000;
    backend.chainHeight = 3000000;
    backend.balanceValue = BigInt.zero;
    backend.unlockedBalanceValue = BigInt.zero;
    backend.transactions = [];
  }

  test('a node wallet that has not caught up does not report itself synced', () async {
    await syncedOnLws();
    freshNodeWallet(reportsSynchronized: true);

    connect('node');
    await wallet.applyConnectionChange(password: _password);

    expect(
      wallet.isSynced,
      isFalse,
      reason: 'the node wallet is 200k blocks behind; "Synced" is a lie',
    );
  });

  test('the switch does not replace the balance and history with zeroes', () async {
    await syncedOnLws();
    freshNodeWallet(reportsSynchronized: false);

    connect('node');
    await wallet.applyConnectionChange(password: _password);

    // The node wallet is the same seed and the same funds; until it has
    // scanned, the last known figures are the honest ones to show. Reading the
    // unscanned wallet instead replaces them with zeroes -- and persists those,
    // so they do not come back on the next launch either.
    expect(
      wallet.totalBalanceBaseUnits,
      BigInt.from(5000000000000),
      reason: 'the unscanned node wallet zeroed the balance',
    );
    expect(wallet.txHistory, hasLength(2), reason: 'the unscanned node wallet emptied the history');
  });

  test('a connection tick in the gap before the rebuild cannot leave it synced', () async {
    await syncedOnLws();

    // The form sets the connection, then persists, then applies. The LWS wallet
    // is still open across that gap and its 1s tick keeps running -- this is the
    // tick, landing after the type flipped to node but before the rebuild.
    connect('node');
    expect(wallet.isSynced, isFalse, reason: 'setConnection clears it');

    backend.synchronizedValue = true; // the OLD lws wallet, still open, still synced
    await wallet.checkConnectionTask();

    freshNodeWallet(reportsSynchronized: false);
    await wallet.applyConnectionChange(password: _password);

    expect(
      wallet.isSynced,
      isFalse,
      reason: 'the rebuilt node wallet inherited the old lws wallet\'s synced flag',
    );
  });

  test('the sync poll does not call a wallet 200k blocks behind synced', () async {
    await syncedOnLws();
    freshNodeWallet(reportsSynchronized: true);

    connect('node');
    await wallet.applyConnectionChange(password: _password);

    // Two polls: the first learns the scanned height and kicks off the daemon
    // height fetch, the second sees the gap.
    await wallet.pollSyncStatus();
    await Future<void>.delayed(Duration.zero);
    await wallet.pollSyncStatus();

    expect(
      wallet.isSynced,
      isFalse,
      reason: 'scanned 2_800_000 of 3_000_000 is not synced, whatever the flag says',
    );
  });

  test('a node wallet that has caught up does report synced, and loads its stats', () async {
    await syncedOnLws();

    // Caught up: scanned height meets the chain, with real figures behind it.
    backend.synchronizedValue = true;
    backend.walletHeight = 3000000;
    backend.chainHeight = 3000000;
    backend.balanceValue = BigInt.from(7000000000000);
    backend.unlockedBalanceValue = BigInt.from(7000000000000);
    backend.transactions = [_tx('ccc')];

    connect('node');
    await wallet.applyConnectionChange(password: _password);
    await wallet.pollSyncStatus();
    await Future<void>.delayed(Duration.zero);
    await wallet.pollSyncStatus();

    expect(wallet.isSynced, isTrue);
    expect(wallet.totalBalanceBaseUnits, BigInt.from(7000000000000));
    expect(wallet.txHistory, hasLength(1));
  });

  test('an unreadable daemon height still lets the wallet reach synced', () async {
    await syncedOnLws();

    // The narrowing must only demote on positive evidence: a node that will not
    // report its height is not a node the wallet should refuse to call synced.
    backend.synchronizedValue = true;
    backend.walletHeight = 3000000;
    backend.chainHeight = 0; // daemonBlockChainHeight reads 0 => never cached

    connect('node');
    await wallet.applyConnectionChange(password: _password);
    await wallet.pollSyncStatus();
    await Future<void>.delayed(Duration.zero);
    await wallet.pollSyncStatus();

    expect(wallet.isSynced, isTrue);
  });
}
