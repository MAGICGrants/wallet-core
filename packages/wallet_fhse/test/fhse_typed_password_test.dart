import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:polyseed/polyseed.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/wallet_fhse.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'support/fake_security_key.dart';
import 'support/host_library.dart';

/// Linux and Windows, where the user types the wallet password and no keystore
/// holds one: the typed password unlocks the seed-derived root, through
/// `wallet.key` while keys are off and as the FHSE file's outer password once
/// they are on.
void main() {
  final skip = useHostLibrary();
  late Directory tmp;
  late MemorySecretStore secrets;

  const typed = 'correct horse battery staple';
  const pin = KeyVerification.pin('123456');

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fhse_typed');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    SharedPreferencesService.store = MemoryPreferenceStore();
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    WalletSecrets.holdsWalletPassword = false;
    WalletManager.passwordGuard = const FhseWalletGuard();
  });

  tearDown(() async {
    FhseVault.endSession();
    TypedPasswordStore.instance.resetForTesting();
    WalletFileCrypto.walletPasswordIterations = WalletFileCrypto.typedPasswordIterations;
    WalletManager.passwordGuard = null;
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File wrapFile() => File('${tmp.path}/wallet.key');

  SeedSource newSeed() => PolyseedSeed(
    Polyseed.create().encode(
      PolyseedLang.getByEnglishName('English'),
      PolyseedCoin.POLYSEED_MONERO,
    ),
  );

  /// Onboarding as the desktop apps do it: the typed password, then a restore.
  Future<(WalletManager, String)> onboard(SeedSource seed) async {
    final manager = WalletManager(coins: () => [])..setWalletPassword(typed);
    await manager.restoreAll(seed: seed, from: RestorePoint.date(DateTime.utc(2026)));
    return (manager, manager.passwordForGuard!);
  }

  /// A fresh start: nothing in memory but the files.
  WalletManager restart() {
    FhseVault.endSession();
    TypedPasswordStore.instance.endSession();
    return WalletManager(coins: () => []);
  }

  test('a new wallet gets the seed-derived password, kept under the typed one', () async {
    final seed = newSeed();
    final (manager, walletPassword) = await onboard(seed);

    expect(walletPassword, isNot(typed));
    expect(walletPassword, await FhseVault.passwordForNewWallet(seed));
    expect(wrapFile().existsSync(), isTrue);
    expect(await FhseVault.isAvailable(), isTrue);
    expect(
      secrets.values.containsKey(walletPasswordStorageKey),
      isFalse,
      reason: 'no keystore copy on Linux or Windows',
    );
    manager.dispose();

    final next = restart();
    expect(await next.unlockWithTypedPassword('wrong password'), isFalse);
    expect(next.hasPassword, isFalse);
    expect(await next.unlockWithTypedPassword(typed), isTrue);
    expect(next.passwordForGuard, walletPassword);
    expect(await next.isPasswordGuarded(), isFalse);
    next.dispose();
  }, skip: skip);

  test('with keys on, the typed password opens the FHSE file and a key the wallet', () async {
    final (manager, walletPassword) = await onboard(newSeed());
    final key = FakeSecurityKey();
    final setup = await FhseVault.beginSetup(walletPassword: walletPassword);
    await setup.addKey(authenticator: key, verification: pin, name: 'Key');
    await FhseWalletGuard.engage(setup, manager);
    expect(wrapFile().existsSync(), isFalse, reason: 'the typed password alone opens nothing');
    manager.dispose();

    final next = restart();
    expect(await next.unlockWithTypedPassword('wrong password'), isFalse);
    expect(await next.unlockWithTypedPassword(typed), isTrue);
    expect(next.hasPassword, isFalse, reason: 'a key comes next');
    expect(await next.isPasswordGuarded(), isTrue);

    final released = await FhseVault.unlock(authenticator: key, verification: pin);
    expect(released, walletPassword);
    await next.unlockWithGuardedPassword(released);
    expect(next.passwordForGuard, walletPassword);
    next.dispose();
  }, skip: skip);

  test('a key alone does not open the FHSE file without the typed password', () async {
    final (manager, walletPassword) = await onboard(newSeed());
    final key = FakeSecurityKey();
    final setup = await FhseVault.beginSetup(walletPassword: walletPassword);
    await setup.addKey(authenticator: key, verification: pin, name: 'Key');
    await FhseWalletGuard.engage(setup, manager);
    manager.dispose();

    restart().dispose();
    await expectLater(
      FhseVault.unlock(authenticator: key, verification: pin),
      throwsA(isA<StateError>()),
    );
  }, skip: skip);

  test('turning keys off puts the typed password back in charge', () async {
    final (manager, walletPassword) = await onboard(newSeed());
    final setup = await FhseVault.beginSetup(walletPassword: walletPassword);
    await setup.addKey(authenticator: FakeSecurityKey(), verification: pin, name: 'Key');
    await FhseWalletGuard.engage(setup, manager);

    await FhseWalletGuard.release(manager);
    expect(await FhseVault.isEngaged(), isFalse);
    expect(wrapFile().existsSync(), isTrue);
    manager.dispose();

    final next = restart();
    expect(await next.unlockWithTypedPassword(typed), isTrue);
    expect(next.passwordForGuard, walletPassword);
    next.dispose();
  }, skip: skip);

  test('an engage cut short before wallet.key went finishes at the next key unlock', () async {
    final (manager, walletPassword) = await onboard(newSeed());
    final key = FakeSecurityKey();
    final setup = await FhseVault.beginSetup(walletPassword: walletPassword);
    await setup.addKey(authenticator: key, verification: pin, name: 'Key');
    // The FHSE file is written, then the process dies before wallet.key goes.
    await setup.commit();
    expect(wrapFile().existsSync(), isTrue);
    manager.dispose();

    final next = restart();
    expect(await next.unlockWithTypedPassword(typed), isTrue);
    expect(next.hasPassword, isFalse, reason: 'the FHSE file decides once it exists');
    await next.unlockWithGuardedPassword(
      await FhseVault.unlock(authenticator: key, verification: pin),
    );
    expect(wrapFile().existsSync(), isFalse);
    next.dispose();
  }, skip: skip);

  test('a wallet made before this build keeps its typed password as the wallet password', () async {
    final seed = newSeed();
    await SeedStore.save(seed: seed, from: RestorePoint.date(DateTime.utc(2026)), password: typed);

    final manager = WalletManager(coins: () => []);
    expect(await manager.unlockWithTypedPassword('wrong password'), isFalse);
    expect(await manager.unlockWithTypedPassword(typed), isTrue);
    expect(manager.passwordForGuard, typed);
    expect(await FhseVault.isAvailable(), isFalse, reason: 'no FHSE seed for an older wallet');
    manager.dispose();
  }, skip: skip);

  test('a full lock forgets the typed password', () async {
    final (manager, walletPassword) = await onboard(newSeed());
    // What the app's full lock does (fullyLockWallet).
    FhseVault.endSession();
    await manager.fullyLock();
    await expectLater(
      FhseVault.beginSetup(walletPassword: walletPassword),
      throwsA(isA<StateError>()),
    );
    manager.dispose();
  }, skip: skip);

  test('deleting the wallet removes wallet.key too', () async {
    final (manager, _) = await onboard(newSeed());
    await manager.deleteAll();
    expect(wrapFile().existsSync(), isFalse);
    expect(await FhseVault.isAvailable(), isFalse);
    manager.dispose();
  }, skip: skip);

  group('bound to this PC (a Windows TPM)', () {
    late FakeMachineKeys tpm;

    setUp(() => PcBinding.keys = tpm = FakeMachineKeys());
    tearDown(() => PcBinding.keys = const NoMachineKeys());

    File fhseFile() => File('${tmp.path}/wallet.fhse');

    /// Keys on: one key enrolled, wallet.key gone.
    Future<FakeSecurityKey> engage() async {
      final (manager, walletPassword) = await onboard(newSeed());
      final key = FakeSecurityKey();
      final setup = await FhseVault.beginSetup(walletPassword: walletPassword);
      await setup.addKey(authenticator: key, verification: pin, name: 'Key');
      await FhseWalletGuard.engage(setup, manager);
      manager.dispose();
      return key;
    }

    test('the FHSE file is bound: it opens here, and not with the typed password alone', () async {
      final key = await engage();
      expect(
        () => FhseSecret.open(
          fhseFile().readAsBytesSync(),
          password: Uint8List.fromList(utf8.encode(typed)),
        ),
        throwsA(
          isA<FhseException>().having((e) => e.code, 'code', FhseException.decryptionFailure),
        ),
        reason: 'a copy elsewhere cannot be opened, or its password guessed',
      );

      final next = restart();
      expect(await next.unlockWithTypedPassword('wrong password'), isFalse);
      expect(await next.unlockWithTypedPassword(typed), isTrue);
      expect(await FhseVault.keys(), hasLength(1));
      final released = await FhseVault.unlock(authenticator: key, verification: pin);
      await next.unlockWithGuardedPassword(released);

      // A key added in the session keeps the file bound.
      await FhseVault.addKey(authenticator: FakeSecurityKey(), verification: pin, name: 'Two');
      next.dispose();
      final again = restart();
      expect(await again.unlockWithTypedPassword(typed), isTrue);
      expect(await FhseVault.keys(), hasLength(2));
      again.dispose();
    }, skip: skip);

    test('on another PC the right password is not taken for a wrong one', () async {
      await engage();
      final next = restart();
      tpm.forgetAll();
      await expectLater(
        next.unlockWithTypedPassword(typed),
        throwsA(isA<BoundToAnotherPcException>()),
      );
      next.dispose();
    }, skip: skip);

    test('turning keys off keeps wallet.key bound', () async {
      final key = await engage();
      final next = restart();
      expect(await next.unlockWithTypedPassword(typed), isTrue);
      await next.unlockWithGuardedPassword(
        await FhseVault.unlock(authenticator: key, verification: pin),
      );
      await FhseWalletGuard.release(next);
      next.dispose();

      final opensAlone = await () async {
        try {
          await WalletFileCrypto.decryptFromBase64(wrapFile().readAsStringSync(), typed);
          return true;
        } on FormatException {
          return false;
        }
      }();
      expect(opensAlone, isFalse);
      final last = restart();
      expect(await last.unlockWithTypedPassword(typed), isTrue);
      expect(last.hasPassword, isTrue);
      last.dispose();
    }, skip: skip);
  });
}
