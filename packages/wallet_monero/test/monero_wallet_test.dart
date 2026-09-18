import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// `MoneroWallet` orchestration against [FakeMoneroBackend].
///
/// Every group here covers a path that behaves differently in the two apps, and
/// in each case Spice's behaviour is the broken one. Without the FFI seam none
/// of this could be tested at all; each case would need a dylib, a wallet file
/// and often a network.
const _polyseed = 'aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp'; // 16 words
const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _bip39 =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';

/// A transaction at [confirmations], for the confirmation-threshold check.
TxDetails _tx({required int confirmations, int height = 3000000}) => TxDetails(
  index: 0,
  direction: txDirectionIncoming,
  hash: 'a',
  amountBaseUnits: BigInt.one,
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: 1700000000,
  height: height,
  confirmations: confirmations,
  key: '',
);

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_wallet');
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

  void connect({String type = 'lws'}) => wallet.setConnection(
    address: 'lws.example.com:18090',
    proxyPort: '',
    useTor: false,
    connectionType: type,
  );

  Future<String> pathFor(String type) => wallet.walletPathForType(type);

  group('metadata', () {
    test('Monero accepts all three seed formats', () {
      expect(wallet.supportedSeedFormats, {
        SeedFormat.polyseed,
        SeedFormat.bip39,
        SeedFormat.moneroLegacy,
      });
    });

    test('offers both server kinds', () => expect(wallet.connectionTypeOptions, ['lws', 'node']));

    test('ten confirmations, and isTxConfirmed uses that rather than a literal', () {
      expect(wallet.requiredConfirmations, 10);
      // The threshold reaches the display through `isTxConfirmed`; a hardcoded
      // number anywhere else would disagree with it for some coin.
      expect(wallet.isTxConfirmed(_tx(confirmations: 9)), isFalse);
      expect(wallet.isTxConfirmed(_tx(confirmations: 10)), isTrue);
      // Height -1 is the mempool. Confirmations there are meaningless, and a
      // reorg can hand back a stale count.
      expect(wallet.isTxConfirmed(_tx(confirmations: 99, height: -1)), isFalse);
    });

    test('resolveWalletPath follows the current connection type', () async {
      // Everything destructive in this class; the rebuild, the restore retry,
      // the deletion sweep; resolves its path through here, so it tracking
      // the live mode rather than the one at open time is load-bearing.
      connect();
      expect(await wallet.resolveWalletPath(), endsWith('/mywallet'));

      connect(type: 'node');
      expect(await wallet.resolveWalletPath(), endsWith('/mywallet_node'));
    });

    test('defers stats only in node mode', () {
      connect();
      expect(wallet.deferStatsUntilSynced, isFalse);
      connect(type: 'node');
      expect(wallet.deferStatsUntilSynced, isTrue);
    });

    test('polls connected status every second, not on the 15s base throttle', () {
      // Wallet_connected is a local read, so it can be checked on the fast
      // cadence; the base throttle exists for coins whose probe is networked.
      expect(wallet.connectivityCheckInterval, const Duration(seconds: 1));
    });

    test('validation asks monero_c rather than guessing from the shape', () {
      expect(wallet.isAddressValid('4${'A' * 94}'), isFalse, reason: 'standard shape only');
      expect(wallet.isAddressValid('8${'A' * 94}'), isFalse, reason: 'subaddress shape only');
      expect(wallet.isAddressValid('4${'A' * 105}'), isFalse, reason: 'integrated shape only');

      expect(
        backend.addressValidCalls.map((c) => c.networkType).toSet(),
        {0},
        reason: 'checked against mainnet, the network the wallet is built for',
      );
    });

    test('an address monero_c accepts is payable, whatever its shape', () {
      // Length and leading character are monero_c's business now, not a list
      // kept in step by hand here.
      backend.addressValidator = (address, _) => address == 'accepted-by-monero-c';
      expect(wallet.isAddressValid('accepted-by-monero-c'), isTrue);
    });

    test('an empty address is refused without troubling the validator', () {
      backend.addressValidCalls.clear();
      expect(wallet.isAddressValid(''), isFalse);
      expect(backend.addressValidCalls, isEmpty);
    });
  });

  group('the two modes use separate files', () {
    test('node gets a _node suffix, LWS keeps the base name', () async {
      expect(await pathFor('lws'), endsWith('/mywallet'));
      expect(await pathFor('node'), endsWith('/mywallet_node'));
    });

    test('a bare wallet name and a coin-suffixed one both round-trip', () async {
      expect(await pathFor('lws'), endsWith('/mywallet'));

      WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
      final spiceWallet = MoneroWallet(backend: backend);
      expect(await spiceWallet.walletPathForType('lws'), endsWith('/mywallet_xmr'));
      expect(await spiceWallet.walletPathForType('node'), endsWith('/mywallet_xmr_node'));
      spiceWallet.dispose();
    });

    test('each mode asks for its own manager factory', () async {
      connect();
      await wallet.hasExistingWallet();
      expect(backend.managersRequested.last, MoneroManagerKind.lws);

      connect(type: 'node');
      await wallet.hasExistingWallet();
      expect(backend.managersRequested.last, MoneroManagerKind.node);
    });
  });

  group('mode/file mismatch recovery', () {
    test('adopts the mode that actually has a wallet file', () async {
      // The scenario: persisted mode says LWS, but only a node file exists;
      // an LWS↔node switch interrupted before the new file was written.
      // Spice reports "no wallet" and sends the user through onboarding on top
      // of an existing wallet.
      connect();
      await File(await pathFor('node')).writeAsString('wallet');

      expect(await wallet.hasExistingWallet(), isTrue);
      expect(wallet.connectionType, 'node', reason: 'switched to the mode with a file');
    });

    test('recognises a node wallet by its .keys file alone', () async {
      // wallet2 writes `<path>` plus `<path>.keys`; a partial write can leave
      // only the latter.
      connect();
      await File('${await pathFor('node')}.keys').writeAsString('keys');
      expect(await wallet.hasExistingWallet(), isTrue);
      expect(wallet.connectionType, 'node');
    });

    test('persists the adopted type, not just in memory', () async {
      connect();
      await File(await pathFor('node')).writeAsString('wallet');
      await wallet.hasExistingWallet();

      expect(
        await SharedPreferencesService.get<String>('connectionType'),
        'node',
        reason: 'callers reload the connection right after this check',
      );
    });

    test('reports no wallet when neither mode has a file', () async {
      connect();
      expect(await wallet.hasExistingWallet(), isFalse);
      expect(wallet.connectionType, 'lws', reason: 'nothing to adopt');
    });

    test('does not switch when the current mode already has a file', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await File(await pathFor('node')).writeAsString('wallet');

      expect(await wallet.hasExistingWallet(), isTrue);
      expect(wallet.connectionType, 'lws', reason: 'current mode wins');
    });
  });

  group('restore dispatches on seed format', () {
    test('a polyseed goes through the polyseed factory', () async {
      connect();
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );

      expect(backend.polyseedRestores, hasLength(1));
      expect(backend.legacyRestores, isEmpty, reason: 'Spice would use recoveryWallet');
      expect(backend.polyseedRestores.single.mnemonic, _polyseed);
    });

    test('a 25-word legacy seed goes straight to recoveryWallet', () async {
      connect();
      await wallet.restoreFromSeed(
        seed: const MoneroLegacySeed(_legacy25),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );

      expect(backend.legacyRestores, hasLength(1));
      expect(backend.legacyRestores.single.mnemonic, _legacy25);
      expect(backend.polyseedRestores, isEmpty);
    });

    test('BIP39 is converted to a legacy word list first', () async {
      connect();
      await wallet.restoreFromSeed(
        seed: const Bip39Seed(_bip39),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );

      expect(backend.legacyRestores, hasLength(1));
      final used = backend.legacyRestores.single.mnemonic;
      expect(used, isNot(_bip39), reason: 'converted, not passed through');
      expect(used.split(' '), hasLength(25));
    });

    test('an empty password is refused', () async {
      connect();
      expect(
        wallet.restoreFromSeed(
          seed: const Bip39Seed(_bip39),
          from: const RestorePoint.height(1),
          password: '',
        ),
        throwsException,
      );
    });
  });

  group('the newWallet flag — the most dangerous value in this layer', () {
    test('RestorePoint.newWallet() sets it', () async {
      // Set for a seed that HAS history and the wallet comes up permanently
      // empty, with no error at all.
      connect();
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.newWallet(),
        password: 'pw',
      );

      final restore = backend.polyseedRestores.single;
      expect(restore.newWallet, isTrue);
      // Both backends' polyseed factories ignore the height once `newWallet` is
      // set, so what is forwarded here does not matter; the row that used to
      // pin a 0 was pinning the bug in the test below rather than a property of
      // this path.
    });

    test('a new wallet does not scan from genesis', () async {
      // `WalletManagerImpl::recoveryWallet` applies the height it is given only
      // `if (restoreHeight > 0)`, so a 0 left wallet2's default in place and a
      // freshly created bip39 wallet scanned from April 2014; hours of work
      // for a wallet that cannot own anything older than this minute.
      connect();
      await wallet.restoreFromSeed(
        seed: const Bip39Seed(_bip39),
        from: const RestorePoint.newWallet(),
        password: 'pw',
      );

      final restore = backend.legacyRestores.single;
      expect(restore.restoreHeight, greaterThan(3000000));
    });

    test('a seed with no birthday still scans from genesis, and says so', () async {
      // The other half of the same switch, and deliberately *not* fixed the
      // same way. A bip39 phrase carries no birthday, so a caller asking for one
      // is asking for information that does not exist, and a height that is too
      // high skips the blocks holding the user's funds and reports an empty
      // wallet with no error at all. A slow scan is the better failure.
      connect();
      await wallet.restoreFromSeed(
        seed: const Bip39Seed(_bip39),
        from: const RestorePoint.seedBirthday(),
        password: 'pw',
      );

      expect(backend.legacyRestores.single.restoreHeight, 0);
    });

    test('a height-based restore leaves it false and forwards the height', () async {
      connect();
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );

      final restore = backend.polyseedRestores.single;
      expect(restore.newWallet, isFalse);
      expect(restore.restoreHeight, 3000000);
    });

    test('a date-based restore converts to a height', () async {
      connect();
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: RestorePoint.date(DateTime(2020, 6, 15)),
        password: 'pw',
      );
      expect(backend.polyseedRestores.single.restoreHeight, greaterThan(2000000));
    });
  });

  group('wallet2 polyseed height fix', () {
    test('node mode re-applies the height after a polyseed restore', () async {
      // wallet2's polyseed factory derives the scan start from the seed birthday
      // and DROPS the height it was handed. Without this the restore is
      // silently empty.
      connect(type: 'node');
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );
      expect(backend.setRefreshHeights, contains(3000000));
    });

    test('LWS mode does not — LWSF honours the height already', () async {
      connect();
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );
      expect(backend.setRefreshHeights, isEmpty);
    });

    test('a legacy restore in node mode does not need it', () async {
      connect(type: 'node');
      await wallet.restoreFromSeed(
        seed: const MoneroLegacySeed(_legacy25),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );
      expect(backend.setRefreshHeights, isEmpty);
    });
  });

  group('"file already exists" retry', () {
    test('clears the mode files and retries once', () async {
      // wallet2 refuses to recover onto an existing file, which surfaces as an
      // unexplained failure the user cannot escape. Spice has no recovery.
      connect();
      final path = await pathFor('lws');
      await File(path).writeAsString('stale');
      backend.queuedRestoreErrors.add('file already exists');

      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(3000000),
        password: 'pw',
      );

      expect(backend.countOf('createWalletFromPolyseed'), 2, reason: 'one retry, not a loop');
      expect(wallet.isLoaded, isTrue);
    });

    test('a fresh-wallet creation does not retry', () async {
      // There would be no seed in hand to recover a clobbered file from.
      connect();
      backend.queuedRestoreErrors.add('file already exists');

      await expectLater(
        wallet.restoreFromSeed(
          seed: const PolyseedSeed(_polyseed),
          from: const RestorePoint.newWallet(),
          password: 'pw',
        ),
        throwsException,
      );
      expect(backend.countOf('createWalletFromPolyseed'), 1);
    });

    test('an invalid mnemonic reports that, not a generic failure', () async {
      connect();
      backend.queuedRestoreErrors.add('Failed polyseed decode');
      await expectLater(
        wallet.restoreFromSeed(
          seed: const PolyseedSeed(_polyseed),
          from: const RestorePoint.height(1),
          password: 'pw',
        ),
        throwsA(
          isA<Exception>().having((e) => e.toString(), 'message', contains('Invalid mnemonic')),
        ),
      );
    });

    test('an unreachable server is not treated as a restore failure', () async {
      // The wallet file is written; the server is just down right now.
      connect();
      backend.queuedRestoreErrors.add('No response from HTTP server');
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(1),
        password: 'pw',
      );
      expect(wallet.isLoaded, isTrue);
    });

    test('a pre-connect "Invalid argument" is not treated as a restore failure', () async {
      // The LWS rescan restore fires before connect; its pre-connect error
      // surfaces as "Invalid argument" but the wallet file is written.
      connect();
      backend.queuedRestoreErrors.add('Invalid argument');
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(1),
        password: 'pw',
      );
      expect(wallet.isLoaded, isTrue);
    });

    test('a bare non-zero status with no message is not fatal on cold start', () async {
      // First restore on a fresh install: monero_c reports a non-zero status but
      // leaves errorString empty, yet writes the file. Treating that as fatal is
      // the "unknown error on the first tap, works on the second" bug; an empty
      // message is never a real failure, so restore must complete.
      connect();
      backend.queuedRestoreStatuses.add(1);
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(1),
        password: 'pw',
      );
      expect(wallet.isLoaded, isTrue);
    });
  });

  group('double-open guard', () {
    test('opening twice for the same mode opens once', () async {
      // Two open wallets against one file means two sync loops writing the
      // same cache, and the first is never closed.
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));

      await wallet.openExisting(password: 'pw');
      await wallet.openExisting(password: 'pw');

      expect(backend.countOf('openWallet'), 1);
    });

    test('a mode change does allow a re-open', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');

      connect(type: 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await wallet.openExisting(password: 'pw');

      expect(backend.countOf('openWallet'), 2);
    });

    test('a failed open throws rather than reporting success', () async {
      connect();
      // No file registered, so the fake reports an error string.
      expect(wallet.openExisting(password: 'pw'), throwsException);
    });
  });

  group('primary address', () {
    // The LWS whitelisting screens show it so the user can hand it to a server
    // they have not connected to yet. Cached only by `load()`, it stayed blank
    // until a sync had run, so a wallet with no reachable server showed none.
    test('is cached by the open itself, with no load or connect', () async {
      backend.defaultAddress = '4${'d' * 94}';
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));

      await wallet.openExisting(password: 'pw');

      expect(wallet.getPrimaryAddress(), backend.defaultAddress);
      expect(backend.countOf('init'), 0, reason: 'no daemon was contacted');
    });

    test('is cached by a restore, before the first sync', () async {
      connect();

      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(2900000),
        password: 'pw',
      );

      // The fake derives the address from the seed, so this is the restored
      // wallet's own address rather than a leftover default.
      expect(wallet.getPrimaryAddress(), backend.addressesBySeed[_polyseed]);
      expect(wallet.getPrimaryAddress(), isNotEmpty);
    });
  });

  group('restore height', () {
    test('falls back to the persisted height when the backend reports 0', () async {
      // Needed to rebuild the other mode's file from the seed on
      // an LWS↔node switch, where the backend returns 0.
      connect();
      await wallet.restoreFromSeed(
        seed: const PolyseedSeed(_polyseed),
        from: const RestorePoint.height(2900000),
        password: 'pw',
      );

      backend.refreshFromBlockHeight = 0;
      expect(await wallet.getRestoreHeight(), 2900000);
    });

    test('prefers the backend height when it has one', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      backend.refreshFromBlockHeight = 3111111;
      expect(await wallet.getRestoreHeight(), 3111111);
    });
  });

  group('fee estimation — needs the pinned monero_c fork', () {
    test('returns the estimate', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');

      backend.feeEstimate = BigInt.from(31230000);
      expect(
        await wallet.estimateFee('4${'A' * 94}', BigInt.from(1000000000000)),
        BigInt.from(31230000),
      );
    });

    test('a zero estimate is null, never a real fee', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');

      backend.feeEstimate = null;
      expect(await wallet.estimateFee('4${'A' * 94}', BigInt.one), isNull);
    });

    test('returns null with no open wallet rather than throwing', () async {
      expect(await wallet.estimateFee('4${'A' * 94}', BigInt.one), isNull);
    });

    group('a missing estimate is recorded', () {
      // Nothing above this layer can tell "no estimate" from a zero fee: the C
      // wrapper returns 0 from its own `catch (...)`, and the send screen shows
      // a bare dash for both. These lines are the only trace either leaves.
      late MemoryLogSink logs;

      setUp(() {
        logs = MemoryLogSink();
        WalletLog.sink = logs;
      });

      tearDown(WalletLog.resetForTesting);

      Future<String> logged() async {
        await Future<void>.delayed(Duration.zero);
        return logs.records.map((r) => r.line).join('\n');
      }

      test('an empty estimate says so, with the state that decides it', () async {
        connect(type: 'node');
        backend.existingWalletPaths.add(await pathFor('node'));
        await wallet.openExisting(password: 'pw');

        backend.feeEstimate = null;
        expect(await wallet.estimateFee('4${'A' * 94}', BigInt.one, priority: 2), isNull);

        final written = await logged();
        expect(written, contains('estimateFee: none'));
        expect(written, contains('priority 2'));
        expect(written, contains('node=true'), reason: 'the mode this only happens in');
        expect(written, contains('daemon='));
      });

      test('a throw is distinguishable from an empty estimate', () async {
        connect();
        backend.existingWalletPaths.add(await pathFor('lws'));
        await wallet.openExisting(password: 'pw');

        backend.feeEstimateError = StateError('ffi blew up');
        expect(await wallet.estimateFee('4${'A' * 94}', BigInt.one), isNull);

        final written = await logged();
        expect(written, contains('estimateFee threw'));
        expect(written, contains('ffi blew up'));
        expect(written, isNot(contains('estimateFee: none')));
      });

      test('neither line carries the destination or the amount', () async {
        connect();
        backend.existingWalletPaths.add(await pathFor('lws'));
        await wallet.openExisting(password: 'pw');

        backend.feeEstimate = null;
        await wallet.estimateFee('4${'A' * 94}', BigInt.from(1234567890123));

        final written = await logged();
        expect(written, isNotEmpty, reason: 'the assertions below would be vacuous');
        expect(written, isNot(contains('4AAAAA')));
        expect(written, isNot(contains('1234567890123')));
      });

      test('no open wallet is its own line, not silence', () async {
        expect(await wallet.estimateFee('4${'A' * 94}', BigInt.one), isNull);
        expect(await logged(), contains('estimateFee: no open wallet'));
      });
    });
  });

  group('sweeps and churns carry the fee', () {
    // Two shapes, and the fee is the whole subject of both. A **sweep** has one
    // destination and no change, so the amount is whatever is left after the fee
    //; monero_c decides that, and the flag is the only thing that tells it to.
    // A **churn** sends back to the wallet's own address, so the fee is the only
    // value that actually leaves.
    //
    // What is testable at this tier is our side of the seam: that the flag and
    // the destination reach monero_c, and that the fee it computed comes back out
    // of `createTx` rather than being dropped or zeroed. What monero_c does with
    // the flag needs a real library to exercise.
    final theirs = '4${'A' * 94}';

    Future<void> openWallet() async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
    }

    test('a sweep asks monero_c to sweep, and returns the fee it worked out', () async {
      await openWallet();
      // What monero_c came back with: everything less its own fee.
      backend.pendingAmount = BigInt.from(1999670000000);
      backend.pendingFee = BigInt.from(330000000);

      final tx = await wallet.createTx(theirs, BigInt.zero, true);

      final request = backend.createTransactionRequests.single;
      expect(request.isSweepAll, isTrue, reason: 'a dropped flag sends the amount, which is zero');
      expect(request.destinations, [theirs]);
      expect(request.mixinCount, MoneroConsts.mixinCount);

      expect(tx.feeBaseUnits, BigInt.from(330000000), reason: "monero_c's fee, not zero");
      expect(tx.amountBaseUnits, BigInt.from(1999670000000));
    });

    test('a churn is a sweep to our own address, and costs the same fee', () async {
      backend.defaultAddress = '4${'c' * 94}';
      await openWallet();
      await wallet.loadPrimaryAddress();
      final ours = wallet.getPrimaryAddress();
      expect(ours, backend.defaultAddress, reason: 'the churn destination is this wallet');

      backend.pendingAmount = BigInt.from(1999670000000);
      backend.pendingFee = BigInt.from(330000000);

      final tx = await wallet.createTx(ours, BigInt.zero, true);

      // Paying ourselves changes nothing about how the transaction is built: the
      // fee is still monero_c's, and the destination is still passed through
      // rather than being recognised as our own and handled some other way.
      expect(backend.createTransactionRequests.single.isSweepAll, isTrue);
      expect(backend.createTransactionRequests.single.destinations, [ours]);
      expect(tx.feeBaseUnits, BigInt.from(330000000));
      expect(tx.amountBaseUnits, BigInt.from(1999670000000));
    });

    test('a non-sweep send passes the amount and leaves the flag off', () async {
      // The other half of the same property: the flag is not set for a normal
      // send, or every send becomes a sweep of the whole balance.
      await openWallet();
      await wallet.createTx(theirs, BigInt.from(1500000000000), false);

      final request = backend.createTransactionRequests.single;
      expect(request.isSweepAll, isFalse);
      expect(request.amounts, [BigInt.from(1500000000000)]);
    });
  });

  group('commit gates success on more than errorString', () {
    Future<MoneroPendingTransaction> pending() async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      return await wallet.createTx('4${'A' * 94}', BigInt.from(1000), false)
          as MoneroPendingTransaction;
    }

    test('a failed broadcast with an empty errorString still throws', () async {
      // The bug this closes: a broadcast can fail without setting errorString,
      // and reporting it as sent is the worst possible outcome.
      final tx = await pending();
      backend.commitResult = false;
      expect(wallet.commitTx(tx, '4${'A' * 94}'), throwsA(isA<FormatException>()));
    });

    test('a non-zero status throws even when commit returned true', () async {
      final tx = await pending();
      backend.commitResult = true;
      backend.pendingStatus = 2;
      expect(wallet.commitTx(tx, '4${'A' * 94}'), throwsA(isA<FormatException>()));
    });

    test('a clean commit succeeds and persists', () async {
      final tx = await pending();
      await wallet.commitTx(tx, '4${'A' * 94}');
      expect(backend.called('commitPendingTx'), isTrue);
      expect(backend.called('store'), isTrue, reason: 'unconfirmed tx must survive a restart');
    });
  });

  group('node-mode sync reporting', () {
    test('syncBlocksRemaining is the gap to the daemon height', () async {
      connect(type: 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'n:18081');

      backend.walletHeight = 2900000;
      backend.chainHeight = 3000000;
      backend.synchronizedValue = false;
      await wallet.loadSyncedHeight();
      // The daemon height is fetched off the poll's critical path; it is the
      // one figure here that can cost a network round trip; so the fetch has
      // to be awaited explicitly rather than raced.
      await wallet.daemonHeightFetch;

      expect(wallet.syncBlocksRemaining, 100000);
    });

    test('is null in LWS mode — the server does the scanning', () async {
      connect();
      expect(wallet.syncBlocksRemaining, isNull);
    });

    test('is null once synced', () async {
      connect(type: 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'n:18081');
      backend.synchronizedValue = true;
      await wallet.loadIsSynced();

      expect(wallet.syncBlocksRemaining, isNull);
    });

    test('a node connect starts the native refresh thread; LWS does not', () async {
      connect(type: 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'n:18081');
      expect(backend.called('startRefresh'), isTrue);

      backend.reset();
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'l:18090');
      expect(backend.called('startRefresh'), isFalse);
    });
  });

  group('store', () {
    test('an open wallet is written', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      backend.reset();

      expect(await wallet.store(), isTrue);
      expect(backend.called('store'), isTrue);
    });

    test('a wallet that is not open reports false instead of calling into native', () async {
      connect();

      // Spice's guard, and the reason this row is P. `Wallet_store` on a null
      // pointer is a segfault, and the refresh cycle calls store() on every
      // tick, including the ticks before a wallet has finished opening.
      expect(await wallet.store(), isFalse);
      expect(backend.called('store'), isFalse);
    });
  });

  group('reading the transaction history', () {
    NativeTxInfo info({
      required String hash,
      required int timestamp,
      String txKey = '',
      String paymentId = '',
      int confirmations = 10,
      String subaddrIndex = '0',
    }) => NativeTxInfo(
      direction: txDirectionIncoming,
      hash: hash,
      amount: BigInt.from(1500000000000),
      fee: BigInt.zero,
      timestamp: timestamp,
      blockHeight: 3000000,
      confirmations: confirmations,
      subaddrAccount: 0,
      subaddrIndex: subaddrIndex,
      isPending: false,
      isFailed: false,
      paymentId: paymentId,
      txKey: txKey,
    );

    Future<void> openWallet() async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
    }

    test('newest first — the pending check reads position zero', () async {
      backend.transactions = [
        info(hash: 'oldest', timestamp: 1000),
        info(hash: 'newest', timestamp: 3000),
        info(hash: 'middle', timestamp: 2000),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      // `loadTxHistory` decides "is anything still pending?" from
      // `history.first`. Read in wallet2's order that is whichever transaction
      // wallet2 happened to store first, and the answer is meaningless.
      expect(wallet.readTxHistory().map((t) => t.hash), ['newest', 'middle', 'oldest']);
    });

    test('the transaction key is the tx key, not the payment ID', () async {
      backend.transactions = [
        info(
          hash: 'a',
          timestamp: 1000,
          txKey: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
          paymentId: '0000000000000000',
        ),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      // Skylight's transaction screen shows this field and lets the user copy
      // it, to prove a payment to a third party. A payment ID proves nothing;
      // it is a linking identifier that happens to be a hex string of about
      // the right shape, so the substitution reads as plausible on screen.
      expect(wallet.readTxHistory().single.key, startsWith('deadbeef'));
      expect(wallet.readTxHistory().single.key, isNot('0000000000000000'));
    });

    test('the key is read from the wallet, which is why the handle is passed', () async {
      backend.transactions = [info(hash: 'a', timestamp: 1000, txKey: 'k')];
      await openWallet();
      await wallet.refreshTxHistory();

      // A caller that drops the wallet handle gets a record with no key and no
      // error, so the omission is asserted directly.
      expect(backend.txKeyRequests, ['a']);
    });

    test('an incoming transaction simply has no key', () async {
      backend.transactions = [info(hash: 'a', timestamp: 1000)];
      await openWallet();
      await wallet.refreshTxHistory();

      // wallet2 stores a key only for transactions it signed. Empty is the
      // honest answer, not an error.
      expect(wallet.readTxHistory().single.key, isEmpty);
    });

    test('a multi-index subaddress list is parsed, and junk in it is dropped', () async {
      backend.transactions = [info(hash: 'a', timestamp: 1000, subaddrIndex: '1, 2,x, 3')];
      await openWallet();
      await wallet.refreshTxHistory();

      expect(wallet.readTxHistory().single.subaddrIndexList, [1, 2, 3]);
    });

    test('an outgoing send reports where it paid', () async {
      backend.transactions = [
        NativeTxInfo(
          direction: txDirectionOutgoing,
          hash: 'paid',
          amount: BigInt.from(500000000000),
          fee: BigInt.from(30000000),
          timestamp: 1000,
          blockHeight: 3000000,
          confirmations: 10,
          subaddrAccount: 0,
          subaddrIndex: '0',
          isPending: false,
          isFailed: false,
          paymentId: '',
          txKey: 'k',
          destinations: [(address: '4recipient', amount: BigInt.from(500000000000))],
        ),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      final tx = wallet.readTxHistory().single;
      expect(tx.recipients.single.address, '4recipient');
      expect(tx.recipients.single.amountBaseUnits, BigInt.from(500000000000));
    });

    test('an outgoing send from another device has no destination to report', () async {
      // wallet2 and LWSF both record destinations when they build the
      // transaction and cannot recover them from the chain, so a send made on a
      // different device with the same seed comes back with none.
      backend.transactions = [
        NativeTxInfo(
          direction: txDirectionOutgoing,
          hash: 'elsewhere',
          amount: BigInt.from(500000000000),
          fee: BigInt.from(30000000),
          timestamp: 1000,
          blockHeight: 3000000,
          confirmations: 10,
          subaddrAccount: 0,
          subaddrIndex: '0',
          isPending: false,
          isFailed: false,
          paymentId: '',
          txKey: '',
        ),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      expect(wallet.readTxHistory().single.recipients, isEmpty);
    });

    test('a swept send records the fee monero_c charged for it', () async {
      backend.transactions = [
        NativeTxInfo(
          direction: txDirectionOutgoing,
          hash: 'swept',
          amount: BigInt.from(1999670000000),
          fee: BigInt.from(330000000),
          timestamp: 1000,
          blockHeight: 3000000,
          confirmations: 10,
          subaddrAccount: 0,
          subaddrIndex: '0',
          isPending: false,
          isFailed: false,
          paymentId: '',
          txKey: 'k',
        ),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      final tx = wallet.readTxHistory().single;
      expect(tx.direction, txDirectionOutgoing);
      expect(tx.amountBaseUnits, BigInt.from(1999670000000));
      // The fee is per-entry and comes straight from the entry: nothing here may
      // derive it from the amount, which for a sweep is already net of it.
      expect(tx.feeBaseUnits, BigInt.from(330000000));
    });

    test('a churn between accounts keeps the fee on the half that paid it', () async {
      // Which churns produce two entries is decided in `wallet2.cpp`, and it is
      // narrower than "a send to ourselves":
      //
      //  - **Same account.** Received outputs whose account matches the spending
      //    account are removed from the received funds ("remove change sent to
      //    the spending subaddress account"), and for a pure self-send the
      //    outgoing amount is zeroed as well (`m_change = self_received`, "so
      //    that it's less confusing"). One outgoing entry, amount 0, and the fee
      //    is the only number it has; see the case below.
      //  - **A different account**, which is this case: the received output
      //    survives, so an `out` and an `in` entry arrive under one hash.
      //
      // Both halves reach us and each keeps its own fee; the mapping does no
      // arithmetic across them, so the fee is not moved onto the incoming half,
      // doubled, or netted away. Anything that later merges the two must preserve
      // that: the fee belongs to the transaction once, and a consumer summing
      // `feeBaseUnits` has to key by hash.
      //
      // The two amounts are **exactly equal**. wallet2 reports the outgoing
      // amount as `amount_in - change - fee`, which is precisely what arrived;
      // and that equality is what `decideTxNotifications` turns on when it
      // declines to call this a receipt.
      backend.transactions = [
        NativeTxInfo(
          direction: txDirectionOutgoing,
          hash: 'churn',
          amount: BigInt.from(1999670000000),
          fee: BigInt.from(330000000),
          timestamp: 2000,
          blockHeight: 3000000,
          confirmations: 10,
          subaddrAccount: 0,
          subaddrIndex: '0',
          isPending: false,
          isFailed: false,
          paymentId: '',
          txKey: 'k',
        ),
        NativeTxInfo(
          direction: txDirectionIncoming,
          hash: 'churn',
          amount: BigInt.from(1999670000000),
          fee: BigInt.zero,
          timestamp: 2000,
          blockHeight: 3000000,
          confirmations: 10,
          subaddrAccount: 0,
          subaddrIndex: '0',
          isPending: false,
          isFailed: false,
          paymentId: '',
          txKey: '',
        ),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      final history = wallet.readTxHistory();
      expect(history, hasLength(2), reason: 'both halves are reported, as wallet2 reports them');

      final sent = history.firstWhere((t) => t.direction == txDirectionOutgoing);
      final received = history.firstWhere((t) => t.direction == txDirectionIncoming);
      expect(sent.feeBaseUnits, BigInt.from(330000000));
      expect(received.feeBaseUnits, BigInt.zero, reason: 'charged once, on the spend');

      // What the churn actually cost: the fee, and only the fee.
      expect(
        sent.amountBaseUnits + sent.feeBaseUnits - received.amountBaseUnits,
        BigInt.from(330000000),
      );
    });

    test('a churn within one account is one entry whose only number is the fee', () async {
      // The shape wallet2 produces for the ordinary churn: the received output is
      // dropped from the received funds because it landed in the spending
      // account, and the outgoing amount is zeroed for being a pure self-send. So
      // nothing arrives, nothing is reported as sent, and the fee is the entire
      // record of what happened. Losing it here leaves a transaction that cost
      // nothing and did nothing.
      backend.transactions = [
        NativeTxInfo(
          direction: txDirectionOutgoing,
          hash: 'same-account-churn',
          amount: BigInt.zero,
          fee: BigInt.from(330000000),
          timestamp: 2000,
          blockHeight: 3000000,
          confirmations: 10,
          subaddrAccount: 0,
          subaddrIndex: '0',
          isPending: false,
          isFailed: false,
          paymentId: '',
          txKey: 'k',
        ),
      ];
      await openWallet();
      await wallet.refreshTxHistory();

      final tx = wallet.readTxHistory().single;
      expect(tx.direction, txDirectionOutgoing);
      expect(tx.amountBaseUnits, BigInt.zero);
      expect(tx.feeBaseUnits, BigInt.from(330000000));
    });

    /// A p2pool payout: a **coinbase** output, paid straight to the miner by the
    /// block that was found.
    ///
    /// Three things follow from it being coinbase, and all three are what this
    /// shape asserts. There is no fee; the miner is the party *collecting*
    /// fees, and a coinbase transaction has no inputs to pay one from. There is
    /// no transaction key, because this wallet did not sign it. And it lands on
    /// the **primary address**: a coinbase output has to pay a standard address,
    /// so p2pool cannot pay a subaddress and index 0 is the only answer.
    NativeTxInfo coinbasePayout({int confirmations = 12}) => NativeTxInfo(
      direction: txDirectionIncoming,
      hash: 'p2pool-payout',
      // 0.00652139827 XMR, a small-miner payout, exact to the piconero.
      amount: BigInt.from(6521398270),
      fee: BigInt.zero,
      timestamp: 1700000500,
      blockHeight: 3000000,
      confirmations: confirmations,
      subaddrAccount: 0,
      subaddrIndex: '0',
      isPending: false,
      isFailed: false,
      paymentId: '',
      txKey: '',
    );

    test('a p2pool coinbase payout is credited whole, with no fee', () async {
      backend.transactions = [coinbasePayout()];
      await openWallet();
      await wallet.refreshTxHistory();

      final tx = wallet.readTxHistory().single;
      expect(tx.direction, txDirectionIncoming);
      expect(tx.amountBaseUnits, BigInt.from(6521398270), reason: 'exact to the piconero');
      // Not "we could not find the fee"; a coinbase transaction has none to
      // find, and netting one off a mining payout would understate every reward.
      expect(tx.feeBaseUnits, BigInt.zero);
      expect(tx.key, isEmpty, reason: 'wallet2 has no key for a block it did not sign');
      // The primary address, which is the only thing a coinbase output can pay.
      // Reported as the recipient: an incoming transaction has no destination
      // recorded, so the receiving subaddress is what there is to show.
      expect(tx.recipients.single.address, backend.defaultAddress);
      expect(tx.recipients.single.amountBaseUnits, BigInt.from(6521398270));
      expect(tx.subaddrIndexList, [0]);
      expect(tx.accountIndex, 0);
    });

    test('a coinbase payout counts as confirmed long before it is spendable', () async {
      // The consensus rule this exists for: a coinbase output is locked for
      // CRYPTONOTE_MINED_MONEY_UNLOCK_WINDOW = **60** blocks, where an ordinary
      // output is spendable after CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE = 10.
      // `requiredConfirmations` is 10, so a mining payout reads as confirmed for
      // fifty blocks during which it cannot be spent.
      //
      // That is safe only because nothing infers spendability from it. The
      // unlocked balance is the authority, monero_c applies the 60-block window
      // when it computes that, and the two numbers are asserted here as the
      // separate things they are. Wire a send limit to `isTxConfirmed` and a
      // miner's wallet will offer to spend a payout the daemon will reject.
      backend.transactions = [coinbasePayout()];
      backend.balanceValue = BigInt.from(6521398270);
      backend.unlockedBalanceValue = BigInt.zero;
      await openWallet();
      // The balance getters read nothing until the daemon is initialised.
      await wallet.connectToDaemonImpl(address: 'l:18090');
      await wallet.refreshTxHistory();
      await wallet.loadTotalBalance();
      await wallet.loadUnlockedBalance();

      final tx = wallet.readTxHistory().single;
      expect(tx.confirmations, 12);
      expect(wallet.isTxConfirmed(tx), isTrue, reason: '12 >= the 10 this coin requires');

      expect(wallet.totalBalanceBaseUnits, BigInt.from(6521398270));
      expect(
        wallet.unlockedBalanceBaseUnits,
        BigInt.zero,
        reason: 'still inside the 60-block coinbase window',
      );
    });

    test('a coinbase payout is announced once, like any other receipt', () async {
      // A miner's wallet receives one of these per block the pool finds, so this
      // is the notification path's normal traffic rather than an edge case. It is
      // a real receipt: incoming, in a block, and worth telling the user about.
      backend.transactions = [coinbasePayout()];
      await openWallet();
      await wallet.refreshTxHistory();

      final first = decideTxNotifications(
        txHistory: wallet.readTxHistory(),
        cutoff: 1600000000,
        announcedHashes: const [],
      );
      expect(first.toAnnounce.map((t) => t.hash), ['p2pool-payout']);
      expect(first.cutoff, 1700000500, reason: 'it is in a block, so the cutoff advances');

      // The next refresh must not announce it again; the payout's timestamp
      // moved from "seen" to the block's when it was mined.
      final second = decideTxNotifications(
        txHistory: wallet.readTxHistory(),
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );
      expect(second.toAnnounce, isEmpty);
    });

    test('nothing is read before the wallet is open', () async {
      backend.transactions = [info(hash: 'a', timestamp: 1000)];

      await wallet.refreshTxHistory();

      expect(wallet.readTxHistory(), isEmpty);
    });
  });

  group('the node-mode catch-up load', () {
    /// Opens a node-mode wallet with the daemon initialised, which is what
    /// `pollSyncStatus` requires before it reads anything.
    Future<void> openNodeWallet() async {
      connect(type: 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'n:18081');
      backend.reset();
    }

    test('an unsynced node wallet reads nothing but its sync status', () async {
      await openNodeWallet();
      backend.synchronizedValue = false;

      await wallet.checkConnectionTask();

      // This is the contention `deferStatsUntilSynced` exists to avoid: the
      // history read and the balance reads each take the wallet lock, and the
      // native scan thread stalls behind them for as long as they hold it.
      expect(backend.called('historyRefresh'), isFalse);
      expect(wallet.isSynced, isFalse);
    });

    test('reaching synced triggers the catch-up load, exactly once', () async {
      await openNodeWallet();
      backend.synchronizedValue = false;
      await wallet.checkConnectionTask();
      expect(backend.called('historyRefresh'), isFalse);

      // The scan finishes. Nothing else would load the stats: the refresh task
      // has been skipping them the whole time, so without this the user stares
      // at a stale balance until something else happens to trigger a load.
      backend.synchronizedValue = true;
      await wallet.checkConnectionTask();
      expect(wallet.isSynced, isTrue);
      final afterCatchUp = backend.countOf('historyRefresh');
      expect(afterCatchUp, greaterThan(0));

      // Still synced on the next tick; the transition already happened, so
      // the expensive load must not repeat every three seconds.
      await wallet.checkConnectionTask();
      await wallet.checkConnectionTask();
      expect(backend.countOf('historyRefresh'), afterCatchUp);
    });

    test('LWS never defers and never catches up — the server does the scanning', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'l:18090');
      backend.reset();
      backend.synchronizedValue = false;

      await wallet.checkConnectionTask();
      backend.synchronizedValue = true;
      await wallet.checkConnectionTask();

      // `pollSyncStatus` returns immediately outside node mode, so there is no
      // transition to catch up from; the ordinary refresh task does the work.
      expect(backend.called('historyRefresh'), isFalse);
    });
  });

  group('load pre- and post-loads the subaddress state', () {
    test('persisted state first, the two server probes last', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      await SharedPreferencesService.set<int>('unusedSubaddressIndex', 7);
      backend.reset();

      await wallet.load();

      // The persisted index is read before the sync so the receive screen has
      // an address to show immediately; the probes run after, because the
      // unused index is derived from the transaction history and both need an
      // open connection. Getting that order wrong shows a blank address on
      // every cold start.
      expect(wallet.unusedSubaddressIndex, isNotNull);
      final connectAt = backend.calls.indexOf('connectToDaemon');
      final historyAt = backend.calls.indexOf('historyRefresh');
      expect(connectAt, isNonNegative);
      expect(historyAt, greaterThan(connectAt));
    });
  });

  group('dispose closes the native wallet', () {
    // These use their own instance: the shared `tearDown` disposes `wallet`,
    // and `ChangeNotifier.dispose` is a once-only contract that this class
    // deliberately keeps rather than making idempotent; a double dispose is a
    // bug in the app, and the assert is what finds it.
    Future<MoneroWallet> localWallet({bool open = true}) async {
      final w = MoneroWallet(backend: backend);
      w.setConnection(
        address: 'lws.example.com:18090',
        proxyPort: '',
        useTor: false,
        connectionType: 'lws',
      );
      if (open) {
        backend.existingWalletPaths.add(await w.walletPathForType('lws'));
        await w.openExisting(password: 'pw');
      }
      backend.reset();
      return w;
    }

    test('an open wallet is closed, without storing', () async {
      final w = await localWallet();

      w.dispose();

      // Skylight never closes it, so the decrypted keys and the background
      // scan thread outlive the object. `store: false` because dispose is not
      // a checkpoint; `pauseSyncAndStore` is, and writing here would race it.
      expect(backend.called('closeWallet'), isTrue);
      expect(backend.called('store'), isFalse);
    });

    test('a wallet that was never opened closes nothing', () async {
      final w = await localWallet(open: false);

      w.dispose();

      expect(backend.called('closeWallet'), isFalse);
    });
  });

  group('connect is skipped on a mode mismatch', () {
    test('does not call init when the open wallet is the wrong kind', () async {
      // Calling Wallet_init with a mismatched lightWallet flag aborts.
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');

      connect(type: 'node'); // switches desired kind; wallet still LWS-built
      await wallet.connectToDaemonImpl(address: 'n:18081');

      expect(backend.called('init'), isFalse);
    });
  });

  group('balances are BigInt end to end', () {
    test('a balance above 2^53 piconero survives', () async {
      connect();
      backend.existingWalletPaths.add(await pathFor('lws'));
      await wallet.openExisting(password: 'pw');
      await wallet.connectToDaemonImpl(address: 'l:18090');

      final big = BigInt.parse('9007199254740993');
      backend.unlockedBalanceValue = big;
      await wallet.loadUnlockedBalance();

      expect(wallet.unlockedBalanceBaseUnits, big);
      expect(wallet.unlockedBalanceString, '9007.199254740993');
    });
  });

  test('deleteFiles removes both modes plus companions', () async {
    connect();
    final lws = await pathFor('lws');
    final node = await pathFor('node');
    for (final p in [lws, '$lws.keys', node, '$node.keys', '$node.address.txt']) {
      await File(p).writeAsString('x');
    }

    await wallet.deleteFiles();

    for (final p in [lws, '$lws.keys', node, '$node.keys', '$node.address.txt']) {
      expect(File(p).existsSync(), isFalse, reason: p);
    }
  });

  test(
    'delete keeps the connection so setup recalls the mode, not a node address under LWS',
    () async {
      wallet.setConnection(
        address: 'node.example.com:18081',
        proxyPort: '',
        useTor: false,
        connectionType: 'node',
      );
      await wallet.persistCurrentConnection();

      await wallet.delete();

      final conn = await wallet.getPersistedConnection();
      expect(conn.connectionType, 'node', reason: 'the previous mode is recalled after delete');
      expect(
        conn.address,
        'node.example.com:18081',
        reason: 'address stays consistent with the recalled mode',
      );
    },
  );

  test('delete forgets the wallet address it had cached', () async {
    backend.defaultAddress = '4${'c' * 94}';
    connect();
    backend.existingWalletPaths.add(await pathFor('lws'));
    await wallet.openExisting(password: 'pw');
    await wallet.loadPrimaryAddress();
    expect(wallet.getPrimaryAddress(), backend.defaultAddress);

    await wallet.delete();

    // Both getters are synchronous and have no liveness check, so a cached
    // address outlives the keys it came from: the receive screen would show a
    // deleted wallet's address, which the user can no longer spend from.
    expect(wallet.getPrimaryAddress(), isEmpty);
    expect(wallet.getReceiveAddress(), isNull);
  });
}
