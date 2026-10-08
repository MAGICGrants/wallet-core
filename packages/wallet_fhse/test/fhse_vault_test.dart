import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:polyseed/polyseed.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/wallet_fhse.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'support/fake_security_key.dart';
import 'support/host_library.dart';

String newPolyseed() => Polyseed.create().encode(
  PolyseedLang.getByEnglishName('English'),
  PolyseedCoin.POLYSEED_MONERO,
);

const _pin = KeyVerification.pin('123456');
const _sparePin = KeyVerification.pin('654321');

void main() {
  final skip = useHostLibrary();
  late Directory tmp;
  late MemorySecretStore secrets;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fhse_vault');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    SharedPreferencesService.store = MemoryPreferenceStore();
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    WalletSecrets.holdsWalletPassword = true;
  });

  tearDown(() async {
    FhseVault.endSession();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> createWallet(SeedSource seed) async {
    final password = await FhseVault.passwordForNewWallet(seed);
    await FhseVault.walletCreated(password);
    return password;
  }

  test('a new wallet is available for keys, with nothing enrolled', () async {
    final mnemonic = newPolyseed();
    final password = await createWallet(PolyseedSeed(mnemonic));
    expect(password, hasLength(40));
    // The password is the seed's: the same phrase gives it again.
    expect(await FhseVault.passwordForNewWallet(PolyseedSeed(mnemonic)), password);
    expect(await FhseVault.isAvailable(), isTrue);
    expect(await FhseVault.isEngaged(), isFalse);
    expect(await FhseVault.keys(), isEmpty);
  }, skip: skip);

  test('set up two keys, then unlock with either', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final blue = FakeSecurityKey();
    final spare = FakeSecurityKey(pin: '654321');

    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: blue, verification: _pin, name: 'Blue');
    // The same key twice is refused by the key itself (exclude list).
    await expectLater(
      setup.addKey(authenticator: blue, verification: _pin, name: 'Blue again'),
      throwsA(isA<StateError>()),
    );
    await setup.addKey(authenticator: spare, verification: _sparePin, name: 'Spare');
    expect(await FhseVault.isEngaged(), isFalse, reason: 'nothing written before commit');
    await setup.commit();

    expect(await FhseVault.isEngaged(), isTrue);
    expect((await FhseVault.keys()).map((k) => k.name), ['Blue', 'Spare']);

    FhseVault.endSession();
    expect(await FhseVault.unlock(authenticator: spare, verification: _sparePin), password);
    FhseVault.endSession();
    expect(await FhseVault.unlock(authenticator: blue, verification: _pin), password);
    await expectLater(
      FhseVault.unlock(authenticator: FakeSecurityKey(), verification: _pin),
      throwsA(isA<StateError>()),
    );
  }, skip: skip);

  test('adding a key uses the unlocked session', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final first = FakeSecurityKey();
    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: first, verification: _pin, name: 'First');
    await setup.commit();

    final later = FakeSecurityKey();
    await FhseVault.addKey(authenticator: later, verification: _pin, name: 'Later');
    expect(first.assertionCalls, 0, reason: 'no tap of an existing key needed');
    expect((await FhseVault.keys()).map((k) => k.name), ['First', 'Later']);

    FhseVault.endSession();
    expect(await FhseVault.unlock(authenticator: later, verification: _pin), password);
  }, skip: skip);

  test('setting up again without a key removes it', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final keep = FakeSecurityKey();
    final lost = FakeSecurityKey();
    final first = await FhseVault.beginSetup(walletPassword: password);
    await first.addKey(authenticator: keep, verification: _pin, name: 'Keep');
    await first.addKey(authenticator: lost, verification: _pin, name: 'Lost');
    await first.commit();

    final again = await FhseVault.beginSetup(walletPassword: password);
    await again.addKey(authenticator: keep, verification: _pin, name: 'Keep');
    await again.commit();

    FhseVault.endSession();
    expect((await FhseVault.keys()).map((k) => k.name), ['Keep']);
    // The lost key's credential is not in the new file, and a new salt means
    // its old credential would not open it either.
    await expectLater(
      FhseVault.unlock(authenticator: lost, verification: _pin),
      throwsA(isA<StateError>()),
    );
    expect(await FhseVault.unlock(authenticator: keep, verification: _pin), password);
  }, skip: skip);

  test('a cancelled setup changes nothing', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: FakeSecurityKey(), verification: _pin, name: 'Key');
    setup.cancel();
    expect(await FhseVault.isEngaged(), isFalse);
  }, skip: skip);

  test('a key enrolled with its PIN opens with its fingerprint, and back', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final bio = FakeSecurityKey(fingerprint: true);
    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: bio, verification: _pin, name: 'Bio');
    await setup.commit();

    FhseVault.endSession();
    expect(
      await FhseVault.unlock(authenticator: bio, verification: const KeyVerification.builtIn()),
      password,
    );
    await FhseVault.addKey(
      authenticator: FakeSecurityKey(fingerprint: true),
      verification: const KeyVerification.builtIn(),
      name: 'Bio 2',
    );
    FhseVault.endSession();
    expect(await FhseVault.unlock(authenticator: bio, verification: _pin), password);
  }, skip: skip);

  test('keys are named after they are touched, in setup and after', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final setup = await FhseVault.beginSetup(walletPassword: password);
    final first = await setup.addKey(
      authenticator: FakeSecurityKey(),
      verification: _pin,
      name: 'Security key 1',
    );
    setup.rename(first.id, 'Blue');
    expect(setup.keys.single.name, 'Blue');
    expect(() => setup.rename('nope', 'X'), throwsArgumentError);
    await setup.commit();

    final second = await FhseVault.addKey(
      authenticator: FakeSecurityKey(),
      verification: _pin,
      name: 'Security key 2',
    );
    await FhseVault.renameKey(second.id, 'Spare');
    expect((await FhseVault.keys()).map((k) => k.name), ['Blue', 'Spare']);
    await expectLater(FhseVault.renameKey('nope', 'X'), throwsArgumentError);
  }, skip: skip);

  test("a key's serial is kept with its name, and filled in once it can be read", () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final blue = FakeSecurityKey(serial: 12345678);
    final hidden = FakeSecurityKey();
    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: blue, verification: _pin, name: 'Blue');
    await setup.addKey(authenticator: hidden, verification: _pin, name: 'Spare');
    expect(setup.keys.map((k) => k.serial), [12345678, null]);
    await setup.commit();
    expect((await FhseVault.keys()).map((k) => k.serial), [12345678, null]);

    // The spare's serial became readable (say, its visibility was turned on).
    hidden.serial = 87654321;
    FhseVault.endSession();
    expect(await FhseVault.unlock(authenticator: hidden, verification: _pin), password);
    expect((await FhseVault.keys()).map((k) => k.serial), [12345678, 87654321]);

    // A rename keeps it.
    await FhseVault.renameKey((await FhseVault.keys()).first.id, 'Navy');
    expect((await FhseVault.keys()).first.serial, 12345678);
  }, skip: skip);

  test('the recovery phrase rebuilds the password when every key is lost', () async {
    final mnemonic = newPolyseed();
    final password = await createWallet(PolyseedSeed(mnemonic));
    expect(await FhseVault.recoverWithSeed(PolyseedSeed(mnemonic)), password);
    await expectLater(
      FhseVault.recoverWithSeed(PolyseedSeed(newPolyseed())),
      throwsA(
        isA<FhseVaultException>().having(
          (e) => e.reason,
          'reason',
          FhseVaultFailure.wrongRecoveryPhrase,
        ),
      ),
    );
  }, skip: skip);

  test('a 25-word wallet gets a random FHSE seed that still sets up', () async {
    final seed = MoneroLegacySeed(List.filled(25, 'abbey').join(' '));
    final password = await createWallet(seed);
    final setup = await FhseVault.beginSetup(walletPassword: password);
    final key = FakeSecurityKey();
    await setup.addKey(authenticator: key, verification: _pin, name: 'Key');
    await setup.commit();
    FhseVault.endSession();
    expect(await FhseVault.unlock(authenticator: key, verification: _pin), password);
    await expectLater(
      FhseVault.recoverWithSeed(seed),
      throwsA(
        isA<FhseVaultException>().having(
          (e) => e.reason,
          'reason',
          FhseVaultFailure.recoveryNotPossible,
        ),
      ),
    );
  }, skip: skip);

  test('engage takes the password out of the keystore; release puts it back', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    await storeMobileWalletPassword(password);
    final manager = WalletManager(coins: () => [])..setWalletPassword(password);
    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: FakeSecurityKey(), verification: _pin, name: 'Key');

    await FhseWalletGuard.engage(setup, manager);
    expect(await getMobileWalletPassword(), isNull);
    expect(await const FhseWalletGuard().isEngaged(), isTrue);
    expect(
      await manager.isPasswordGuarded(),
      isFalse,
      reason: 'no guard installed on the manager here',
    );

    await FhseWalletGuard.release(manager);
    expect(await getMobileWalletPassword(), password);
    expect(await FhseVault.isEngaged(), isFalse);
    expect(await FhseVault.isAvailable(), isTrue, reason: 'keys can be set up again later');
    manager.dispose();
  }, skip: skip);

  test('deleting the wallet forgets everything', () async {
    final password = await createWallet(PolyseedSeed(newPolyseed()));
    final setup = await FhseVault.beginSetup(walletPassword: password);
    await setup.addKey(authenticator: FakeSecurityKey(), verification: _pin, name: 'Key');
    await setup.commit();
    await const FhseWalletGuard().walletDeleted();
    expect(await FhseVault.isAvailable(), isFalse);
    expect(await FhseVault.isEngaged(), isFalse);
    expect(secrets.values.keys.where((k) => k.startsWith('fhse')), isEmpty);
  }, skip: skip);
}
