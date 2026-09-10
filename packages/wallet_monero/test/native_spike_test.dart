// monero.dart marks almost its entire surface `@Deprecated("TODO")`. That is
// the generator's marker for "generated but not yet exercised", not a real
// deprecation; there is no replacement API. Per-line ignores don't cover the
// type in a signature, so the suppression is file-level here.
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:polyseed/polyseed.dart';

/// Proves this package can load a monero_c library and drive it.
///
/// The de-risking spike for the whole native tier. Until
/// it passes, every plan that depends on real-FFI tests (the test wallets,
/// the differential harness, the `MoneroBackend` contract tests) rests on an
/// assumption. Once it passes, the rest is ordinary work.
///
/// The key enabler is that `monero.libPath` is a mutable top-level `String`,
/// not a compile-time constant, so a test can point it at a host-built library
/// instead of relying on an app bundle's loader path. That is what makes native
/// runnable in CI with no device and no Flutter app.
///
/// Gating matches pbkdf2_native_test.dart:
///   - library loads                          -> run
///   - missing, REQUIRE_MONERO_FFI unset      -> skip with an actionable message
///   - missing, REQUIRE_MONERO_FFI=1          -> fail
///
/// Set `MONERO_LIB_PATH` to an absolute path; CI does this after building
/// x86_64-linux-gnu with scripts/build-moneroc-ci.sh.
bool get _required => Platform.environment['REQUIRE_MONERO_FFI'] == '1';

String? get _libPathOverride => Platform.environment['MONERO_LIB_PATH'];

bool _configured = false;

void _configureLibPath() {
  if (_configured) return;
  final override = _libPathOverride;
  if (override != null && override.isNotEmpty) monero.libPath = override;
  _configured = true;
}

/// Returns the wallet manager, or null when the library can't be loaded.
monero.WalletManager? _tryGetWalletManager() {
  _configureLibPath();
  try {
    return monero.WalletManagerFactory_getWalletManager();
  } catch (_) {
    return null;
  }
}

/// Returns a manager when available; skips (or fails) otherwise.
monero.WalletManager? _ensureAvailable() {
  final wm = _tryGetWalletManager();
  if (wm != null) return wm;
  if (_required) {
    fail(
      'REQUIRE_MONERO_FFI=1 but the monero_c library could not be loaded '
      '(libPath="${monero.libPath}"). Build it with '
      '`scripts/build-moneroc-ci.sh` and set MONERO_LIB_PATH to the resulting '
      'libwallet2_api_c.so.',
    );
  }
  markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
  return null;
}

String _freshPolyseed() => Polyseed.create().encode(
  PolyseedLang.getByEnglishName('English'),
  PolyseedCoin.POLYSEED_MONERO,
);

/// Creates a wallet from [mnemonic] at [path] and returns its primary address.
String _addressFromPolyseed(
  monero.WalletManager wm, {
  required String mnemonic,
  required String path,
  required bool newWallet,
  int restoreHeight = 0,
}) {
  final wallet = monero.WalletManager_createWalletFromPolyseed(
    wm,
    path: path,
    password: 'spike-password',
    networkType: 0, // mainnet
    mnemonic: mnemonic,
    seedOffset: '',
    newWallet: newWallet,
    restoreHeight: restoreHeight,
    kdfRounds: 1,
  );
  final err = monero.Wallet_errorString(wallet);
  final status = monero.Wallet_status(wallet);
  expect(err, isEmpty, reason: 'createWalletFromPolyseed failed (status $status): $err');
  return monero.Wallet_address(wallet, accountIndex: 0, addressIndex: 0);
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('wallet_monero_spike'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the monero_c library loads and yields a wallet manager', () {
    final wm = _ensureAvailable();
    if (wm == null) return;
    expect(wm, isNotNull);
  });

  test('a polyseed wallet can be created and yields a mainnet address', () {
    final wm = _ensureAvailable();
    if (wm == null) return;

    final address = _addressFromPolyseed(
      wm,
      mnemonic: _freshPolyseed(),
      path: '${tmp.path}/created',
      newWallet: true,
    );

    // Monero mainnet standard addresses: 95 chars, network byte 18 -> '4'.
    expect(address, hasLength(95));
    expect(address, startsWith('4'));
  });

  test('restoring the same polyseed reproduces the same address', () {
    final wm = _ensureAvailable();
    if (wm == null) return;

    final mnemonic = _freshPolyseed();

    final created = _addressFromPolyseed(
      wm,
      mnemonic: mnemonic,
      path: '${tmp.path}/created',
      newWallet: true,
    );

    // newWallet: false is the restore path; the one Skylight uses for a seed
    // that already has history, and the one Spice never exercises.
    final restored = _addressFromPolyseed(
      wm,
      mnemonic: mnemonic,
      path: '${tmp.path}/restored',
      newWallet: false,
      restoreHeight: 3000000,
    );

    expect(restored, created, reason: 'same seed must derive the same address');
  });
}
