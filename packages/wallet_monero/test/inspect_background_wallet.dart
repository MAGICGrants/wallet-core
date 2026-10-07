// THROWAWAY — do not commit. Opens a .background view-only wallet with an EMPTY
// password to demonstrate the exposure, and prints the address + keys it yields.
// Use it only on a test wallet.
//
//   MONERO_LIB_PATH=/abs/libwallet2_api_c.so \
//   MONERO_BG_WALLET=/abs/mywallet_xmr_node.background \   # the file, not .keys
//   MONERO_NETWORK=0 \                                     # 0 main,1 test,2 stage
//   flutter test test/inspect_background_wallet.dart
//
// ignore_for_file: avoid_print, deprecated_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;

void main() {
  test('open a .background wallet with an empty password', () {
    final lib = Platform.environment['MONERO_LIB_PATH'];
    final path = Platform.environment['MONERO_BG_WALLET'];
    final network = int.tryParse(Platform.environment['MONERO_NETWORK'] ?? '0') ?? 0;

    if (lib == null || path == null) {
      markTestSkipped('set MONERO_LIB_PATH and MONERO_BG_WALLET');
      return;
    }
    expect(File(path).existsSync(), isTrue, reason: 'no cache file at $path');
    expect(File('$path.keys').existsSync(), isTrue, reason: 'no keys file at $path.keys');

    monero.libPath = lib;
    final wm = monero.WalletManagerFactory_getWalletManager();

    // The exposure: open with password "".
    final w = monero.WalletManager_openWallet(wm, path: path, password: '', networkType: network);
    final err = monero.Wallet_errorString(w);

    print('--- opened "$path" with EMPTY password ---');
    print('error:      ${err.isEmpty ? '(none — it opened)' : err}');
    if (err.isEmpty) {
      print('address:    ${monero.Wallet_address(w, accountIndex: 0, addressIndex: 0)}');
      print('view key:   ${monero.Wallet_secretViewKey(w)}');
      final spend = monero.Wallet_secretSpendKey(w);
      print('spend key:  $spend  (all-zero/empty => view-only)');
    }

    monero.WalletManager_closeWallet(wm, w, false);

    expect(err, isEmpty, reason: 'it opened with no secret — view key + history are exposed');
  });
}
