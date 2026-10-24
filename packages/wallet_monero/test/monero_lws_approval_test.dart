import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// A light-wallet server that approves accounts by hand answers login with
/// "unapproved", which LWSF reports only as text in its error string. The apps
/// tell the user from [MoneroWallet.lwsPendingApproval], so it has to follow
/// that string: set after a login or refresh that reports it, and gone again
/// once the operator approves.
void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  // LWSF's own wording, from its src/error.cpp.
  const accountPending = 'Account needs approval on light-wallet-server';
  const importPending = 'Import/restore from height is awaiting approval';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_lws_approval');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    useTestCaBundle();
    WalletLog.sink = MemoryLogSink();
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> open(String type) async {
    final address = type == 'node' ? '192.168.1.10:18081' : '192.168.1.10:18090';
    wallet.setConnection(address: address, proxyPort: '', useTor: false, connectionType: type);
    backend.existingWalletPaths.add(await wallet.walletPathForType(type));
    await wallet.openExisting(password: 'pw');
  }

  Future<void> connect() =>
      wallet.connectToDaemonImpl(address: wallet.connectionAddress, proxyPort: '');

  test('nothing is pending on a server that serves the account', () async {
    await open('lws');
    await connect();
    expect(wallet.lwsPendingApproval, isNull);
  });

  test('an account the server has not approved is reported at login', () async {
    await open('lws');
    backend.connectToDaemonError = accountPending;
    var notified = 0;
    wallet.addListener(() => notified++);

    await connect();

    expect(wallet.lwsPendingApproval, LwsPendingApproval.account);
    expect(notified, greaterThan(0), reason: 'the screens rebuild on it');
  });

  test('a rescan awaiting approval is reported as its own case', () async {
    await open('lws');
    backend.connectToDaemonError = importPending;
    await connect();
    expect(wallet.lwsPendingApproval, LwsPendingApproval.restoreHeight);
  });

  test('a refresh picks it up too, and drops it once the operator approves', () async {
    await open('lws');
    await connect();

    backend.refreshErrorString = accountPending;
    await wallet.refresh();
    expect(wallet.lwsPendingApproval, LwsPendingApproval.account);

    // LWSF clears the string on the next request that succeeds.
    backend.refreshErrorString = '';
    await wallet.refresh();
    expect(wallet.lwsPendingApproval, isNull);
  });

  test('another failure is not mistaken for one awaiting approval', () async {
    await open('lws');
    backend.connectToDaemonError = 'Connection refused';
    backend.connectToDaemonResult = false;
    await connect();
    expect(wallet.lwsPendingApproval, isNull);
  });

  test('a node has no light-wallet server to approve anything', () async {
    await open('node');
    backend.connectToDaemonError = accountPending;
    await connect();
    expect(wallet.lwsPendingApproval, isNull);
  });
}
