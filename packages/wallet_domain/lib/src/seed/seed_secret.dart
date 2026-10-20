import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:pointycastle/export.dart';
import 'package:polyseed/polyseed.dart';

import 'seed.dart';

/// Carrot's keyed hash: BLAKE2b with the "Monero" personalisation over a
/// transcript whose first byte is the length of the domain string
/// (`carrot_core/hash_functions.cpp`, `transcript_fixed.h`).
///
/// `H_n[key](domain ‖ data)`: [length] is n in bytes, [key] may be empty.
Uint8List carrotHash(int length, Uint8List key, String domain, [List<int> data = const []]) {
  final domainBytes = ascii.encode(domain);
  if (domainBytes.length > 255) throw ArgumentError('domain string too long');
  final personal = Uint8List(16)..setRange(0, 6, ascii.encode('Monero'));
  final digest = Blake2bDigest(
    digestSize: length,
    key: key.isEmpty ? null : key,
    personalization: personal,
  );
  final input = Uint8List(1 + domainBytes.length + data.length)
    ..[0] = domainBytes.length
    ..setRange(1, 1 + domainBytes.length, domainBytes)
    ..setRange(1 + domainBytes.length, 1 + domainBytes.length + data.length, data);
  final out = digest.process(input);
  input.fillRange(0, input.length, 0);
  return out;
}

/// `H_32`, the 32-byte [carrotHash].
Uint8List carrotHash32(Uint8List key, String domain, [List<int> data = const []]) =>
    carrotHash(32, key, domain, data);

/// Thrown when a seed cannot have seed secrets: a 25-word seed (it *is* the
/// spend key), or a polyseed with an offset passphrase, whose
/// `cn_slow_hash` mix-in is not implemented here.
class SeedSecretUnavailable implements Exception {
  const SeedSecretUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'SeedSecretUnavailable: $reason';
}

/// What a seed secret is for. Each purpose has its own domain string, and all
/// of them are listed here, so no two can share one.
enum SeedPurpose {
  /// The metadata root `M`, behind the metadata backup.
  metadata('Monero metadata secret'),

  /// The security-key (FHSE) seed `s_f`, behind the wallet password.
  fhse('Monero FHSE seed');

  const SeedPurpose(this.domain);

  final String domain;
}

/// A secret for one [SeedPurpose], straight from the seed:
///
/// ```
/// polyseed  r_p = polyseed_keygen(seed, POLYSEED_MONERO, 64)[32:64]
///           key = H_32[r_p](purpose ‖ o)
/// BIP39     r   = SLIP-21 Key(S / "Monero"), S the BIP39 seed (passphrase included)
///           key = H_32[r](purpose ‖ IntToBytes32(a))
/// 25-word   none
/// ```
///
/// Every purpose is a sibling under `r_p` or `r`, so none is derived from
/// another: the security-key seed does not hang off the metadata secret. What
/// sets one wallet apart from another on the same words therefore goes into
/// every purpose: `o`, the `cn_slow_hash` of a polyseed offset passphrase
/// (empty without one; offset passphrases are refused), and `a`, the BIP39
/// account. A new purpose must take both.
///
/// Every step is a hash, so nothing on the path is exposed by a discrete-log
/// solver that knows the wallet's public keys. A 25-word seed is the private
/// spend key itself, whose public key is in the address, so nothing is derived
/// from it.
///
/// **The domain strings and the SLIP-21 label are fixed.** The values here match
/// the test vectors in `test/seed_secret_test.dart`; changing any of them would
/// move that purpose's backups or security-key setups to a new key.
class SeedSecret {
  SeedSecret._();

  static const slip21Label = 'Monero';

  /// Both apps hold one wallet per seed, at account 0.
  static const defaultAccount = 0;

  /// Whether [seed] can have seed secrets at all. False for 25-word seeds and
  /// polyseed offset passphrases.
  static bool isAvailableFor(SeedSource seed) => switch (seed) {
    PolyseedSeed(:final passphrase) => passphrase.isEmpty,
    Bip39Seed() => true,
    MoneroLegacySeed() => false,
  };

  /// The secret for [purpose] from [seed], computed off the calling isolate
  /// (PBKDF2: 10,000 rounds for polyseed, 2,048 for BIP39).
  ///
  /// Throws [SeedSecretUnavailable] where [isAvailableFor] is false. The
  /// caller wipes the result when done with it.
  static Future<Uint8List> derive(
    SeedSource seed,
    SeedPurpose purpose, {
    int account = defaultAccount,
  }) {
    if (!isAvailableFor(seed)) {
      throw SeedSecretUnavailable(switch (seed) {
        MoneroLegacySeed() => '25-word seeds are the spend key; nothing is derived from them',
        _ => 'polyseed offset passphrases are not supported',
      });
    }
    final format = seed.format;
    final mnemonic = seed.mnemonic;
    final passphrase = seed.passphrase;
    return Isolate.run(() => deriveSync(format, mnemonic, passphrase, purpose, account: account));
  }

  /// [derive], on the calling isolate. For tests and for code already off the
  /// UI isolate.
  static Uint8List deriveSync(
    SeedFormat format,
    String mnemonic,
    String passphrase,
    SeedPurpose purpose, {
    int account = defaultAccount,
  }) {
    switch (format) {
      case SeedFormat.polyseed:
        if (passphrase.isNotEmpty) {
          throw const SeedSecretUnavailable('polyseed offset passphrases are not supported');
        }
        final rp = polyseedBase(mnemonic);
        try {
          // `o` is empty: no offset passphrase.
          return carrotHash32(rp, purpose.domain);
        } finally {
          rp.fillRange(0, rp.length, 0);
        }
      case SeedFormat.bip39:
        final r = bip39Base(mnemonic, passphrase);
        try {
          return carrotHash32(r, purpose.domain, _u32le(account));
        } finally {
          r.fillRange(0, r.length, 0);
        }
      case SeedFormat.moneroLegacy:
        throw const SeedSecretUnavailable(
          '25-word seeds are the spend key; nothing is derived from them',
        );
    }
  }

  /// `r_p`: bytes 32–63 of `polyseed_keygen(seed, POLYSEED_MONERO, 64)`, the
  /// second PBKDF2 block, which no wallet uses for keys. The first 32 bytes are
  /// the legacy spend key's.
  ///
  /// An encrypted polyseed is used as decoded, without its passphrase; that is
  /// the same (wrong) wallet the restore produces.
  static Uint8List polyseedBase(String mnemonic) {
    final seed = Polyseed.decode(
      mnemonic,
      PolyseedLang.getByPhrase(mnemonic),
      PolyseedCoin.POLYSEED_MONERO,
    );
    final full = seed.generateKey(PolyseedCoin.POLYSEED_MONERO, 64);
    final rp = Uint8List.fromList(full.sublist(32, 64));
    full.fillRange(0, full.length, 0);
    return rp;
  }

  /// `r`: SLIP-21 `Key(S / "Monero")` of the BIP39 seed `S`, [passphrase]
  /// included.
  static Uint8List bip39Base(String mnemonic, String passphrase) {
    final s = bip39.mnemonicToSeed(mnemonic, passphrase: passphrase);
    try {
      return slip21Key(s, utf8.encode(slip21Label));
    } finally {
      s.fillRange(0, s.length, 0);
    }
  }

  /// SLIP-21 `Key(m/label)`: one level only, as Ledger's OS derives it.
  static Uint8List slip21Key(Uint8List seed, List<int> label) {
    final master = _hmacSha512(ascii.encode('Symmetric key seed'), seed);
    final child = _hmacSha512(master.sublist(0, 32), [0, ...label]);
    master.fillRange(0, master.length, 0);
    final key = Uint8List.fromList(child.sublist(32, 64));
    child.fillRange(0, child.length, 0);
    return key;
  }

  static Uint8List _hmacSha512(List<int> key, List<int> data) {
    final mac = HMac(SHA512Digest(), 128)..init(KeyParameter(Uint8List.fromList(key)));
    return mac.process(Uint8List.fromList(data));
  }

  static Uint8List _u32le(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}
