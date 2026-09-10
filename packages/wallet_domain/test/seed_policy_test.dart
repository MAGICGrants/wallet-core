import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

const _bip39 =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// Stand-ins for the real `CryptoWallet.supportedSeedFormats`.
const _moneroSupports = {SeedFormat.polyseed, SeedFormat.bip39, SeedFormat.moneroLegacy};
const _bitcoinSupports = {SeedFormat.bip39};

void main() {
  group('SeedPolicy — Skylight (Monero-only)', () {
    const policy = SeedPolicy.skylight;

    test('generates polyseed', () => expect(policy.generate, SeedFormat.polyseed));

    test('accepts all three restore formats', () {
      expect(policy.accepts(SeedFormat.polyseed), isTrue);
      expect(policy.accepts(SeedFormat.bip39), isTrue);
      expect(policy.accepts(SeedFormat.moneroLegacy), isTrue);
    });

    test('passes a polyseed through to Monero', () {
      expect(
        () => policy.check(
          const PolyseedSeed('sixteen words here'),
          coinSupported: _moneroSupports,
          coinSymbol: 'XMR',
        ),
        returnsNormally,
      );
    });
  });

  group('SeedPolicy — Spice (multicoin)', () {
    const policy = SeedPolicy.spice;

    test('generates bip39', () => expect(policy.generate, SeedFormat.bip39));

    test('rejects polyseed and legacy at the policy layer', () {
      expect(policy.accepts(SeedFormat.polyseed), isFalse);
      expect(policy.accepts(SeedFormat.moneroLegacy), isFalse);
      expect(policy.accepts(SeedFormat.bip39), isTrue);
    });

    test('throws on a polyseed even though Monero could take it', () {
      expect(
        () => policy.check(
          const PolyseedSeed('sixteen words here'),
          coinSupported: _moneroSupports,
          coinSymbol: 'XMR',
        ),
        throwsA(isA<UnsupportedSeedFormatException>()),
      );
    });
  });

  group('SeedPolicy — two-sided enforcement', () {
    test('a permissive policy cannot push a polyseed into Bitcoin', () {
      // The coin is the second gate: even if an app policy allowed polyseed,
      // a coin that cannot derive from one must still refuse.
      expect(
        () => SeedPolicy.skylight.check(
          const PolyseedSeed('sixteen words here'),
          coinSupported: _bitcoinSupports,
          coinSymbol: 'BTC',
        ),
        throwsA(
          isA<UnsupportedSeedFormatException>().having((e) => e.reason, 'reason', contains('BTC')),
        ),
      );
    });

    test('bip39 is accepted by both apps for every coin', () {
      for (final policy in [SeedPolicy.skylight, SeedPolicy.spice]) {
        for (final supported in [_moneroSupports, _bitcoinSupports]) {
          expect(
            () => policy.check(const Bip39Seed(_bip39), coinSupported: supported, coinSymbol: 'X'),
            returnsNormally,
          );
        }
      }
    });
  });

  // The `WalletAppConfig` naming schemes were tested here, against the namer
  // functions in isolation. They live in `app_config_test.dart` now, asserted
  // on the keys that reach storage instead: a namer can be correct and simply
  // not be consulted, which orphans the same settings and passes the isolated
  // check.
}
