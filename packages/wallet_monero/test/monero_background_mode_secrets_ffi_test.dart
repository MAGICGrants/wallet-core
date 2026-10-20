// Real-FFI check that wallet2's background mode leaves nothing in the wallet
// that leads to the spend key: not the key, the seed, nor the wallet password
// that decrypts the keys file. Needs a built monero_c; skips without
// MONERO_LIB_PATH:
//   MONERO_LIB_PATH=/abs/libwallet2_api_c.so REQUIRE_MONERO_FFI=1 \
//     flutter test test/monero_background_mode_secrets_ffi_test.dart
//
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:polyseed/polyseed.dart';

bool get _required => Platform.environment['REQUIRE_MONERO_FFI'] == '1';
String? get _libPathOverride => Platform.environment['MONERO_LIB_PATH'];

monero.WalletManager? _ensureAvailable() {
  final override = _libPathOverride;
  if (override != null && override.isNotEmpty) monero.libPath = override;
  monero.WalletManager? wm;
  try {
    wm = monero.WalletManagerFactory_getWalletManager();
  } catch (_) {
    wm = null;
  }
  if (wm != null) return wm;
  if (_required) {
    fail(
      'REQUIRE_MONERO_FFI=1 but the monero_c library could not be loaded '
      '(libPath="${monero.libPath}"). Build it with scripts/build-moneroc-ci.sh '
      'and set MONERO_LIB_PATH to the resulting libwallet2_api_c.so.',
    );
  }
  markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
  return null;
}

// monero_c BackgroundSyncType.CustomPassword.
const _syncCustomPassword = 2;

const _walletPassword = 'wallet-password';
const _cachePassword = 'strong-cache-password';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('bg_mode_secrets'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'background mode holds no spend key, seed or wallet password; leaving it takes the password back',
    () {
      final wm = _ensureAvailable();
      if (wm == null) return;

      final path = '${tmp.path}/w';
      final created = monero.WalletManager_createWalletFromPolyseed(
        wm,
        path: path,
        password: _walletPassword,
        networkType: 0,
        mnemonic: Polyseed.create().encode(
          PolyseedLang.getByEnglishName('English'),
          PolyseedCoin.POLYSEED_MONERO,
        ),
        seedOffset: '',
        newWallet: true,
        restoreHeight: 0,
        kdfRounds: 1,
      );
      expect(monero.Wallet_errorString(created), isEmpty, reason: 'create the wallet');
      monero.WalletManager_closeWallet(wm, created, true);
      // Opened as the app opens it: with the password, which monero_c keeps.
      final wallet = monero.WalletManager_openWallet(wm, path: path, password: _walletPassword);
      addTearDown(() => monero.WalletManager_closeWallet(wm, wallet, false));
      expect(monero.Wallet_errorString(wallet), isEmpty, reason: 'open the wallet');
      expect(
        monero.Wallet_setupBackgroundSync(
          wallet,
          backgroundSyncType: _syncCustomPassword,
          walletPassword: _walletPassword,
          backgroundCachePassword: _cachePassword,
        ),
        isTrue,
        reason: 'set up the view-only cache: ${monero.Wallet_errorString(wallet)}',
      );
      expect(monero.Wallet_getPassword(wallet) == _walletPassword, isTrue);
      final spendKey = monero.Wallet_secretSpendKey(wallet);
      expect(spendKey, hasLength(64));

      expect(
        monero.Wallet_startBackgroundSync(wallet),
        isTrue,
        reason: 'enter background mode: ${monero.Wallet_errorString(wallet)}',
      );
      expect(
        monero.Wallet_getPassword(wallet),
        isEmpty,
        reason: 'the password opens the keys file',
      );
      expect(monero.Wallet_secretSpendKey(wallet), isEmpty, reason: 'no key of zeros either');
      expect(monero.Wallet_seed(wallet, seedOffset: ''), isEmpty);
      expect(monero.Wallet_getPolyseed(wallet, passphrase: ''), isEmpty);
      expect(
        monero.Wallet_store(wallet, path: '${tmp.path}/copy'),
        isFalse,
        reason: 'new files would need the password',
      );
      expect(File('${tmp.path}/copy.keys').existsSync(), isFalse);
      expect(monero.Wallet_store(wallet), isTrue, reason: 'the background cache still saves');

      expect(monero.Wallet_stopBackgroundSync(wallet, 'not-the-password'), isFalse);
      expect(monero.Wallet_getPassword(wallet), isEmpty, reason: 'a wrong password is not kept');

      expect(
        monero.Wallet_stopBackgroundSync(wallet, _walletPassword),
        isTrue,
        reason: 'leave background mode: ${monero.Wallet_errorString(wallet)}',
      );
      expect(monero.Wallet_getPassword(wallet) == _walletPassword, isTrue);
      expect(monero.Wallet_secretSpendKey(wallet) == spendKey, isTrue);
      expect(monero.Wallet_store(wallet), isTrue);
    },
  );
}
