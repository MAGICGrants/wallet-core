import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';

/// The distinct byte values seen across [samples] freshly generated mnemonics.
///
/// bip39's generator RNG is private, so its output can only be observed by
/// round-tripping generated mnemonics back through `mnemonicToEntropy`.
Set<int> _generatedEntropyBytes({required int samples, required int strength}) {
  final seen = <int>{};
  for (var i = 0; i < samples; i++) {
    final entropy = bip39.mnemonicToEntropy(bip39.generateMnemonic(strength: strength));
    for (var j = 0; j < entropy.length; j += 2) {
      seen.add(int.parse(entropy.substring(j, j + 2), radix: 16));
    }
  }
  return seen;
}

void main() {
  // Taken from Spice's `stack-bip39` branch. Guards the reason we pin
  // cypherstack/stack-bip39 rather than the unmaintained dart-bitcoin/bip39:
  // upstream draws entropy bytes with `nextInt(255)`, so 0xff is unreachable and
  // each byte carries log2(255) rather than 8 bits. The fork uses 256.
  // See https://github.com/dart-bitcoin/bip39/issues/23.
  //
  // 1000 mnemonics x 20 bytes = 20000 draws, so a spurious failure has
  // probability 256 * (255/256)^20000 ~= 3e-32, while the unfixed package fails
  // on every run.
  group('bip39 entropy is unbiased', () {
    late final Set<int> observed;

    setUpAll(() {
      // 160 bits is what WalletManager.generateSeed() asks for.
      observed = _generatedEntropyBytes(samples: 1000, strength: 160);
    });

    test('0xff is reachable', () {
      expect(
        observed,
        contains(0xff),
        reason: 'bip39 is drawing bytes with nextInt(255) instead of nextInt(256)',
      );
    });

    test('every byte value is reachable', () {
      expect(observed.length, 256);
    });
  });
}
