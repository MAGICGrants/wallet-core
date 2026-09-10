import 'package:bip39/bip39.dart' as bip39;
import 'package:polyseed/polyseed.dart';

/// Mnemonic encodings the shared core knows how to classify.
///
/// [moneroLegacy] is the 25-word Monero word list. It is Monero-only by
/// definition and is accepted on restore, never generated.
enum SeedFormat { polyseed, bip39, moneroLegacy }

/// A user-supplied or freshly-generated mnemonic, tagged with its encoding.
///
/// Tagging at the boundary (rather than re-sniffing the string in every
/// consumer) is what lets [SeedPolicy] and `CryptoWallet.supportedSeedFormats`
/// reject an unsupported format *before* any wallet file is touched.
sealed class SeedSource {
  const SeedSource(this.mnemonic, {this.passphrase = ''});

  final String mnemonic;

  /// Monero's "seed offset". Empty for every path both apps ship today; kept
  /// on the type so adding passphrase support later is not an API break.
  final String passphrase;

  SeedFormat get format;

  /// Classifies [mnemonic]. Returns null when it matches no known encoding.
  ///
  /// Word counts do not collide: polyseed is always 16, BIP39 is 12/15/18/21/24,
  /// legacy Monero is 25. So the order below is for clarity, not correctness.
  ///
  /// The polyseed branch verifies the checksum itself. `Polyseed.isValidSeed`
  /// checks only the word count and that the language is recognized; a typo'd
  /// phrase passes it, and would then be reported as "a polyseed" right up
  /// until the backend rejected it at restore time. Checking here lets the
  /// caller say "that isn't a valid seed" while the user is still typing.
  ///
  /// Only the 25-word branch is left unverified: its checksum lives in the
  /// Monero word list, and the backend's own check is the authority.
  static SeedSource? detect(String mnemonic, {String passphrase = ''}) {
    final normalized = mnemonic.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;

    if (Polyseed.isValidSeed(normalized) && _polyseedChecksumValid(normalized)) {
      return PolyseedSeed(normalized, passphrase: passphrase);
    }
    if (bip39.validateMnemonic(normalized)) {
      return Bip39Seed(normalized, passphrase: passphrase);
    }
    if (normalized.split(' ').length == 25) {
      return MoneroLegacySeed(normalized, passphrase: passphrase);
    }
    return null;
  }

  /// Decoding is pure polynomial arithmetic (no KDF), so this is cheap enough
  /// to run on every keystroke of a restore field.
  ///
  /// The catch is deliberately untyped: polyseed 0.0.7 raises a checksum
  /// mismatch with `throw ChecksumMismatchException`, the *type*, not an
  /// instance; so `on ChecksumMismatchException` would never match it.
  /// An encrypted polyseed still decodes without its passphrase; only the
  /// secret is encrypted, so this produces no false negatives.
  static bool _polyseedChecksumValid(String normalized) {
    try {
      Polyseed.decode(
        normalized,
        PolyseedLang.getByPhrase(normalized),
        PolyseedCoin.POLYSEED_MONERO,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

final class PolyseedSeed extends SeedSource {
  const PolyseedSeed(super.mnemonic, {super.passphrase});

  @override
  SeedFormat get format => SeedFormat.polyseed;

  /// The creation date encoded in the seed itself. A polyseed carries its own
  /// birthday, so a restore never has to ask the user for a height or date.
  ///
  /// `Polyseed.birthday` is Unix **seconds**, not a `DateTime` and not millis.
  DateTime get birthday {
    final decoded = Polyseed.decode(
      mnemonic,
      PolyseedLang.getByPhrase(mnemonic),
      PolyseedCoin.POLYSEED_MONERO,
    );
    return DateTime.fromMillisecondsSinceEpoch(decoded.birthday * 1000);
  }
}

final class Bip39Seed extends SeedSource {
  const Bip39Seed(super.mnemonic, {super.passphrase});

  @override
  SeedFormat get format => SeedFormat.bip39;
}

final class MoneroLegacySeed extends SeedSource {
  const MoneroLegacySeed(super.mnemonic, {super.passphrase});

  @override
  SeedFormat get format => SeedFormat.moneroLegacy;
}

/// Where a restore should start scanning.
///
/// Both Skylight and Spice accept a height and a date (Skylight also reads a
/// height out of a restore QR); a date converts via `getHeightByDate` and a
/// polyseed supplies its own birthday. Carrying the intent instead of a
/// resolved int keeps the "wallet2's polyseed factory silently drops the height
/// it was handed" special case expressible, see MoneroWallet.restoreFromSeed,
/// and lets [SeedStore] persist a height without degrading it to a date.
sealed class RestorePoint {
  const RestorePoint();

  const factory RestorePoint.height(int height) = RestoreFromHeight;
  const factory RestorePoint.date(DateTime date) = RestoreFromDate;
  const factory RestorePoint.seedBirthday() = RestoreFromSeedBirthday;

  /// A seed with no history behind it, generated right now.
  ///
  /// Distinct from a height of 0: it sets the backend's `newWallet` flag, which
  /// makes both backends skip the rescan entirely. Setting this for a seed that
  /// *does* have history produces a wallet that comes up permanently empty.
  const factory RestorePoint.newWallet() = RestoreNewWallet;

  Map<String, dynamic> toJson() => switch (this) {
    RestoreFromHeight(:final height) => {'kind': 'height', 'height': height},
    RestoreFromDate(:final date) => {'kind': 'date', 'iso': date.toIso8601String()},
    RestoreFromSeedBirthday() => {'kind': 'seedBirthday'},
    RestoreNewWallet() => {'kind': 'newWallet'},
  };

  static RestorePoint fromJson(Map<String, dynamic> json) => switch (json['kind']) {
    'height' => RestorePoint.height(json['height'] as int),
    'date' => RestorePoint.date(DateTime.parse(json['iso'] as String)),
    'seedBirthday' => const RestorePoint.seedBirthday(),
    'newWallet' => const RestorePoint.newWallet(),
    final kind => throw FormatException('Unknown restore point kind: $kind'),
  };
}

final class RestoreFromHeight extends RestorePoint {
  const RestoreFromHeight(this.height);
  final int height;
}

final class RestoreFromDate extends RestorePoint {
  const RestoreFromDate(this.date);
  final DateTime date;
}

final class RestoreFromSeedBirthday extends RestorePoint {
  const RestoreFromSeedBirthday();
}

final class RestoreNewWallet extends RestorePoint {
  const RestoreNewWallet();
}

/// Thrown when a mnemonic's encoding is not permitted, either by the app's
/// [SeedPolicy] or by the coin's `supportedSeedFormats`.
class UnsupportedSeedFormatException implements Exception {
  UnsupportedSeedFormatException(this.format, this.reason);

  final SeedFormat format;
  final String reason;

  @override
  String toString() => 'UnsupportedSeedFormatException(${format.name}): $reason';
}
