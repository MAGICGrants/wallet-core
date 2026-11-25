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

/// A guard whose record for a wallet is just the password it was kept under.
class _Guard extends WalletPasswordGuard {
  String? kept;
  int forgotten = 0;

  @override
  Future<String> passwordForNewWallet(SeedSource seed) async => 'from-guard';

  @override
  Future<void> keepForNewWallet(String password) async => kept = password;

  @override
  Future<bool> isEngaged() async => false;

  @override
  Future<void> walletDeleted() async => kept = null;

  @override
  Future<bool> keptUnder(String password) async => kept == password;

  @override
  Future<void> forgetKept() async {
    kept = null;
    forgotten++;
  }
}

/// Keeps one file of its own under the wallet password, as Bitcoin and
/// Ethereum do, and can fail while moving it.
class _FileWallet extends FakeWallet {
  _FileWallet() : super('XMR', existing: true);

  bool failMove = false;

  /// Holds the move, when set, until it completes; [moving] says it began.
  Completer<void>? hold;
  final moving = Completer<void>();

  /// Holds the open, when set, until it completes (a Monero open takes
  /// seconds); [opening] says it began.
  Completer<void>? openGate;
  final opening = Completer<void>();
  String? openedWith;

  Future<File> file() async => File('${(await getAppDir()).path}/xmr_keys');

  /// What a save in this session writes: the wallet's own state, under the
  /// password it was opened with.
  Future<void> save(String content) async => writeStringAtomic(
    await file(),
    await WalletFileCrypto.encryptToBase64(content, openedWith!),
  );

  @override
  Future<void> openExisting({required String password}) async {
    if (!opening.isCompleted) opening.complete();
    await openGate?.future;
    openedWith = password;
    // Opens only under the password its file is under, as a real coin does.
    await WalletFileCrypto.decryptFromBase64(await (await file()).readAsString(), password);
    await super.openExisting(password: password);
  }

  @override
  Future<List<String>> walletPasswordFilePaths() async => [
    ...await super.walletPasswordFilePaths(),
    (await file()).path,
  ];

  @override
  Future<void> changeWalletPassword({required String from, required String to}) async {
    if (!moving.isCompleted) moving.complete();
    await hold?.future;
    await super.changeWalletPassword(from: from, to: to);
    if (!await rekeyWalletFile(await file(), from: from, to: to)) throw StateError('neither');
    if (failMove) throw StateError('disk full');
  }
}

/// Counts what the manager asks of the metadata backup.
class _Backup implements MetadataBackup {
  int opens = 0;

  @override
  Future<void> open(
    SeedSource seed, {
    required List<CryptoWallet> wallets,
    bool restored = false,
  }) async => opens++;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The security-key upgrade: a wallet made before the guard moves onto it at
/// its first unlock, and one cut short is kept or put back.
const _labels = [AddressLabel(coin: 'XMR', address: '8a', label: 'Donations')];

void main() {
  late Directory tmp;
  late _Guard guard;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('guard_upgrade');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletSecrets.holdsWalletPassword = true;
    guard = _Guard();
    WalletManager.passwordGuard = guard;
    AddressLabelKey.resetForTesting();
  });

  tearDown(() {
    AddressLabelKey.resetForTesting();
    WalletManager.passwordGuard = null;
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A wallet as an earlier build left it: a random password in the keystore,
  /// and its files under it.
  Future<void> olderWallet(_FileWallet w, {bool storedSeed = true}) async {
    await storeKeystoreWalletPassword('old');
    await writeStringAtomic(await w.file(), await WalletFileCrypto.encryptToBase64('keys', 'old'));
    if (storedSeed) {
      await SeedStore.save(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
        password: 'old',
      );
    }
    await writeAddressLabels(_labels, password: 'old');
  }

  Future<String?> labelUnder(String password) async =>
      (await readAddressLabels(password: password))?.single.label;

  Future<String> fileUnder(_FileWallet w, String password) async =>
      WalletFileCrypto.decryptFromBase64(await (await w.file()).readAsString(), password);

  Iterable<String> leftovers() => tmp
      .listSync()
      .map((e) => e.path)
      .where((p) => p.endsWith('.upgrade-bak') || p.endsWith('.upgrade-new'));

  test('an older wallet moves onto the guard at its first unlock', () async {
    final w = _FileWallet();
    await olderWallet(w);
    final m = WalletManager(coins: () => [w]);
    await m.openAll();

    expect(await readKeystoreWalletPassword(), 'from-guard');
    expect(m.passwordForGuard, 'from-guard');
    expect(guard.kept, 'from-guard');
    expect(await SeedStore.load('from-guard'), isNotNull);
    expect(await fileUnder(w, 'from-guard'), 'keys');
    expect(await labelUnder('from-guard'), 'Donations');
    expect(await labelUnder('old'), isNull, reason: 'the labels moved with the other files');
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty, reason: 'no copy under the old password may outlast it');
    m.dispose();
  });

  test('a failure before the commit puts everything back', () async {
    final w = _FileWallet()..failMove = true;
    await olderWallet(w);
    final m = WalletManager(coins: () => [w]);
    await m.openAll();

    expect(await readKeystoreWalletPassword(), 'old');
    expect(m.passwordForGuard, 'old');
    expect(guard.kept, isNull);
    expect(await SeedStore.load('old'), isNotNull);
    expect(await fileUnder(w, 'old'), 'keys');
    expect(await labelUnder('old'), 'Donations');
    expect(w.isLoaded, isTrue, reason: 'opened again under the old password');
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty);
    m.dispose();
  });

  test('one cut short before its commit is put back, then done again', () async {
    final w = _FileWallet();
    await olderWallet(w);
    // The app died after re-encrypting and keeping the guard's record, with
    // the keystore still holding the old password.
    await GuardUpgradeFiles.backUp([await SeedStore.path(), ...await w.walletPasswordFilePaths()]);
    await rekeyWalletFile(await w.file(), from: 'old', to: 'from-guard');
    guard.kept = 'from-guard';

    final m = WalletManager(coins: () => [w]);
    await m.openAll();

    expect(guard.forgotten, 1);
    expect(await readKeystoreWalletPassword(), 'from-guard');
    expect(await fileUnder(w, 'from-guard'), 'keys');
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty);
    m.dispose();
  });

  test('one cut short after its commit is kept', () async {
    final w = _FileWallet();
    await olderWallet(w);
    await GuardUpgradeFiles.backUp([await SeedStore.path(), ...await w.walletPasswordFilePaths()]);
    await rekeyWalletFile(await w.file(), from: 'old', to: 'from-guard');
    guard.kept = 'from-guard';
    await storeKeystoreWalletPassword('from-guard');

    final m = WalletManager(coins: () => [w]);
    await m.openAll();

    expect(guard.forgotten, 0);
    expect(await fileUnder(w, 'from-guard'), 'keys');
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty);
    m.dispose();
  });

  test('a lock during the upgrade waits for it, then forgets the password', () async {
    final w = _FileWallet()..hold = Completer<void>();
    await olderWallet(w);
    final m = WalletManager(coins: () => [w]);
    final open = m.openAll();
    await w.moving.future;

    final lock = m.fullyLock();
    w.hold!.complete();
    await open;
    await lock;

    // A lock that did not wait would be undone: the upgrade sets the new
    // password once it is through.
    expect(m.hasPassword, isFalse);
    expect(w.isLoaded, isFalse);
    expect(await readKeystoreWalletPassword(), 'from-guard');
    expect(await fileUnder(w, 'from-guard'), 'keys');
    expect(leftovers(), isEmpty);
    m.dispose();
  });

  group('a lock while the wallets open, before the upgrade begins', () {
    /// Opens [w] with the open held, runs [lock] once it is under way, then
    /// lets the open finish.
    Future<void> lockWhileOpening(
      WalletManager m,
      _FileWallet w,
      Future<void> Function() lock,
    ) async {
      w.openGate = Completer<void>();
      final open = m.openAll();
      await w.opening.future;
      await lock();
      w.openGate!.complete();
      await open;
    }

    test('cancels it, and the next launch keeps what the session wrote', () async {
      final w = _FileWallet();
      await olderWallet(w);
      final m = WalletManager(coins: () => [w]);
      // What App Lock does with security keys off.
      await lockWhileOpening(m, w, m.lockSpend);

      expect(await GuardUpgradeFiles.inProgress(), isFalse);
      expect(leftovers(), isEmpty);
      expect(guard.kept, isNull);
      expect(await readKeystoreWalletPassword(), 'old');

      // The user comes back and sends: the wallet saves under the password
      // it opened with.
      expect(await m.loadStoredPassword(), isTrue);
      if (m.isSpendLocked) await m.unlockSpend();
      await w.save('keys-after-a-send');
      m.dispose();

      // The next launch upgrades, from the files as the session left them.
      final next = _FileWallet();
      final m2 = WalletManager(coins: () => [next]);
      await m2.openAll();
      expect(await readKeystoreWalletPassword(), 'from-guard');
      expect(await fileUnder(next, 'from-guard'), 'keys-after-a-send');
      expect(await labelUnder('from-guard'), 'Donations');
      expect(await GuardUpgradeFiles.inProgress(), isFalse);
      expect(leftovers(), isEmpty);
      m2.dispose();
    });

    test('a full lock cancels it too', () async {
      final w = _FileWallet();
      await olderWallet(w);
      final m = WalletManager(coins: () => [w]);
      await lockWhileOpening(m, w, m.fullyLock);

      expect(m.hasPassword, isFalse);
      expect(await GuardUpgradeFiles.inProgress(), isFalse);
      expect(leftovers(), isEmpty);
      expect(guard.kept, isNull);
      expect(await readKeystoreWalletPassword(), 'old');
      expect(await fileUnder(w, 'old'), 'keys');
      expect(await labelUnder('old'), 'Donations');
      m.dispose();
    });

    test('an unlock again before the open ends does not undo the cancel', () async {
      final w = _FileWallet();
      await olderWallet(w);
      final m = WalletManager(coins: () => [w]);
      await lockWhileOpening(m, w, () async {
        await m.lockSpend();
        expect(await m.loadStoredPassword(), isTrue);
      });

      expect(m.hasPassword, isTrue);
      expect(w.isLoaded, isTrue);
      expect(await GuardUpgradeFiles.inProgress(), isFalse);
      expect(leftovers(), isEmpty);
      expect(guard.kept, isNull);
      expect(await readKeystoreWalletPassword(), 'old');
      m.dispose();
    });

    test('the backup opens again only once the password is back', () async {
      final backup = _Backup();
      MetadataBackup.instance = backup;
      addTearDown(() => MetadataBackup.instance = null);

      final w = _FileWallet();
      await olderWallet(w);
      final m = WalletManager(coins: () => [w]);
      await lockWhileOpening(m, w, m.lockSpend);
      expect(backup.opens, 0, reason: 'still locked');
      m.dispose();

      final again = _FileWallet();
      final m2 = WalletManager(coins: () => [again]);
      await lockWhileOpening(m2, again, () async {
        await m2.lockSpend();
        expect(await m2.loadStoredPassword(), isTrue);
      });
      expect(backup.opens, 1, reason: 'unlocked again before the open ended');
      m2.dispose();
    });
  });

  test('a wallet with no seed to read back keeps its password', () async {
    final w = _FileWallet();
    await olderWallet(w, storedSeed: false);
    final m = WalletManager(coins: () => [w]);
    await m.openAll();

    expect(await readKeystoreWalletPassword(), 'old');
    expect(await fileUnder(w, 'old'), 'keys');
    expect(guard.kept, isNull);
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty);
    m.dispose();
  });

  test('putting back restores each copy and deletes what did not exist', () async {
    final dir = await getAppDir();
    final kept = File('${dir.path}/kept')..writeAsStringSync('before');
    final made = File('${dir.path}/made');
    await GuardUpgradeFiles.backUp([kept.path, made.path]);
    expect(await GuardUpgradeFiles.inProgress(), isTrue);

    kept.writeAsStringSync('after');
    made.writeAsStringSync('new');
    await GuardUpgradeFiles.restore();

    expect(kept.readAsStringSync(), 'before');
    expect(made.existsSync(), isFalse);
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('cancelling leaves every file as it is now and unmarks the set', () async {
    final dir = await getAppDir();
    final kept = File('${dir.path}/kept')..writeAsStringSync('before');
    final made = File('${dir.path}/made');
    await GuardUpgradeFiles.backUp([kept.path, made.path]);

    kept.writeAsStringSync('after');
    made.writeAsStringSync('new');
    await GuardUpgradeFiles.cancel();

    expect(kept.readAsStringSync(), 'after');
    expect(made.readAsStringSync(), 'new');
    expect(await GuardUpgradeFiles.inProgress(), isFalse);
    expect(leftovers(), isEmpty);
  });
}
