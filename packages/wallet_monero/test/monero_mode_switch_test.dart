import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// The LWS↔node switch: `applyConnectionChange` and
/// `_rebuildForConnectionType`.
///
/// This runs when the user changes server type in the settings form, and it is
/// the most destructive routine in the class that is not called `delete`. It
/// closes an open wallet, then either re-opens a different file or recovers one
/// from the seed it just read out of the wallet it closed.
///
/// The matrix is {LWS, node} × {target file exists, does not}, plus the
/// property that ties it together; **the existing password is reused**. Each
/// mode file is encrypted with its own password, so recovering one with a
/// freshly minted password desyncs the pair permanently: the user ends up with
/// two files, one of which nothing can open again.

const _polyseed = 'aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp'; // 16 words
const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _password = 'the-existing-password';

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mode_switch');
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

  Future<String> pathFor(String type) => wallet.walletPathForType(type);

  /// Opens a wallet in [mode] whose seed is [seed], then clears the recording so
  /// each test asserts only what the switch itself did.
  Future<void> openIn(String mode, {String seed = _legacy25}) async {
    connect(mode);
    await wallet.restoreFromSeed(
      seed: seed.split(' ').length == 16 ? PolyseedSeed(seed) : MoneroLegacySeed(seed),
      from: RestorePoint.height(2_800_000),
      password: _password,
    );
    // A restore writes no file through the fake, so make the source mode's file
    // real; the switch keys on whether the *target* exists, and a missing
    // source would confuse that reading.
    await File(await pathFor(mode)).writeAsString('wallet');
    backend.existingWalletPaths.add(await pathFor(mode));
    backend.reset();
  }

  /// Makes [mode]'s file exist on disk and be openable.
  Future<void> targetFileExists(String mode) async {
    await File(await pathFor(mode)).writeAsString('wallet');
    backend.existingWalletPaths.add(await pathFor(mode));
  }

  group('the target file already exists — re-open, never recover', () {
    test('LWS to node', () async {
      await openIn('lws');
      await targetFileExists('node');

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      // Recovering over an existing file is the destructive mistake here: it
      // would rewrite a wallet the user already has, and wallet2 refuses it
      // anyway (hence the delete-and-retry path elsewhere).
      expect(backend.legacyRestores, isEmpty);
      expect(backend.polyseedRestores, isEmpty);
      expect(backend.opens.single.path, endsWith('/mywallet_node'));
    });

    test('node to LWS', () async {
      await openIn('node');
      await targetFileExists('lws');

      connect('lws');
      await wallet.applyConnectionChange(password: _password);

      expect(backend.legacyRestores, isEmpty);
      expect(backend.opens.single.path, endsWith('/mywallet'));
    });

    test('the old wallet is closed before the new one is opened', () async {
      await openIn('lws');
      await targetFileExists('node');

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      // Two wallets open on one seed means two sync loops writing one cache.
      final closeAt = backend.calls.indexOf('closeWallet');
      final openAt = backend.calls.indexOf('openWallet');
      expect(closeAt, isNonNegative, reason: 'the old wallet must be closed');
      expect(openAt, greaterThan(closeAt));
    });
  });

  group('the target file does not exist — recover it from the seed', () {
    test('LWS to node recovers the node file', () async {
      await openIn('lws');

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      expect(backend.opens, isEmpty, reason: 'nothing to open yet');
      expect(backend.legacyRestores.single.path, endsWith('/mywallet_node'));
    });

    test('node to LWS recovers the LWS file', () async {
      await openIn('node');

      connect('lws');
      await wallet.applyConnectionChange(password: _password);

      expect(backend.legacyRestores.single.path, endsWith('/mywallet'));
    });

    test('a polyseed wallet recovers through the polyseed factory', () async {
      await openIn('lws', seed: _polyseed);

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      // The seed is read back out of the open wallet, so which factory runs is
      // decided by what that wallet reports, not by what the app remembers.
      expect(backend.polyseedRestores.single.mnemonic, _polyseed);
      expect(backend.legacyRestores, isEmpty);
    });

    test('the restore height carries across', () async {
      await openIn('lws');
      backend.refreshFromBlockHeight = 2_800_000;

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      // A rebuilt file that starts scanning from zero re-scans years of chain;
      // one that starts too late silently misses transactions.
      expect(backend.legacyRestores.single.restoreHeight, 2_800_000);
    });
  });

  group('the existing password is reused', () {
    test('on the recover path', () async {
      await openIn('lws');

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      // The property the whole routine turns on. Each mode file is encrypted
      // with its own password; minting a fresh one here leaves the user with a
      // node file nothing can ever open, and no error at the time.
      expect(backend.legacyRestores.single.password, _password);
    });

    test('on the re-open path', () async {
      await openIn('lws');
      await targetFileExists('node');

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      expect(backend.opens.single.password, _password);
    });

    test('and on a polyseed recover', () async {
      await openIn('lws', seed: _polyseed);

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      expect(backend.polyseedRestores.single.password, _password);
    });
  });

  group('when no rebuild is needed', () {
    test('the same mode re-applied opens and recovers nothing', () async {
      await openIn('lws');

      connect('lws');
      await wallet.applyConnectionChange(password: _password);

      // Changing the server *address* within a mode must not rebuild the file.
      expect(backend.opens, isEmpty);
      expect(backend.legacyRestores, isEmpty);
      expect(backend.called('closeWallet'), isFalse);
    });

    test('a different address in the same mode is not a rebuild', () async {
      await openIn('lws');

      wallet.setConnection(
        address: 'other-lws.example.com:18090',
        proxyPort: '',
        useTor: false,
        connectionType: 'lws',
      );
      await wallet.applyConnectionChange(password: _password);

      expect(backend.legacyRestores, isEmpty);
      expect(backend.called('closeWallet'), isFalse);
    });

    test('an unopened wallet rebuilds nothing', () async {
      connect('lws');

      await wallet.applyConnectionChange(password: _password);

      // `needsRebuildForCurrentConnection` is false with no wallet open, so
      // this is the settings form applied before onboarding finished.
      expect(backend.legacyRestores, isEmpty);
      expect(backend.opens, isEmpty);
    });
  });

  group('Spice BIP39-only policy — a legacy-reading wallet still switches modes', () {
    // Regression: a Monero wallet Spice created from BIP39 reads its own seed
    // back as a 25-word legacy seed. The LWS↔node rebuild recovers the target
    // file from that seed; Spice's `acceptedForRestore: {bip39}` must NOT reject
    // it, because this is an internal rebuild of the same wallet, not a user
    // importing an arbitrary seed. Before the fix this threw
    // UnsupportedSeedFormatException(moneroLegacy) on the first switch to node.
    const bip39 =
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about';

    setUp(() {
      WalletAppConfig.resetForTesting();
      WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    });

    test('LWS to node recovers the node file from the derived legacy seed', () async {
      connect('lws');
      await wallet.restoreFromSeed(
        seed: Bip39Seed(bip39),
        from: RestorePoint.height(2_800_000),
        password: _password,
      );
      await File(await pathFor('lws')).writeAsString('wallet');
      backend.existingWalletPaths.add(await pathFor('lws'));
      backend.reset();

      connect('node');
      await wallet.applyConnectionChange(password: _password);

      expect(backend.legacyRestores, hasLength(1));
      expect(backend.legacyRestores.single.password, _password);
    });
  });

  group('state that must not survive the switch', () {
    test('the cached daemon height is cleared', () async {
      await openIn('node');
      backend.chainHeight = 3_000_000;
      backend.walletHeight = 2_900_000;
      backend.synchronizedValue = false;
      await wallet.connectToDaemonImpl(address: 'n:18081');
      await wallet.loadSyncedHeight();
      await wallet.daemonHeightFetch;
      expect(wallet.syncBlocksRemaining, isNotNull);

      connect('lws');
      await wallet.applyConnectionChange(password: _password);

      // The old mode's daemon height describes a chain view this wallet no
      // longer has; left cached it drives a sync-progress bar for the wrong
      // wallet. LWS reports null regardless, which is the check here.
      expect(wallet.syncBlocksRemaining, isNull);
    });

    test('the loaded mode is updated, so a second switch back also rebuilds', () async {
      await openIn('lws');

      connect('node');
      await wallet.applyConnectionChange(password: _password);
      expect(backend.legacyRestores, hasLength(1));

      // Switching back must be seen as a change again. If `_loadedKind` were
      // left stale the predicate would report "no rebuild needed" and the
      // wallet would keep using the node file while the UI said LWS.
      backend.reset();
      // `reset()` clears the fake's file registry, but the rebuild decides
      // exists-or-not from the *real* filesystem and only then asks the
      // backend to open. Re-register so the two agree, or the fake reports
      // "no such file" for a path that is sitting right there.
      await targetFileExists('lws');

      connect('lws');
      await wallet.applyConnectionChange(password: _password);
      expect(
        backend.opens.single.path,
        endsWith('/mywallet'),
        reason: 'the switch back is a rebuild too',
      );
    });
  });

  group('the refresh/connection timers do not race the rebuild', () {
    // Regression: the 20s refresh timer calls store() on the native wallet. If
    // it fires while applyConnectionChange is closing that wallet to rebuild it,
    // store() runs on a freed handle; a SIGSEGV in the native lib, not a Dart
    // exception. The rebuild must hold the timers off until the close is done.
    test('a timer tick during the close is a no-op', () async {
      await openIn('lws'); // legacy-seed wallet in LWS mode
      connect('node'); // node file does not exist → recover path, which closes first
      backend.reset();

      final closeGate = Completer<void>();
      backend.pauseNextClose = closeGate;
      backend.closeStarted = Completer<void>();

      // Start the switch; it suspends sync, then blocks in closeWallet with the
      // handle mid-free.
      final rebuild = wallet.applyConnectionChange(password: _password);
      await backend.closeStarted!.future;

      final callsAtClose = List.of(backend.calls);

      // Drive the timers by hand, the way the periodic ones would fire here.
      await wallet.refreshTask();
      await wallet.checkConnectionTask();

      // Neither touched the wallet: no store(), no recover, no connectivity probe
      // while the handle is being freed.
      expect(
        backend.calls,
        callsAtClose,
        reason: 'refresh/connection ticks must not touch the wallet during a rebuild',
      );

      closeGate.complete();
      await rebuild;
    });
  });
}
