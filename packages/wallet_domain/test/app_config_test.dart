import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// `WalletAppConfig` is the type that keeps `if (isSkylight)` out of the core:
/// every difference between the two apps' shipped layouts is one of its
/// injected namers.
///
/// Getting a namer wrong crashes nothing. It points the core at keys and files
/// that nobody wrote, so an upgraded user lands on a wallet that believes it has
/// never been configured; no server, no restore height, no subaddress state.
/// That is the regression this file guards.
///
/// The assertions are therefore on **the keys that actually reach storage**, not
/// on the namer functions. A namer that is correct but not consulted orphans
/// exactly the same settings, and only the storage-side assertion catches it.

void main() {
  late Directory tmp;
  late MemoryPreferenceStore prefs;
  late MemorySecretStore secrets;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_config');
    prefs = MemoryPreferenceStore();
    SharedPreferencesService.store = prefs;
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void installSpice() =>
      WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  void installSkylight() =>
      WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));

  /// Puts a connection on [wallet] and persists it, which is the only way the
  /// connection keys reach storage.
  Future<void> persistAConnection(
    CryptoWallet wallet, {
    String address = 'node.example.com',
  }) async {
    wallet.setConnection(
      address: address,
      proxyPort: '9050',
      useTor: false,
      connectionType: 'node',
    );
    await wallet.persistCurrentConnection();
  }

  group('install', () {
    test('using the core before install() is a clear error, not a null crash', () {
      expect(() => WalletAppConfig.instance, throwsA(isA<StateError>()));
    });

    test('install also configures the layer below, so an app configures one object', () async {
      installSkylight();
      // `WalletPaths` lives in wallet_infra and cannot import this type, but an
      // app should not have to configure two objects to say one thing. The
      // directory provider handed to `WalletAppConfig.install` has to arrive
      // there, or every store in this package writes somewhere else.
      expect(WalletAppConfig.instance.appDirName, '.skylight_wallet');
      expect((await getAppDir()).path, tmp.path);
    });
  });

  group('names on shipped devices that are not namespaced at all', () {
    test('the wallet password key is the one 1.0.x wrote', () async {
      // Not namer-derived: one global key, shared by both apps because each is
      // a separate install. That puts it outside every guard in this file, and
      // outside the one in `tx_notification_store_test.dart`, even though it is
      // the highest-consequence name of the three.
      //
      // Rename it and an upgraded wallet cannot find the password it minted for
      // itself. On mobile with app lock off the app auto-loads that password to
      // open the wallet, so the wallet file is intact and unreachable, and the
      // user has no password to type because they were never shown one.
      //
      // The literal is asserted rather than the constant: `wallet_manager_test`
      // already uses `walletPasswordStorageKey` as a variable, which passes
      // whatever the constant happens to say.
      expect(walletPasswordStorageKey, 'walletPassword');

      // And it is the key the store actually reaches for, not just a constant
      // sitting next to one; the same reasoning as this file's header.
      WalletSecrets.store = secrets;
      await storeMobileWalletPassword('minted-at-restore');
      expect(secrets.values.keys, ['walletPassword']);
      expect(await getMobileWalletPassword(), 'minted-at-restore');
    });
  });

  group('the shipped preference layouts', () {
    test('the namers are the schemes each app already shipped', () {
      // The cheap half of the guard, and the one that reads as documentation:
      // these two strings are on real users' devices.
      expect(
        WalletAppConfig.skylight.prefKeyNamer('XMR', 'walletRestoreHeight'),
        'walletRestoreHeight',
      );
      expect(
        WalletAppConfig.spice.prefKeyNamer('XMR', 'walletRestoreHeight'),
        'xmr_walletRestoreHeight',
      );
    });

    test('Skylight keys are bare, exactly as it shipped them', () async {
      installSkylight();
      final xmr = FakeWallet('XMR');
      addTearDown(xmr.dispose);

      await persistAConnection(xmr);

      // Skylight is single-coin and shipped unprefixed keys. Adding a prefix
      // here would strand every existing user's server settings.
      expect(
        prefs.values.keys,
        containsAll([
          'connectionAddress',
          'connectionProxyPort',
          'connectionUseTor',
          'connectionType',
        ]),
      );
      expect(prefs.values.keys.where((k) => k.startsWith('xmr_')), isEmpty);
    });

    test('Spice namespaces every key by coin', () async {
      installSpice();
      final xmr = FakeWallet('XMR');
      addTearDown(xmr.dispose);

      await persistAConnection(xmr);

      expect(prefs.values.keys, containsAll(['xmr_connectionAddress', 'xmr_connectionType']));
      expect(prefs.values.containsKey('connectionAddress'), isFalse);
    });

    test('two Spice coins keep separate connections', () async {
      installSpice();
      final xmr = FakeWallet('XMR');
      final btc = FakeWallet('BTC');
      addTearDown(xmr.dispose);
      addTearDown(btc.dispose);

      await persistAConnection(xmr, address: 'xmr.example.com');
      await persistAConnection(btc, address: 'btc.example.com');

      expect((await xmr.getPersistedConnection()).address, 'xmr.example.com');
      expect((await btc.getPersistedConnection()).address, 'btc.example.com');
    });

    test('a Skylight read finds what a Skylight write left', () async {
      installSkylight();
      final xmr = FakeWallet('XMR');
      addTearDown(xmr.dispose);

      await persistAConnection(xmr, address: 'lws.example.com');
      final read = await xmr.getPersistedConnection();

      // The round trip is the point: a namer applied on write but not on read
      // (or vice versa) passes a key-name assertion and still loses the setting.
      expect(read.address, 'lws.example.com');
      expect(read.connectionType, 'node');
    });
  });

  group('the shipped wallet-file layouts', () {
    test('Skylight writes one mywallet, whatever the coin is called', () {
      installSkylight();
      final namer = WalletAppConfig.instance.walletFileNamer;
      expect(namer('XMR'), 'mywallet');
      expect(namer('BTC'), 'mywallet');
    });

    test('Spice writes one file per coin', () {
      installSpice();
      final namer = WalletAppConfig.instance.walletFileNamer;
      expect(namer('XMR'), 'mywallet_xmr');
      expect(namer('BTC'), 'mywallet_btc');
    });
  });

  group('a token shares its parent connection, not its per-coin state', () {
    // An ERC-20 token has no RPC of its own: it reads the parent chain's, so
    // setting the node once from either side works. Everything else about it;
    // its transactions, what the user has been told about, where its history
    // starts; belongs to the token.
    //
    // Spice keeps these in two namespaces for that reason (`prefKey` on the
    // coin, `_connPrefKey` on the connection owner). Collapsing them into one
    // is silent: the token reads the parent's marker and stops announcing.

    test('the connection is shared with the parent', () async {
      installSpice();
      final eth = FakeWallet('ETH');
      final dai = FakeTokenWallet('DAI', 'ETH');
      addTearDown(eth.dispose);
      addTearDown(dai.dispose);

      await persistAConnection(eth, address: 'rpc.example.com');

      // Set once on the chain coin, found by the token, so no second setup screen.
      expect((await dai.getPersistedConnection()).address, 'rpc.example.com');
    });

    test('the notification marker is the token own, not the parent one', () async {
      installSpice();
      final eth = FakeWallet('ETH');
      final dai = FakeTokenWallet('DAI', 'ETH');
      addTearDown(eth.dispose);
      addTearDown(dai.dispose);

      await eth.markExistingTxsAsNotified();
      await dai.markExistingTxsAsNotified();

      expect(
        secrets.values.keys,
        containsAll(['eth_txNotificationState', 'dai_txNotificationState']),
      );
    });

    test('a later cutoff on the parent does not silence the token', () async {
      installSpice();
      final dai = FakeTokenWallet('DAI', 'ETH');
      addTearDown(dai.dispose);

      final seen = <String>[];
      CryptoWallet.incomingTxNotifier = (tx, coin) => seen.add('$coin:${tx.hash}');

      // Two coins that have been running independently. The chain coin saw a
      // native transaction recently; the token has not seen one in a while.
      // Cutoffs are seeded directly so the gap between them is exact rather
      // than a function of how fast the test runs.
      secrets.values['dai_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });
      secrets.values['eth_txNotificationState'] = jsonEncode({
        'cutoff': 5000,
        'announcedHashes': <String>[],
      });

      // A transfer lands in the window between the two: new to the token,
      // already in the past as far as the chain coin is concerned.
      dai.history = [_tx('dai-transfer', timestamp: 2000)];
      await dai.loadTxHistory(persistCount: false);
      await dai.notifyNewIncomingTxs();

      expect(
        seen,
        ['DAI:dai-transfer'],
        reason: 'reading the parent cutoff swallows every token receipt older than it, in silence',
      );
    });

    test('the persisted history count is the token own', () async {
      installSpice();
      final eth = FakeWallet('ETH');
      final dai = FakeTokenWallet('DAI', 'ETH');
      addTearDown(eth.dispose);
      addTearDown(dai.dispose);

      eth.history = List.generate(3, (i) => _tx('eth-$i'));
      dai.history = [_tx('dai-0')];
      await eth.loadTxHistory();
      await dai.loadTxHistory();

      expect(await eth.getPersistedTxHistoryCount(), 3);
      expect(await dai.getPersistedTxHistoryCount(), 1);
    });

    test('deleting the token leaves the parent state alone', () async {
      installSpice();
      final eth = FakeWallet('ETH');
      final dai = FakeTokenWallet('DAI', 'ETH');
      addTearDown(eth.dispose);
      addTearDown(dai.dispose);

      eth.history = [_tx('eth-0')];
      await eth.loadTxHistory();
      await eth.markExistingTxsAsNotified();
      await persistAConnection(eth, address: 'rpc.example.com');

      // Removing one token from a multicoin wallet must not reach into the
      // chain coin. Wiping its marker makes the chain coin reseed and stay
      // quiet about its next receipts.
      await dai.clearPersistedState();

      expect(await eth.getPersistedTxHistoryCount(), 1);
      expect(secrets.values.containsKey('eth_txNotificationState'), isTrue);
      // The shared half is shared on purpose and stays put.
      expect((await eth.getPersistedConnection()).address, 'rpc.example.com');
    });
  });
}

TxDetails _tx(String hash, {int timestamp = 1000}) => TxDetails(
  index: 0,
  direction: txDirectionIncoming,
  hash: hash,
  amountBaseUnits: BigInt.one,
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: timestamp,
  height: 100,
  confirmations: 1,
  key: '',
);
