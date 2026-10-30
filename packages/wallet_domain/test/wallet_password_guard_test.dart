import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

const _bip39 =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';

class _Guard extends WalletPasswordGuard {
  bool engaged = false;
  String? created;
  int deleted = 0;

  @override
  Future<String> passwordForNewWallet(SeedSource seed) async => 'from-guard';

  @override
  Future<void> keepForNewWallet(String password) async => created = password;

  @override
  Future<bool> isEngaged() async => engaged;

  @override
  Future<void> walletDeleted() async => deleted++;
}

/// A guard on Linux or Windows. Everything it and [_FlakyWallet] do goes into
/// one [log], so their order can be checked.
class _TypedGuard extends _Guard {
  _TypedGuard(this.log);

  final List<String> log;

  /// Whether the typed password opens the guard while it is engaged.
  bool accepts = true;

  @override
  Future<String> passwordForNewWallet(SeedSource seed) async {
    log.add('derive');
    return 'from-guard';
  }

  @override
  Future<bool> acceptsTypedPassword(String typed) async => accepts;
}

/// Fails its first restore when asked to, and logs the password of each and
/// whether `wallet.key` was already written.
class _FlakyWallet extends FakeWallet {
  _FlakyWallet(this.log, {this.failFirst = false}) : super('XMR', seedFormats: {SeedFormat.bip39});

  final List<String> log;
  bool failFirst;

  @override
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {
    final kept = (await TypedPasswordStore.wrapFile()).existsSync();
    log.add('restore $password${kept ? ' after wallet.key' : ''}');
    if (failFirst) {
      failFirst = false;
      throw StateError('connection lost');
    }
    await super.restoreFromSeed(seed: seed, from: from, password: password);
  }
}

class _ViewOnlyWallet extends FakeWallet {
  _ViewOnlyWallet(super.symbol) : super(existing: true);

  int viewOnlyOpens = 0;
  int prepared = 0;
  int forgotten = 0;
  int closedFiles = 0;

  @override
  Future<bool> openViewOnly() async {
    viewOnlyOpens++;
    setIsLoaded(true);
    return true;
  }

  @override
  Future<void> prepareViewOnly() async => prepared++;

  @override
  Future<void> forgetViewOnly() async => forgotten++;

  @override
  Future<void> closeFiles() async => closedFiles++;
}

/// Holds its close until [release] completes, to look inside a full lock.
class _SlowCloseWallet extends _ViewOnlyWallet {
  _SlowCloseWallet(super.symbol);

  final release = Completer<void>();

  @override
  Future<void> closeFiles() async {
    closedFiles++;
    await release.future;
  }
}

void main() {
  late Directory tmp;
  late MemorySecretStore secrets;
  late _Guard guard;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('password_guard');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    SharedPreferencesService.store = MemoryPreferenceStore();
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    // The default follows the test host; these are the mobile paths.
    WalletSecrets.holdsWalletPassword = true;
    guard = _Guard();
    WalletManager.passwordGuard = guard;
  });

  tearDown(() {
    WalletManager.passwordGuard = null;
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> restore(WalletManager m) =>
      m.restoreAll(seed: const Bip39Seed(_bip39), from: RestorePoint.date(DateTime.utc(2026)));

  test('a new wallet takes its password from the guard', () async {
    final w = FakeWallet('XMR', seedFormats: {SeedFormat.bip39});
    final m = WalletManager(coins: () => [w])..useGeneratedPassword();
    await restore(m);
    expect(m.passwordForGuard, 'from-guard');
    expect(guard.created, 'from-guard');
    // Until keys are set up, the keystore holds it as it always did.
    expect(await readKeystoreWalletPassword(), 'from-guard');
    m.dispose();
  });

  test('a typed password is never replaced', () async {
    final m = WalletManager(coins: () => [FakeWallet('XMR')])..setWalletPassword('typed');
    await restore(m);
    expect(m.passwordForGuard, 'typed');
    expect(guard.created, isNull);
    m.dispose();
  });

  test('once engaged, a keystore copy is not read back', () async {
    await storeKeystoreWalletPassword('left over');
    guard.engaged = true;
    final m = WalletManager(coins: () => [FakeWallet('XMR')]);
    expect(await m.loadStoredPassword(), isFalse);
    expect(m.hasPassword, isFalse);
    expect(await m.isPasswordGuarded(), isTrue);
    m.dispose();
  });

  test('App Lock keeps a guarded password in memory, and drops a stored one', () async {
    WalletSecrets.holdsWalletPassword = true;
    final m = WalletManager(coins: () => [FakeWallet('XMR', existing: true)])
      ..setWalletPassword('pw');

    guard.engaged = true;
    expect(await m.armAppLockRelock(), isTrue);
    expect(m.hasPassword, isTrue, reason: 'nothing to read it back from');

    guard.engaged = false;
    expect(await m.armAppLockRelock(), isTrue);
    expect(m.hasPassword, isFalse);
    m.dispose();
  });

  test('App Lock\'s recovery phrase never reads a guarded wallet\'s leftover copy', () async {
    WalletSecrets.holdsWalletPassword = true;
    await storeKeystoreWalletPassword('left over');
    guard.engaged = true;
    final m = WalletManager(coins: () => [FakeWallet('XMR', existing: true)]);
    expect(
      await m.unlockWithRecoveryPhrase(
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon abandon address',
      ),
      isFalse,
    );
    expect(m.hasPassword, isFalse, reason: 'the keys\' own recovery opens it');
    m.dispose();
  });

  test('unlocking with the guard sets the password and clears a keystore leftover', () async {
    await storeKeystoreWalletPassword('pw');
    guard.engaged = true;
    final m = WalletManager(coins: () => [FakeWallet('XMR')]);
    await m.unlockWithGuardedPassword('pw');
    expect(m.passwordForGuard, 'pw');
    expect(await readKeystoreWalletPassword(), isNull);
    m.dispose();
  });

  test('a full lock closes every wallet and forgets the password', () async {
    final w = _ViewOnlyWallet('XMR');
    final m = WalletManager(coins: () => [w])..setWalletPassword('pw');
    await m.openAll();
    expect(w.isLoaded, isTrue);

    await m.fullyLock();
    expect(w.isLoaded, isFalse);
    expect(w.closedFiles, 1);
    expect(m.hasPassword, isFalse);
    m.dispose();
  });

  test('a full lock forgets the password before it closes anything', () async {
    final w = _SlowCloseWallet('XMR');
    final m = WalletManager(coins: () => [w])..setWalletPassword('pw');
    await m.openAll();

    final lock = m.fullyLock();
    // Closing stores each wallet and takes a while; the password must already
    // be gone, so nothing still on screen can use it meanwhile.
    expect(m.hasPassword, isFalse);
    expect(m.passwordForGuard, isNull);

    w.release.complete();
    await lock;
    expect(w.isLoaded, isFalse);
    m.dispose();
  });

  test('two closes at once share one, so a wallet is never closed twice', () async {
    final w = _SlowCloseWallet('XMR');
    final m = WalletManager(coins: () => [w])..setWalletPassword('pw');
    await m.openAll();

    final first = w.close();
    final second = w.close();
    expect(identical(first, second), isTrue);

    w.release.complete();
    await Future.wait([first, second]);
    expect(w.closedFiles, 1);

    // Once finished, a later close is a new one.
    await w.close();
    expect(w.closedFiles, 2);
    m.dispose();
  });

  test('an unattended run with no password opens view-only; a foreground one does not', () async {
    guard.engaged = true;
    final unattended = _ViewOnlyWallet('XMR')..markUnattended();
    final background = WalletManager(coins: () => [unattended]);
    await background.openAll();
    expect(unattended.viewOnlyOpens, 1);
    expect(unattended.openCount, 0);
    background.dispose();

    final foreground = _ViewOnlyWallet('XMR');
    final m = WalletManager(coins: () => [foreground]);
    await m.openAll();
    expect(foreground.viewOnlyOpens, 0);
    expect(foreground.isLoaded, isFalse);
    m.dispose();
  });

  test('view-only state is prepared and forgotten through the manager', () async {
    final w = _ViewOnlyWallet('XMR');
    final m = WalletManager(coins: () => [w])..setWalletPassword('pw');
    await m.openAll();
    // The open itself keeps it in step (nothing runs unattended here: forgotten).
    expect((w.prepared, w.forgotten), (0, 1));
    await m.prepareViewOnlyAll();
    await m.forgetViewOnlyAll();
    expect((w.prepared, w.forgotten), (1, 2));
    m.dispose();
  });

  // A Periodic run and Continuous Sync are view-only whatever the
  // configuration: never the password, the seed or a spend key.
  group('unattended runs', () {
    test('never load the kept password, keys off and a copy in the keystore', () async {
      await storeKeystoreWalletPassword('kept');
      guard.engaged = false;
      final w = _ViewOnlyWallet('XMR')..markUnattended();
      final m = WalletManager(coins: () => [w]);

      await m.openAll();
      expect(w.viewOnlyOpens, 1);
      expect(m.hasPassword, isFalse);
      expect(await m.loadStoredPassword(), isFalse);

      // Not even when handed one.
      m.setWalletPassword('kept');
      expect(m.hasPassword, isFalse);
      expect(await m.loadStoredSeed(), isNull);
      m.dispose();
    });

    test('a coin without view-only material is skipped, not opened with keys', () async {
      await storeKeystoreWalletPassword('kept');
      final w = FakeWallet('BTC', existing: true)..markUnattended();
      final m = WalletManager(coins: () => [w]);
      await m.openAll();
      expect(w.isLoaded, isFalse);
      expect(m.hasPassword, isFalse);
      m.dispose();
    });
  });

  group('view-only material follows what runs without the user', () {
    // An Android phone with Sync Frequency off unless a test says otherwise.
    setUp(() async {
      syncFrequencyPlatform = 'android';
      await saveSyncFrequency(SyncFrequency.off);
    });
    tearDown(() => syncFrequencyPlatform = Platform.operatingSystem);

    Future<_ViewOnlyWallet> openWith({SyncFrequency? frequency, bool keys = false}) async {
      if (frequency != null) await saveSyncFrequency(frequency);
      guard.engaged = keys;
      final w = _ViewOnlyWallet('XMR');
      final m = WalletManager(coins: () => [w])..setWalletPassword('pw');
      addTearDown(m.dispose);
      await m.openAll();
      return w;
    }

    test('nothing runs: forgotten', () async {
      final w = await openWith();
      expect((w.prepared, w.forgotten), (0, 1));
    });

    for (final frequency in [SyncFrequency.periodic, SyncFrequency.continuous]) {
      test('${frequency.name}: kept, with security keys off', () async {
        final w = await openWith(frequency: frequency);
        expect((w.prepared, w.forgotten), (1, 0));
      });
    }

    test('notifications alone keep nothing: they run nothing', () async {
      await SharedPreferencesService.set<bool>(SettingsKeys.notificationsEnabled, true);
      final w = await openWith();
      expect((w.prepared, w.forgotten), (0, 1));
    });

    test('security keys on: kept even with Sync Frequency off', () async {
      final w = await openWith(keys: true);
      expect((w.prepared, w.forgotten), (1, 0));
    });

    test('Sync Frequency switched on later takes effect at once', () async {
      final w = _ViewOnlyWallet('XMR');
      final m = WalletManager(coins: () => [w])..setWalletPassword('pw');
      addTearDown(m.dispose);
      await m.openAll();
      await saveSyncFrequency(SyncFrequency.periodic);
      await m.applySyncSettings();
      expect(w.prepared, 1);
    });
  });

  test('a failed restore derives again on the retry, keystore copy first', () async {
    final log = <String>[];
    final m = WalletManager(coins: () => [_FlakyWallet(log, failFirst: true)])
      ..useGeneratedPassword();
    await expectLater(restore(m), throwsStateError);
    expect(await readKeystoreWalletPassword(), 'from-guard', reason: 'stored before any file');
    expect(guard.created, 'from-guard', reason: "the guard's record, before any file too");
    guard.created = null;
    await restore(m);
    expect(m.passwordForGuard, 'from-guard');
    expect(guard.created, 'from-guard');
    expect(log, ['restore from-guard', 'restore from-guard']);
    m.dispose();
  });

  group('typed passwords (Linux, Windows)', () {
    late List<String> log;
    late _TypedGuard typedGuard;

    setUp(() {
      WalletSecrets.holdsWalletPassword = false;
      log = [];
      typedGuard = _TypedGuard(log);
      WalletManager.passwordGuard = typedGuard;
    });

    tearDown(() {
      TypedPasswordStore.instance.resetForTesting();
      WalletFileCrypto.walletPasswordIterations = WalletFileCrypto.typedPasswordIterations;
    });

    Future<String> keptCopy(String typed) async => WalletFileCrypto.decryptFromBase64(
      await (await TypedPasswordStore.wrapFile()).readAsString(),
      typed,
    );

    test("the guard's password opens the new wallet, kept under the typed one first", () async {
      final m = WalletManager(coins: () => [_FlakyWallet(log)])..setWalletPassword('typed');
      await restore(m);
      expect(log, ['derive', 'restore from-guard after wallet.key']);
      expect(await keptCopy('typed'), 'from-guard');
      expect(typedGuard.created, 'from-guard');
      expect(m.passwordForGuard, 'from-guard');
      expect(
        secrets.values.containsKey(walletPasswordStorageKey),
        isFalse,
        reason: 'no keystore copy on Linux or Windows',
      );
      expect(
        WalletFileCrypto.walletPasswordIterations,
        WalletFileCrypto.generatedPasswordIterations,
        reason: 'files under a seed-derived password need no typed-password cost',
      );
      m.dispose();
    });

    test('a failed restore is retried from the typed password', () async {
      final m = WalletManager(coins: () => [_FlakyWallet(log, failFirst: true)])
        ..setWalletPassword('typed');
      await expectLater(restore(m), throwsStateError);
      expect(m.passwordForGuard, 'typed', reason: 'still the typed password');
      await restore(m);
      expect(log, [
        'derive',
        'restore from-guard after wallet.key',
        'derive',
        'restore from-guard after wallet.key',
      ]);
      expect(await keptCopy('typed'), 'from-guard');
      expect(m.passwordForGuard, 'from-guard');
      m.dispose();
    });

    test(
      'without a guard, the typed password is the wallet password and nothing is kept',
      () async {
        WalletManager.passwordGuard = null;
        final m = WalletManager(coins: () => [_FlakyWallet(log)])..setWalletPassword('typed');
        await restore(m);
        expect(log, ['restore typed']);
        expect((await TypedPasswordStore.wrapFile()).existsSync(), isFalse);
        expect(WalletFileCrypto.walletPasswordIterations, WalletFileCrypto.typedPasswordIterations);
        m.dispose();
      },
    );

    test('the typed unlock: a wrong password, the kept copy, and keys on', () async {
      await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
      TypedPasswordStore.instance.endSession();
      final m = WalletManager(coins: () => [FakeWallet('XMR')]);

      expect(await m.unlockWithTypedPassword('wrong'), isFalse);
      expect(m.hasPassword, isFalse);

      expect(await m.unlockWithTypedPassword('typed'), isTrue);
      expect(m.passwordForGuard, 'from-guard');
      expect(TypedPasswordStore.instance.typedPassword, 'typed');

      await m.fullyLock();
      expect(TypedPasswordStore.instance.typedPassword, isNull);
      typedGuard.engaged = true;
      typedGuard.accepts = false;
      expect(await m.unlockWithTypedPassword('typed'), isFalse);
      typedGuard.accepts = true;
      expect(await m.unlockWithTypedPassword('typed'), isTrue);
      expect(m.hasPassword, isFalse, reason: 'a key comes next');
      expect(TypedPasswordStore.instance.typedPassword, 'typed');
      m.dispose();
    });

    test("an older wallet's typed password is its wallet password, at the typed cost", () async {
      await SeedStore.save(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
        password: 'old typed',
      );
      final m = WalletManager(coins: () => [FakeWallet('XMR')]);
      expect(await m.unlockWithTypedPassword('wrong'), isFalse);
      expect(await m.unlockWithTypedPassword('old typed'), isTrue);
      expect(m.passwordForGuard, 'old typed');
      expect(WalletFileCrypto.walletPasswordIterations, WalletFileCrypto.typedPasswordIterations);
      m.dispose();
    });

    test("a guard's password cannot start another wallet without the typed one", () async {
      await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
      final m = WalletManager(
        coins: () => [
          FakeWallet('XMR', seedFormats: {SeedFormat.bip39}),
        ],
      );
      await m.unlockWithTypedPassword('typed');
      await expectLater(restore(m), throwsStateError);
      expect(log, isEmpty);
      m.dispose();
    });

    test('a key unlock finishes an engage that was cut short before wallet.key went', () async {
      await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
      final wrap = await TypedPasswordStore.wrapFile();
      final leftover = File('${wrap.path}.4242-0.tmp')..writeAsStringSync(wrap.readAsStringSync());
      final m = WalletManager(coins: () => [FakeWallet('XMR')]);
      await m.unlockWithGuardedPassword('from-guard');
      expect(wrap.existsSync(), isFalse);
      expect(leftover.existsSync(), isFalse, reason: 'the typed password opens it too');
      m.dispose();
    });

    test('removing the copy takes the older copies a cut-short write left', () async {
      await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
      final wrap = await TypedPasswordStore.wrapFile();
      final old = [
        for (final n in ['1-0', '99-3']) File('${wrap.path}.$n.tmp')..writeAsStringSync('old'),
      ];
      final unrelated = File('${wrap.parent.path}/master_seed.1-0.tmp')..writeAsStringSync('x');

      await TypedPasswordStore.instance.deleteCopy();
      expect(wrap.existsSync(), isFalse);
      expect(old.where((f) => f.existsSync()), isEmpty);
      expect(unrelated.existsSync(), isTrue);
    });

    test('checkTypedPassword proves the password without unlocking anything', () async {
      await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
      TypedPasswordStore.instance.endSession();
      final m = WalletManager(coins: () => [FakeWallet('XMR')]);
      expect(await m.checkTypedPassword('wrong'), isFalse);
      expect(await m.checkTypedPassword('typed'), isTrue);
      expect(m.hasPassword, isFalse);
      expect(TypedPasswordStore.instance.typedPassword, isNull);
      m.dispose();
    });

    test('with keys on, checkTypedPassword asks the guard', () async {
      typedGuard.engaged = true;
      final m = WalletManager(coins: () => [FakeWallet('XMR')]);
      typedGuard.accepts = false;
      expect(await m.checkTypedPassword('typed'), isFalse);
      typedGuard.accepts = true;
      expect(await m.checkTypedPassword('typed'), isTrue);
      expect(TypedPasswordStore.instance.typedPassword, isNull);
      m.dispose();
    });

    test(
      "an older wallet's password is checked against its seed; no seed proves nothing",
      () async {
        final m = WalletManager(coins: () => [FakeWallet('XMR')]);
        expect(await m.checkTypedPassword('anything'), isFalse);
        await SeedStore.save(
          seed: const Bip39Seed(_bip39),
          from: RestorePoint.date(DateTime.utc(2026)),
          password: 'old typed',
        );
        expect(await m.checkTypedPassword('wrong'), isFalse);
        expect(await m.checkTypedPassword('old typed'), isTrue);
        m.dispose();
      },
    );

    group('bound to this PC (a Windows TPM)', () {
      late FakeMachineKeys tpm;

      setUp(() => PcBinding.keys = tpm = FakeMachineKeys());
      tearDown(() => PcBinding.keys = const NoMachineKeys());

      Future<bool> opensWithTypedAlone() async {
        try {
          await keptCopy('typed');
          return true;
        } on FormatException {
          return false;
        }
      }

      test('wallet.key is bound: it opens here, and not with the typed password alone', () async {
        await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
        TypedPasswordStore.instance.endSession();
        expect(await opensWithTypedAlone(), isFalse, reason: 'a copy elsewhere cannot be guessed');

        final m = WalletManager(coins: () => [FakeWallet('XMR')]);
        expect(
          await m.unlockWithTypedPassword('wrong'),
          isFalse,
          reason: 'a wrong password is just that',
        );
        expect(await m.unlockWithTypedPassword('typed'), isTrue);
        expect(m.passwordForGuard, 'from-guard');
        expect(await m.checkTypedPassword('typed'), isTrue);
        expect(await m.checkTypedPassword('wrong'), isFalse);
        m.dispose();
      });

      test('a copy written unbound is bound at its next unlock', () async {
        PcBinding.keys = const NoMachineKeys();
        await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
        TypedPasswordStore.instance.endSession();
        expect(await opensWithTypedAlone(), isTrue);

        PcBinding.keys = tpm;
        final m = WalletManager(coins: () => [FakeWallet('XMR')]);
        expect(await m.unlockWithTypedPassword('typed'), isTrue);
        expect(m.passwordForGuard, 'from-guard');
        expect(await opensWithTypedAlone(), isFalse, reason: 'rewritten bound');

        await m.fullyLock();
        expect(await m.unlockWithTypedPassword('typed'), isTrue);
        expect(m.passwordForGuard, 'from-guard');
        m.dispose();
      });

      test('on another PC the right password is not taken for a wrong one', () async {
        await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
        TypedPasswordStore.instance.endSession();
        tpm.forgetAll();

        final m = WalletManager(coins: () => [FakeWallet('XMR')]);
        await expectLater(
          m.unlockWithTypedPassword('typed'),
          throwsA(isA<BoundToAnotherPcException>()),
        );
        expect(m.hasPassword, isFalse);
        await expectLater(m.checkTypedPassword('typed'), throwsA(isA<BoundToAnotherPcException>()));
        m.dispose();
      });

      test('deleting the wallet deletes the binding', () async {
        await TypedPasswordStore.instance.saveCopy('from-guard', typed: 'typed');
        final record = File('${(await getAppDir()).path}/${PcBinding.fileName}');
        expect(record.existsSync(), isTrue);
        final m = WalletManager(coins: () => [FakeWallet('XMR')]);
        await m.deleteAll();
        expect(record.existsSync(), isFalse);
        m.dispose();
      });
    });
  });

  test('deleting the wallet tells the guard', () async {
    final m = WalletManager(coins: () => [FakeWallet('XMR')]);
    await m.deleteAll();
    expect(guard.deleted, 1);
    m.dispose();
  });
}
