// An address with a hidden U+0000. monero_c reads NUL-terminated
// copies of its strings, so C sees only the part before the NUL while the
// screens show the whole string. The guards in front of C run without the
// library; the checks against monero_c's own decoder need a built monero_c and
// skip without MONERO_LIB_PATH:
//   MONERO_LIB_PATH=/abs/libwallet2_api_c.so REQUIRE_MONERO_FFI=1 \
//     flutter test test/monero_address_ffi_test.dart
//
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:wallet_monero/wallet_monero.dart';

bool get _required => Platform.environment['REQUIRE_MONERO_FFI'] == '1';
String? get _libPathOverride => Platform.environment['MONERO_LIB_PATH'];

/// A mainnet primary address.
const _address =
    '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A';

/// The address, a NUL, then the ending of another address: what a user who
/// checks only the ends would take for that other address.
const _withHiddenNul = '$_address\u0000Lx7wS9jX7w';

bool _libraryLoads() {
  final override = _libPathOverride;
  if (override != null && override.isNotEmpty) monero.libPath = override;
  try {
    monero.Wallet_addressValid(_address, MoneroConsts.mainnetNetworkType);
    return true;
  } catch (_) {
    if (_required) {
      fail(
        'REQUIRE_MONERO_FFI=1 but the monero_c library could not be loaded '
        '(libPath="${monero.libPath}"). Set MONERO_LIB_PATH to a built libwallet2_api_c.',
      );
    }
    return false;
  }
}

void main() {
  const backend = FfiMoneroBackend();
  final refusesNul = throwsA(
    isA<ArgumentError>().having((e) => e.message, 'message', contains('U+0000')),
  );

  group('in front of monero_c, with or without the library', () {
    test('the address check refuses a NUL without calling C', () {
      expect(backend.addressValid(_withHiddenNul, MoneroConsts.mainnetNetworkType), isFalse);
    });

    test('neither the fee estimate nor the build takes a NUL', () async {
      // Refused before the handle is touched, so a dummy one is enough.
      const wallet = NativeHandle(0);
      await expectLater(
        backend.estimateTransactionFee(
          wallet,
          destinations: [_withHiddenNul],
          amounts: [BigInt.one],
        ),
        refusesNul,
      );
      await expectLater(
        backend.createTransaction(
          wallet,
          destinations: [_address, _withHiddenNul],
          amounts: [BigInt.one, BigInt.one],
          isSweepAll: false,
          mixinCount: MoneroConsts.mixinCount,
        ),
        refusesNul,
      );
    });
  });

  group('against monero_c', () {
    late bool available;
    setUpAll(() => available = _libraryLoads());

    test('monero_c alone would take the NUL form: the reason for the guards', () {
      if (!available) return markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
      const mainnet = MoneroConsts.mainnetNetworkType;
      expect(monero.Wallet_addressValid(_address, mainnet), isTrue);
      expect(monero.Wallet_addressValid('${_address}Lx7wS9jX7w', mainnet), isFalse);
      expect(monero.Wallet_addressValid(_withHiddenNul, mainnet), isTrue);
    });

    test('the wallet takes the address and refuses it with anything hidden after it', () {
      if (!available) return markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
      final wallet = MoneroWallet();
      expect(wallet.isAddressValid(_address), isTrue);
      expect(wallet.isAddressValid(_withHiddenNul), isFalse);
      expect(wallet.isAddressValid('$_address\u200B'), isFalse);
      expect(backend.addressValid(_withHiddenNul, MoneroConsts.mainnetNetworkType), isFalse);
    });
  });
}
