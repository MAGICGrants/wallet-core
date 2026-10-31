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

  Future<File> file() async => File('${(await getAppDir()).path}/xmr_keys');

  @override
  Future<List<String>> walletPasswordFilePaths() async => [
    ...await super.walletPasswordFilePaths(),
    (await file()).path,
  ];

  @override
  Future<void> changeWalletPassword({required String from, required String to}) async {
    await super.changeWalletPassword(from: from, to: to);
    if (!await rekeyWalletFile(await file(), from: from, to: to)) throw StateError('neither');
    if (failMove) throw StateError('disk full');
  }
}

/// The security-key upgrade: a wallet made before the guard moves onto it at
/// its first unlock, and one cut short is kept or put back.
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
  });

  tearDown(() {
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
  }

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
}
