// Derivation from https://github.com/cake-tech/cake_wallet/blob/main/cw_monero/lib/bip39_seed.dart

import 'dart:typed_data';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:polyseed/polyseed.dart';

/// Converts a BIP39 mnemonic to the equivalent Monero 25-word legacy seed.
///
/// Monero's own wallet API has no BIP39 entry point, so a BIP39 restore is
/// performed by deriving the spend key at `m/44'/128'/account'/0/0` (128 is
/// Monero's SLIP-44 coin type), reducing it mod the ed25519 curve order, and
/// re-encoding it as a legacy word list that `WalletManager_recoveryWallet`
/// accepts.
///
/// **This derivation must never change.** Users' funds sit behind it, and a
/// different path or reduction silently produces a valid but empty wallet: no
/// error, no funds. `bip39_legacy_test` pins it with known-answer vectors.
String getLegacySeedFromBip39(String mnemonic, {int accountIndex = 0, String passphrase = ''}) {
  final seed = bip39.mnemonicToSeed(mnemonic, passphrase: passphrase);
  final keyPair = bip32.BIP32.fromSeed(seed).derivePath("m/44'/128'/$accountIndex'/0/0");
  final spendKey = _reduceECKey(keyPair.privateKey!);

  return LegacySeedLang.getByEnglishName('English').encodePhrase(spendKey.toHexString());
}

const _ed25519CurveOrder = '1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED';

Uint8List _reduceECKey(Uint8List buffer) {
  final curveOrder = BigInt.parse(_ed25519CurveOrder, radix: 16);
  var result = _readBytes(buffer) % curveOrder;

  final resultBuffer = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    resultBuffer[i] = (result & BigInt.from(0xff)).toInt();
    result = result >> 8;
  }

  return resultBuffer;
}

/// Reads a little-endian [BigInt] out of [bytes].
///
/// From https://github.com/dart-lang/sdk/issues/32803#issuecomment-387405784
BigInt _readBytes(Uint8List bytes) {
  BigInt read(int start, int end) {
    if (end - start <= 4) {
      var result = 0;
      for (var i = end - 1; i >= start; i--) {
        result = result * 256 + bytes[i];
      }
      return BigInt.from(result);
    }
    final mid = start + ((end - start) >> 1);
    return read(start, mid) + read(mid, end) * (BigInt.one << ((mid - start) * 8));
  }

  return read(0, bytes.length);
}
