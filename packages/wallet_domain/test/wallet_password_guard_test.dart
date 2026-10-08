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
  Future<void> walletCreated(String password) async => created = password;

  @override
  Future<bool> isEngaged() async => engaged;

  @override
  Future<void> walletDeleted() async => deleted++;
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
    // `flutter test` runs on a desktop OS; these are the mobile paths.
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
    expect(await getMobileWalletPassword(), 'from-guard');
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
    await storeMobileWalletPassword('left over');
    guard.engaged = true;
    final m = WalletManager(coins: () => [FakeWallet('XMR')]);
    expect(await m.loadMobileWalletPassword(), isFalse);
    expect(m.hasPassword, isFalse);
    expect(await m.isPasswordGuarded(), isTrue);
    m.dispose();
  });

  test('App Lock keeps a guarded password in memory, and drops a stored one', () async {
    await SharedPreferencesService.set<bool>(DomainPreferenceKeys.appLockEnabled, true);
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

  test('unlocking with the guard sets the password and clears a keystore leftover', () async {
    await storeMobileWalletPassword('pw');
    guard.engaged = true;
    final m = WalletManager(coins: () => [FakeWallet('XMR')]);
    await m.unlockWithGuardedPassword('pw');
    expect(m.passwordForGuard, 'pw');
    expect(await getMobileWalletPassword(), isNull);
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
    await m.prepareViewOnlyAll();
    await m.forgetViewOnlyAll();
    expect(w.prepared, 1);
    expect(w.forgotten, 1);
    m.dispose();
  });

  test('deleting the wallet tells the guard', () async {
    final m = WalletManager(coins: () => [FakeWallet('XMR')]);
    await m.deleteAll();
    expect(guard.deleted, 1);
    m.dispose();
  });
}
