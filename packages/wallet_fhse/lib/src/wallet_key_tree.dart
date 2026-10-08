import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:polyseed/polyseed.dart';
import 'package:wallet_domain/wallet_domain.dart'
    show SeedSource, PolyseedSeed, Bip39Seed, MoneroLegacySeed;

import 'fhse_native.dart';
import 'fhse_secret.dart';

/// The FHSE seed for a wallet: the proof-of-concept stand-in for the key tree
/// vtnerd proposes in jeffro256/carrot#9.
///
/// ```
/// s_m (master secret)
///  └ s_me (metadata secret)
///     └ s_u (user secret)
///        └ s_f (FHSE seed)
///           └ k_p (FHSE root, z85: the wallet password)
/// ```
///
/// **Not a standard.** Carrot's master secret `s_m` exists only for the new key
/// hierarchy, and these wallets are legacy-hierarchy (lwsf and wallet2 have no
/// new-hierarchy wallets yet). So `s_me` here is a hash of the most-root
/// secret each seed format has, behind a one-way function, with domain strings
/// this proof of concept made up:
///
/// - **polyseed**: its 32-byte storage form, which carries the 150-bit secret
///   the spend key is derived from (vtnerd's polyseed#25 idea);
/// - **BIP39**: the 64-byte BIP39 seed (PBKDF2 of the mnemonic and passphrase),
///   which sits above the BIP32 path to the Monero keys;
/// - **25-word legacy**: nothing. That seed *is* the spend key, whose public
///   key is in the address, so anything derived from it falls to a
///   discrete-log solver, which is why carrot#9 excludes legacy keys. Such a
///   wallet gets a random FHSE seed instead.
///
/// A wallet restored elsewhere does not derive these keys, and the strings
/// would change once Carrot specifies `s_me`.
class WalletKeyTree {
  WalletKeyTree._();

  static const _personalPolyseed = 'SKYPOC-SME-PSEED';
  static const _personalBip39 = 'SKYPOC-SME-BIP39';
  static const _contextUser = 'SKY_SU01';
  static const _contextFhse = 'SKY_SF01';

  /// `s_f` for [seed], or a fresh random one where the seed has no secret
  /// above its spend key ([isSeedDerived] says which).
  static Future<Uint8List> fhseSeedFor(SeedSource seed) async {
    final sme = await _metadataSecret(seed);
    if (sme == null) return random(fhseSecretLength);
    try {
      final su = kdf(sme, _contextUser);
      try {
        return kdf(su, _contextFhse);
      } finally {
        su.fillRange(0, su.length, 0);
      }
    } finally {
      sme.fillRange(0, sme.length, 0);
    }
  }

  /// Whether [seed] determines the FHSE seed; false means it is random and
  /// exists only in this wallet's files.
  static bool isSeedDerived(SeedSource seed) => seed is! MoneroLegacySeed;

  static Future<Uint8List?> _metadataSecret(SeedSource seed) async {
    switch (seed) {
      case PolyseedSeed():
        final storage = Polyseed.decode(
          seed.mnemonic,
          PolyseedLang.getByPhrase(seed.mnemonic),
          PolyseedCoin.POLYSEED_MONERO,
        ).save();
        try {
          return hashPersonal(storage, _personalPolyseed);
        } finally {
          storage.fillRange(0, storage.length, 0);
        }
      case Bip39Seed():
        final mnemonic = seed.mnemonic;
        final passphrase = seed.passphrase;
        // PBKDF2 with 2048 rounds: off the UI isolate.
        final bip39Seed = await Isolate.run(
          () => bip39.mnemonicToSeed(mnemonic, passphrase: passphrase),
        );
        try {
          return hashPersonal(bip39Seed, _personalBip39);
        } finally {
          bip39Seed.fillRange(0, bip39Seed.length, 0);
        }
      case MoneroLegacySeed():
        return null;
    }
  }

  /// libsodium `crypto_kdf_blake2b_derive_from_key`, subkey id 0.
  static Uint8List kdf(Uint8List key, String context) {
    final n = FhseNative.instance;
    final ctx = Uint8List.fromList(ascii.encode(context));
    return n.withBytes(key, (k, kLen) {
      return n.withBytes(ctx, (c, cLen) {
        return n.withOutput(32, (out, outLen) => n.kdf(k, kLen, c, cLen, out, outLen), 'kdf');
      });
    });
  }

  /// Unkeyed BLAKE2b-256 with a 16-byte personalisation.
  static Uint8List hashPersonal(Uint8List message, String personal) {
    final n = FhseNative.instance;
    final pers = Uint8List.fromList(ascii.encode(personal));
    return n.withBytes(message, (m, mLen) {
      return n.withBytes(pers, (p, pLen) {
        return n.withOutput(
          32,
          (out, outLen) => n.hashPersonal(m, mLen, p, pLen, out, outLen),
          'hash',
        );
      });
    });
  }

  /// libsodium `randombytes_buf`.
  static Uint8List random(int length) {
    final n = FhseNative.instance;
    return n.withOutput(length, (out, outLen) => n.random(out, outLen), 'random');
  }
}
