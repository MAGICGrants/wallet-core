import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

import 'support/fake_lws.dart';
import 'support/monero_test_crypto.dart';

/// Behind an engaged password guard the keystore has no wallet password, so a
/// background run cannot open the wallet file. In LWS mode it asks the server
/// with the view key instead, and incoming payments must still be announced.
///
/// The steps are `runTxNotifier`'s, in its order, against a real HTTP server.
const _password = 'the-wallet-password';

class _EngagedGuard extends WalletPasswordGuard {
  @override
  Future<String> passwordForNewWallet(SeedSource seed) async => _password;

  @override
  Future<void> walletCreated(String password) async {}

  @override
  Future<bool> isEngaged() async => true;

  @override
  Future<void> walletDeleted() async {}
}

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late FakeLws lws;
  late FakeLwsOutput output;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('view_only_background_notify');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    useTestCaBundle();
    WalletLog.sink = MemoryLogSink();
    backend = FakeMoneroBackend();

    final viewSecret = MoneroTestCrypto.randomScalar();
    output = FakeLwsOutput.paying(
      amount: BigInt.from(1500000000000),
      viewSecret: viewSecret,
      spendPublicKey: MoneroTestCrypto.randomPoint(),
      major: 0,
      minor: 0,
      globalIndex: 1,
    );
    lws = await FakeLws.start(outputs: [output]);
  });

  tearDown(() async {
    await lws.close();
    WalletManager.passwordGuard = null;
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The foreground half: the wallet is open, the user turns security keys on,
  /// and the view-only credential is kept before the keystore password goes.
  Future<void> engageFromForeground() async {
    final wallet = MoneroWallet(backend: backend);
    wallet.setConnection(
      address: Uri.parse(lws.url).authority,
      proxyPort: '',
      useTor: false,
      connectionType: 'lws',
    );
    await wallet.persistCurrentConnection();
    backend.existingWalletPaths.add(await wallet.walletPathForType('lws'));
    await wallet.openExisting(password: _password);
    await wallet.prepareViewOnly();

    // Notifications were already running: everything up to an hour ago is seen.
    await TxNotificationStore.write(
      WalletAppConfig.instance.prefKeyNamer(wallet.coinSymbol, 'txNotificationState'),
      TxNotificationState(
        cutoff: DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
        announcedHashes: const [],
      ),
    );
    wallet.dispose();
    WalletManager.passwordGuard = _EngagedGuard();
  }

  /// `runTxNotifier`, minus the scheduling: a fresh isolate's manager with the
  /// coin marked unattended before anything opens.
  Future<List<TxDetails>> runBackgroundCheck() async {
    final announced = <TxDetails>[];
    CryptoWallet.incomingTxNotifier = (tx, coin) => announced.add(tx);

    final manager = WalletManager(
      coins: () => [MoneroWallet(backend: backend)..markUnattended()],
    );
    await manager.openAll();
    for (final w in manager.activeWallets) {
      await w.loadPersistedConnection();
      await w.connectToDaemon();
      await w.loadTxHistory(persistCount: false);
    }
    await manager.pauseSyncAndStoreAll();
    await manager.notifyNewIncomingTxsAll();
    manager.dispose();
    return announced;
  }

  test('an incoming payment is announced from the view key alone', () async {
    await engageFromForeground();
    final opensBefore = backend.opens.length;
    lws.requests.clear();

    final announced = await runBackgroundCheck();

    expect(announced, hasLength(1));
    expect(announced.single.direction, txDirectionIncoming);
    expect(announced.single.amountBaseUnits, output.amount);

    // No wallet file was opened, and the only request carried the view key.
    expect(backend.opens.length, opensBefore);
    final request = lws.requests.singleWhere((r) => r.path == '/get_address_txs');
    expect(request.body, {
      'address': backend.defaultAddress,
      'view_key': backend.secretViewKeyValue,
    });
    expect(lws.requests.map((r) => r.path), everyElement('/get_address_txs'));
  });

  test('a second run does not announce the same payment again', () async {
    await engageFromForeground();
    expect(await runBackgroundCheck(), hasLength(1));
    expect(await runBackgroundCheck(), isEmpty);
  });

  test('without the kept credential the run announces nothing', () async {
    await engageFromForeground();
    final wallet = MoneroWallet(backend: backend);
    await wallet.forgetViewOnly();
    wallet.dispose();

    expect(await runBackgroundCheck(), isEmpty);
    expect(lws.requests.where((r) => r.path == '/get_address_txs'), isEmpty);
  });
}
