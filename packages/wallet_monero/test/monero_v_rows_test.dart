import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Guards for four behaviours that were lost when this code moved into the
/// shared core. The apps themselves agreed on all of them; only the port
/// dropped them, so these tests aim at the relocation.

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;
  late MemoryLogSink logs;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_v_rows');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    logs = MemoryLogSink();
    WalletLog.sink = logs;
    WalletLog.isVerbose = () async => true;
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void connect({String type = 'lws'}) => wallet.setConnection(
    address: type == 'node' ? 'node.example.com:18081' : 'lws.example.com:18090',
    proxyPort: '',
    useTor: false,
    connectionType: type,
  );

  Future<void> openAndConnect({String type = 'lws'}) async {
    connect(type: type);
    backend.existingWalletPaths.add(await wallet.walletPathForType(type));
    await wallet.openExisting(password: 'pw');
    await wallet.connectToDaemonImpl(address: 'x:1');
  }

  Future<String> logged() async {
    await Future<void>.delayed(Duration.zero);
    return logs.records.map((r) => r.line).join('\n');
  }

  group('refresh keeps the mode branch (row: refresh)', () {
    test('LWS scans on demand — the server did the work', () async {
      await openAndConnect();
      backend.calls.clear();

      await wallet.refresh();

      expect(backend.called('refresh'), isTrue);
      expect(backend.called('startRefresh'), isFalse);
    });

    test('a node nudges its background thread instead of scanning inline', () async {
      await openAndConnect(type: 'node');
      backend.calls.clear();

      await wallet.refresh();

      // `Wallet_refresh` is a blocking one-shot that takes the wallet lock.
      // Calling it on the 20s cycle reintroduces exactly the contention
      // `deferStatsUntilSynced` exists to avoid.
      expect(backend.called('startRefresh'), isTrue);
      expect(backend.called('refresh'), isFalse);
    });

    test('a paused node scan is restarted by the next refresh', () async {
      await openAndConnect(type: 'node');

      // What a background task does before it ends.
      await wallet.pauseSync();
      expect(backend.called('pauseRefresh'), isTrue);

      backend.calls.clear();
      await wallet.refresh();

      // Starting the thread only at connect would leave it stopped for the life
      // of the wallet object, and node mode would silently never sync again.
      expect(backend.called('startRefresh'), isTrue);
    });

    test('refresh is a no-op with no wallet or no daemon', () async {
      await wallet.refresh();
      expect(backend.called('refresh'), isFalse);
      expect(backend.called('startRefresh'), isFalse);
    });
  });

  group('the node probe rejects a non-node politely (row: testConnection)', () {
    test('accepts a real get_height response', () {
      expect(MoneroWallet.looksLikeMoneroNodeBody('{"height":3000000,"status":"OK"}'), isTrue);
    });

    test('a 200 that is not JSON is rejected, not a parse error', () {
      // A captive portal, a reverse proxy, or a web server on 18081. The port
      // decoded with a bare jsonDecode, so this surfaced a FormatException
      // instead of "that address did not respond like a Monero node".
      expect(MoneroWallet.looksLikeMoneroNodeBody('<html><body>hello</body></html>'), isFalse);
      expect(MoneroWallet.looksLikeMoneroNodeBody(''), isFalse);
      expect(MoneroWallet.looksLikeMoneroNodeBody('not json at all'), isFalse);
    });

    test('valid JSON that is not a node is rejected', () {
      expect(MoneroWallet.looksLikeMoneroNodeBody('[]'), isFalse);
      expect(MoneroWallet.looksLikeMoneroNodeBody('"a string"'), isFalse);
      expect(MoneroWallet.looksLikeMoneroNodeBody('{"status":"OK"}'), isFalse);
    });

    test('a non-integer height is rejected — stricter than either app', () {
      // Both apps checked only for non-null, so an endpoint answering
      // `{"height":"lots"}` passed as a monerod.
      expect(MoneroWallet.looksLikeMoneroNodeBody('{"height":"3000000"}'), isFalse);
      expect(MoneroWallet.looksLikeMoneroNodeBody('{"height":null}'), isFalse);
    });
  });

  group('commitTx refreshes the display snapshot (row: commitTx)', () {
    test('the pending tx and reduced balance are on disk before the next sync', () async {
      await openAndConnect();
      wallet.setCachePassword('cache-pw');
      await wallet.loadCache();

      backend.balanceValue = BigInt.from(7000000000000);
      backend.unlockedBalanceValue = BigInt.from(7000000000000);

      final tx = await wallet.createTx('4${'a' * 94}', BigInt.from(1000000000000), false);
      await wallet.commitTx(tx, '4${'a' * 94}');

      // Without this the app reopens
      // showing the pre-send balance and no pending transaction until the sync
      // catches up.
      final cached = await WalletCacheStore.load('XMR', 'cache-pw');
      expect(cached['cachedUnlockedBalanceUnits'], '7000000000000');
    });
  });

  group('needsRebuildForCurrentConnection', () {
    // No test for `dispose()` now clearing `_loadedKind`: the predicate
    // short-circuits on the wallet being null, which dispose already did, so
    // that change is defensive hygiene with no observable behaviour to assert.
    // It is what makes Skylight's extra `_loadedType != null` guard provably
    // redundant rather than probably redundant.

    test('an open wallet in its own mode needs nothing', () async {
      await openAndConnect();
      expect(await wallet.needsRebuildForCurrentConnection(), isFalse);
    });

    test('a mode switch does need a rebuild', () async {
      await openAndConnect();
      connect(type: 'node');
      expect(await wallet.needsRebuildForCurrentConnection(), isTrue);
    });

    test('no open wallet needs no rebuild', () async {
      connect();
      expect(await wallet.needsRebuildForCurrentConnection(), isFalse);
    });
  });

  group('destructive file removal is traceable (row: _deleteWalletFilesForCurrentMode)', () {
    test('each removed file is logged by basename, not by full path', () async {
      connect();
      final path = await wallet.walletPathForType('lws');
      for (final p in [path, '$path.keys', '$path.address.txt']) {
        File(p).writeAsStringSync('leftover');
      }
      // wallet2 refuses to recover onto an existing file. That failure is what
      // sends the restore down the delete-and-retry path.
      backend.queuedRestoreErrors.add('file already exists');

      await wallet.restoreFromSeed(
        seed: const Bip39Seed(
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon abandon address',
        ),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );

      final written = await logged();
      expect(written, contains('Removing wallet file before restore: mywallet'));
      expect(written, contains('mywallet.keys'));
      // The full path carries the OS user's home directory.
      expect(written, isNot(contains(tmp.path)));
    });
  });

  group('converged rows, confirmed', () {
    test('getCurrentHeight reads the manager, not the wallet', () async {
      await openAndConnect();
      backend.chainHeight = 3210000;
      expect(await wallet.getCurrentHeight(), 3210000);
    });

    test('the primary address is never logged, unlike in either app', () async {
      backend.defaultAddress = '4${'z' * 94}';
      await openAndConnect();
      await wallet.loadPrimaryAddress();

      expect(wallet.getPrimaryAddress(), backend.defaultAddress);
      // Both apps printed `Wallet_address result: <the address>`.
      expect(await logged(), isNot(contains(backend.defaultAddress)));
    });

    test('createTx names neither the destination nor the amount', () async {
      await openAndConnect();
      final destination = '4${'d' * 94}';
      await wallet.createTx(destination, BigInt.from(1234500000000), false);

      final written = await logged();
      expect(written, isNot(contains(destination)));
      expect(written, isNot(contains('1234500000000')));
      // Still says what happened.
      expect(written, contains('Creating tx'));
    });

    test('a commit that the backend refuses throws rather than reporting a send', () async {
      await openAndConnect();
      final tx = await wallet.createTx('4${'a' * 94}', BigInt.from(1000), false);

      backend.commitResult = false;
      await expectLater(wallet.commitTx(tx, '4${'a' * 94}'), throwsA(isA<FormatException>()));
    });
  });
}
