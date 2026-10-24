import 'dart:convert';
import 'dart:typed_data';

import 'package:wallet_domain/wallet_domain.dart' show SeedPurpose, SeedSecret, SeedSource;

import 'fhse_native.dart';
import 'fhse_secret.dart';

/// The FHSE seed `s_f` for a wallet, and the primitives FHSE's keys use.
///
/// ```
/// seed
///  ├ M     the metadata root (SeedPurpose.metadata)
///  └ s_f   the FHSE seed (SeedPurpose.fhse)
///     └ k_p  FHSE root: crypto_kdf_blake2b(s_f, "FHSEROOT"), z85 (the wallet password)
/// ```
///
/// `s_f` is a sibling of the metadata root, not derived from it ([SeedSecret]):
///
/// - **polyseed**: `H_32[r_p]("Monero FHSE seed")`, with `r_p` the second
///   PBKDF2 block of `polyseed_keygen`, which no wallet uses for keys;
/// - **BIP39**: `H_32[r]("Monero FHSE seed" ‖ IntToBytes32(a))`, with `r` the
///   SLIP-21 `Key(m/"Monero")` of the BIP39 seed (passphrase included);
/// - **25-word legacy**: nothing. That seed *is* the spend key, whose public
///   key is in the address, so anything derived from it falls to a
///   discrete-log solver. Such a wallet gets a random FHSE seed instead.
///
/// The domain strings are fixed: changing one would change the wallet password
/// of every wallet whose FHSE seed comes from its seed.
class WalletKeyTree {
  WalletKeyTree._();

  /// `s_f` for [seed], or a fresh random one where the seed has no secret
  /// above its spend key ([isSeedDerived] says which).
  static Future<Uint8List> fhseSeedFor(SeedSource seed) async {
    if (!isSeedDerived(seed)) return random(fhseSecretLength);
    return SeedSecret.derive(seed, SeedPurpose.fhse);
  }

  /// Whether [seed] determines the FHSE seed; false means it is random and
  /// exists only in this wallet's files.
  static bool isSeedDerived(SeedSource seed) => SeedSecret.isAvailableFor(seed);

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
