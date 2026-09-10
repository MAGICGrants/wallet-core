import 'package:flutter_test/flutter_test.dart';
import 'package:polyseed/polyseed.dart';
import 'package:wallet_domain/wallet_domain.dart';

/// Standard BIP39 all-zeros entropy vectors. Public test vectors with no value;
/// never put a seed with mainnet funds in a fixture.
const _bip39Twelve =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// 15 words is what `SeedPolicy.spice` generates, so it is the length real
/// users hold, and the one a 12/24-only vector set would miss.
const _bip39Fifteen =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';
const _bip39TwentyFour =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon art';

/// 25 words from the Monero legacy English list. Word count is what the legacy
/// branch keys on; the backend's own word-list check rejects a bad checksum.
const _legacyTwentyFive =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';

String _freshPolyseed() => Polyseed.create().encode(
  PolyseedLang.getByEnglishName('English'),
  PolyseedCoin.POLYSEED_MONERO,
);

void main() {
  group('SeedSource.detect', () {
    test('classifies a polyseed', () {
      final seed = SeedSource.detect(_freshPolyseed());
      expect(seed, isA<PolyseedSeed>());
      expect(seed!.format, SeedFormat.polyseed);
    });

    test('classifies BIP39 at 12, 15 and 24 words', () {
      // BIP39 also permits 18 and 21; those are valid and would classify the
      // same way, but neither app generates them so no vector is pinned.
      expect(SeedSource.detect(_bip39Twelve)!.format, SeedFormat.bip39);
      expect(SeedSource.detect(_bip39Fifteen)!.format, SeedFormat.bip39);
      expect(SeedSource.detect(_bip39TwentyFour)!.format, SeedFormat.bip39);
    });

    test('a 15-word BIP39 seed is never mistaken for a polyseed', () {
      // Polyseed is exactly 16 words and BIP39 has no 16-word length, so they
      // cannot collide, but 15 sits right next to it, and Spice generates 15,
      // so the boundary is worth pinning rather than assuming.
      final seed = SeedSource.detect(_bip39Fifteen);
      expect(seed, isA<Bip39Seed>());
      expect(seed!.mnemonic.split(' '), hasLength(15));
    });

    test('classifies a 25-word Monero legacy seed', () {
      final seed = SeedSource.detect(_legacyTwentyFive);
      expect(seed, isA<MoneroLegacySeed>());
      expect(seed!.format, SeedFormat.moneroLegacy);
    });

    test('normalizes surrounding and repeated whitespace', () {
      final seed = SeedSource.detect('  $_bip39Twelve  '.replaceAll(' ', '   '));
      expect(seed?.format, SeedFormat.bip39);
      expect(seed!.mnemonic, _bip39Twelve);
    });

    test('returns null for input that matches no encoding', () {
      expect(SeedSource.detect(''), isNull);
      expect(SeedSource.detect('   '), isNull);
      expect(SeedSource.detect('not a mnemonic at all'), isNull);
      // Valid BIP39 words, wrong checksum, and not a legacy word count.
      expect(SeedSource.detect('abandon abandon abandon'), isNull);
    });

    test('polyseed birthday decodes as a plausible date', () {
      // Regression guard: Polyseed.birthday is Unix *seconds*, not millis and
      // not a DateTime. Reading it as millis puts every restore in 1970 and
      // silently rescans the whole chain.
      final seed = SeedSource.detect(_freshPolyseed()) as PolyseedSeed;
      final birthday = seed.birthday;
      expect(birthday.year, greaterThanOrEqualTo(2021));
      expect(birthday.isAfter(DateTime(2014, 4, 18)), isTrue);
      expect(birthday.isBefore(DateTime.now().add(const Duration(days: 2))), isTrue);
    });

    test('a detected seed round-trips its mnemonic unchanged', () {
      final phrase = _freshPolyseed();
      expect(SeedSource.detect(phrase)!.mnemonic, phrase);
    });

    test('rejects a 16-word phrase whose polyseed checksum fails', () {
      // `Polyseed.isValidSeed` only checks the word count and the language, so
      // a typo'd polyseed passes it. Without our own checksum check, detect()
      // would report a broken phrase as a valid polyseed and the user would
      // only find out when the restore failed.
      final broken = _mutateUntilChecksumFails(_freshPolyseed());

      // Precondition: the package still considers it "valid".
      expect(Polyseed.isValidSeed(broken), isTrue);
      // ...and we still reject it.
      expect(SeedSource.detect(broken), isNull);
    });
  });
}

/// Swaps word pairs until the polyseed checksum genuinely fails, so the test
/// never depends on a random mutation happening to be invalid.
String _mutateUntilChecksumFails(String phrase) {
  final words = phrase.split(' ');
  for (var i = 0; i + 1 < words.length; i++) {
    final candidate = [...words];
    candidate[i] = words[i + 1];
    candidate[i + 1] = words[i];
    final joined = candidate.join(' ');
    if (joined == phrase) continue;
    try {
      Polyseed.decode(joined, PolyseedLang.getByPhrase(joined), PolyseedCoin.POLYSEED_MONERO);
    } catch (_) {
      return joined;
    }
  }
  fail('could not construct a checksum-failing polyseed from $phrase');
}
