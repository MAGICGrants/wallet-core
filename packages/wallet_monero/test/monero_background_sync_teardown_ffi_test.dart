// Real-FFI check that turning node-mode background sync off deletes the
// view-only cache and leaves nothing readable without a secret. Asserts the
// fixed postconditions: fails on an unfixed wrapper (the reproduction), passes
// once it honours `off`. Needs a built monero_c; skips without MONERO_LIB_PATH:
//   MONERO_LIB_PATH=/abs/libwallet2_api_c.so REQUIRE_MONERO_FFI=1 \
//     flutter test test/monero_background_sync_teardown_ffi_test.dart
//
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:polyseed/polyseed.dart';

bool get _required => Platform.environment['REQUIRE_MONERO_FFI'] == '1';
String? get _libPathOverride => Platform.environment['MONERO_LIB_PATH'];

bool _configured = false;
void _configureLibPath() {
  if (_configured) return;
  final override = _libPathOverride;
  if (override != null && override.isNotEmpty) monero.libPath = override;
  _configured = true;
}

monero.WalletManager? _ensureAvailable() {
  _configureLibPath();
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

String _freshPolyseed() => Polyseed.create().encode(
  PolyseedLang.getByEnglishName('English'),
  PolyseedCoin.POLYSEED_MONERO,
);

// monero_c BackgroundSyncType values.
const _syncOff = 0;
const _syncCustomPassword = 2;

const _walletPassword = 'wallet-password';
const _cachePassword = 'strong-cache-password';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('bg_sync_teardown'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('turning background sync off deletes the view-only cache and leaves nothing readable without a secret', () {
    final wm = _ensureAvailable();
    if (wm == null) return;

    final path = '${tmp.path}/w';
    final backgroundPath = '$path.background';
    final backgroundKeys = File('$backgroundPath.keys');

    final wallet = monero.WalletManager_createWalletFromPolyseed(
      wm,
      path: path,
      password: _walletPassword,
      networkType: 0,
      mnemonic: _freshPolyseed(),
      seedOffset: '',
      newWallet: true,
      restoreHeight: 0,
      kdfRounds: 1,
    );
    expect(monero.Wallet_errorString(wallet), isEmpty, reason: 'create main wallet');
    monero.Wallet_store(wallet);
    final mainViewKey = monero.Wallet_secretViewKey(wallet);

    // Enable with a strong cache password.
    final enabled = monero.Wallet_setupBackgroundSync(
      wallet,
      backgroundSyncType: _syncCustomPassword,
      walletPassword: _walletPassword,
      backgroundCachePassword: _cachePassword,
    );
    expect(enabled, isTrue, reason: 'enable background sync: ${monero.Wallet_errorString(wallet)}');
    expect(monero.Wallet_getBackgroundSyncType(wallet), _syncCustomPassword, reason: 'configured after enable');
    expect(backgroundKeys.existsSync(), isTrue, reason: 'view-only cache written on enable');

    // Teardown as the pre-fix Dart did: off + empty cache password.
    final tornDown = monero.Wallet_setupBackgroundSync(
      wallet,
      backgroundSyncType: _syncOff,
      walletPassword: _walletPassword,
      backgroundCachePassword: '',
    );
    expect(tornDown, isTrue, reason: 'teardown call returns true: ${monero.Wallet_errorString(wallet)}');

    final typeAfterTeardown = monero.Wallet_getBackgroundSyncType(wallet);

    // Close the main wallet to release the keys-file lock, then try an empty open.
    monero.WalletManager_closeWallet(wm, wallet, false);

    var openedWithEmptyPassword = false;
    var exposedViewKeyMatches = false;
    if (backgroundKeys.existsSync()) {
      final bg = monero.WalletManager_openWallet(wm, path: backgroundPath, password: '', networkType: 0);
      if (monero.Wallet_errorString(bg).isEmpty) {
        openedWithEmptyPassword = true;
        final viewKey = monero.Wallet_secretViewKey(bg);
        exposedViewKeyMatches = viewKey.isNotEmpty && viewKey == mainViewKey;
      }
      monero.WalletManager_closeWallet(wm, bg, false);
    }

    // Summary — never prints key material, only whether it leaked.
    // ignore: avoid_print
    print(
      '[bg-sync teardown] keysFilePresent=${backgroundKeys.existsSync()} '
      'type=$typeAfterTeardown(0=off,2=custom) '
      'openedWithEmptyPassword=$openedWithEmptyPassword '
      'viewKeyExposed=$exposedViewKeyMatches',
    );

    // Fixed postconditions: red on an unfixed wrapper, green once it honours off.
    expect(typeAfterTeardown, _syncOff, reason: 'background sync should report off after teardown');
    expect(backgroundKeys.existsSync(), isFalse, reason: 'the view-only cache file should be deleted on teardown');
    expect(
      openedWithEmptyPassword,
      isFalse,
      reason: 'the view-only wallet opened with an empty password — the private '
          'view key is on disk with no secret',
    );
  });
}
