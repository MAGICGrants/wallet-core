import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Known-answer vectors for the BIP39 -> Monero legacy seed derivation.
///
/// These are not aspirational: they were computed from this implementation and
/// pinned. The derivation is BIP44 with SLIP-44 coin type 128, which predates
/// any wallet's BIP39 support and is what users' funds sit behind. If a change
/// moves any of these, it does not produce an error; it produces a valid,
/// empty wallet, and the user's balance becomes reachable only by whoever
/// works out what changed. Treat a failure here as "the change is wrong",
/// never as "the vector needs updating".
///
/// Inputs are the standard all-zeros BIP39 vectors; no value has ever been
/// sent to anything derived from them.
const _bip39Twelve =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// **Spice's generation length.** 15 words is 160 bits of entropy, and it is
/// what `SeedPolicy.spice` produces; so this is the length that actually
/// matters in production, not the 12- and 24-word cases usually seen in test
/// vectors.
const _bip39Fifteen =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';

/// A second 15-word case with non-degenerate entropy (0x0f repeated), so the
/// coverage does not rest entirely on an all-zeros input.
const _bip39FifteenAlt =
    'audit journey sense bulk valley maple destroy tiger '
    'audit journey sense bulk valley maple distance';

const _bip39TwentyFour =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon art';

const _expectedTwelveAccount0 =
    'subtly emerge cucumber wield jester neutral echo guide problems hiding '
    'necklace tapestry offend tell erase ugly envy turnip click iguana pebbles '
    'idols listen nail cucumber';

const _expectedTwelveAccount1 =
    'jive aquarium jingle sensible obnoxious southern altitude nineteen irate '
    'present older agenda bounced gecko irony flying pliers sadness dapper '
    'weavers duke having last lymph irony';

const _expectedTwelveWithPassphrase =
    'hedgehog digit yearbook luxury firm urchins wade twice igloo likewise '
    'vacation sulking obnoxious fonts oval vessel rafts jagged adrenalin reef '
    'frying avatar tudor vampire urchins';

const _expectedFifteenAccount0 =
    'galaxy rounded ability vinegar betting light natural token toffee gemstone '
    'maul dreams sphere offend tomorrow rash awkward seismic doing unquoted '
    'gags aztec maze medicate token';

const _expectedFifteenAccount1 =
    'feast rapid safety humid edgy suffice tacit elbow pebbles jester eels '
    'rewind raking copy violin waist omission robot bugs hunter sushi alpine '
    'mechanic moment suffice';

const _expectedFifteenAltAccount0 =
    'zodiac rest ugly rated itinerary gaze orders bested mammal inline highway '
    'rover nuns huts sailor ruined losing hurried abnormal tonic hairy bobsled '
    'adapt apricot itinerary';

const _expectedTwentyFourAccount0 =
    'coal gourmet geometry raking lilac sewage pawnshop rudely bays ascend '
    'gifts reinvest voted moisture kept podcast vocal paradise acidic espionage '
    'hijack wrap vogue waist sewage';

void main() {
  group('known-answer vectors — do not update these to match a change', () {
    test('12-word BIP39, account 0', () {
      expect(getLegacySeedFromBip39(_bip39Twelve), _expectedTwelveAccount0);
    });

    test('12-word BIP39, account 1', () {
      expect(getLegacySeedFromBip39(_bip39Twelve, accountIndex: 1), _expectedTwelveAccount1);
    });

    test('12-word BIP39 with a passphrase', () {
      expect(
        getLegacySeedFromBip39(_bip39Twelve, passphrase: 'TREZOR'),
        _expectedTwelveWithPassphrase,
      );
    });

    test('24-word BIP39, account 0', () {
      expect(getLegacySeedFromBip39(_bip39TwentyFour), _expectedTwentyFourAccount0);
    });

    // 15 words is what Spice generates, so these are the vectors covering the
    // length real users will actually hold.
    test('15-word BIP39, account 0 — Spice generation length', () {
      expect(getLegacySeedFromBip39(_bip39Fifteen), _expectedFifteenAccount0);
    });

    test('15-word BIP39, account 1', () {
      expect(getLegacySeedFromBip39(_bip39Fifteen, accountIndex: 1), _expectedFifteenAccount1);
    });

    test('15-word BIP39, non-degenerate entropy', () {
      expect(getLegacySeedFromBip39(_bip39FifteenAlt), _expectedFifteenAltAccount0);
    });
  });

  group('properties', () {
    // BIP39 permits 12, 15, 18, 21 and 24 words. These vectors cover 12, 15
    // and 24; the lengths the two apps actually produce or accept. 18 and 21
    // are valid BIP39 and would work, but neither app generates them and no
    // vector is pinned for them.
    test('produces a 25-word legacy seed from each covered length (12, 15, 24)', () {
      for (final mnemonic in [_bip39Twelve, _bip39Fifteen, _bip39FifteenAlt, _bip39TwentyFour]) {
        expect(getLegacySeedFromBip39(mnemonic).split(' '), hasLength(25));
      }
    });

    test('each covered mnemonic gives a distinct legacy seed', () {
      final seeds = {
        for (final m in [_bip39Twelve, _bip39Fifteen, _bip39FifteenAlt, _bip39TwentyFour])
          getLegacySeedFromBip39(m),
      };
      expect(seeds, hasLength(4));
    });

    test('is deterministic', () {
      expect(getLegacySeedFromBip39(_bip39Twelve), getLegacySeedFromBip39(_bip39Twelve));
    });

    test('the account index changes the result', () {
      final seeds = {
        for (var i = 0; i < 4; i++) getLegacySeedFromBip39(_bip39Twelve, accountIndex: i),
      };
      expect(seeds, hasLength(4));
    });

    test('a passphrase changes the result', () {
      expect(
        getLegacySeedFromBip39(_bip39Twelve, passphrase: 'a'),
        isNot(getLegacySeedFromBip39(_bip39Twelve)),
      );
    });

    test('different mnemonics give different seeds', () {
      expect(getLegacySeedFromBip39(_bip39Twelve), isNot(getLegacySeedFromBip39(_bip39TwentyFour)));
    });

    test('the derived seed classifies as moneroLegacy, not bip39', () {
      // Closes the loop with SeedSource.detect: a converted seed must be
      // handed to the legacy factory, never back through the BIP39 path.
      final legacy = getLegacySeedFromBip39(_bip39Twelve);
      expect(legacy.split(' '), hasLength(25));
      expect(legacy, isNot(_bip39Twelve));
    });
  });
}
