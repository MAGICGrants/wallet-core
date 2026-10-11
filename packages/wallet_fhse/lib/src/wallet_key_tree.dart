import 'dart:convert';
import 'dart:typed_data';

import 'package:wallet_domain/wallet_domain.dart' show SeedSource, MetadataSecret;

import 'fhse_native.dart';
import 'fhse_secret.dart';

/// The FHSE seed for a wallet: the proof-of-concept stand-in for the key tree
/// vtnerd proposes in jeffro256/carrot#9.
///
/// ```
/// M (metadata root, wallet_domain's MetadataSecret)
///  └ s_u (user secret)
///     └ s_f (FHSE seed)
///        └ k_p (FHSE root, z85: the wallet password)
/// ```
///
/// **Not a standard.** Carrot's master secret `s_m` exists only for the new key
/// hierarchy, and these wallets are legacy-hierarchy (lwsf and wallet2 have no
/// new-hierarchy wallets yet). `M` stands in for Carrot's `s_me`: it is the
/// metadata root the metadata backup uses too (PM-a for polyseed, BM-a for
/// BIP39; see [MetadataSecret]), reached from the seed by hashes only.
///
/// - **polyseed**: the second PBKDF2 block of `polyseed_keygen`, which no wallet
///   uses for keys;
/// - **BIP39**: SLIP-21 `Key(m/"Monero")` of the BIP39 seed (passphrase
///   included);
/// - **25-word legacy**: nothing. That seed *is* the spend key, whose public
///   key is in the address, so anything derived from it falls to a
///   discrete-log solver, which is why carrot#9 excludes legacy keys. Such a
///   wallet gets a random FHSE seed instead.
///
/// The FHSE branch below `M` (`s_u`, `s_f`) and the metadata backup's
/// (`H_32[M]("Monero metadata backup v1")`) are separated by their own domain
/// strings. The strings here would change once Carrot specifies `s_me`.
class WalletKeyTree {
  WalletKeyTree._();

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
  static bool isSeedDerived(SeedSource seed) => MetadataSecret.isAvailableFor(seed);

  static Future<Uint8List?> _metadataSecret(SeedSource seed) async {
    if (!isSeedDerived(seed)) return null;
    return MetadataSecret.derive(seed);
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
