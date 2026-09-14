import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

void main() {
  test('a bare seed phrase is the payload', () {
    final parsed = parseRestoreQr('  abandon ability able about  ');
    expect(parsed!.seed, 'abandon ability able about');
    expect(parsed.restoreHeight, isNull);
  });

  test('reads seed and height out of each accepted scheme', () {
    for (final scheme in ['monero', 'monero-wallet', 'monero_wallet']) {
      final parsed = parseRestoreQr('$scheme:?seed=one%20two%20three&height=3120000');
      expect(parsed!.seed, 'one two three', reason: scheme);
      expect(parsed.restoreHeight, 3120000, reason: scheme);
    }
  });

  test('accepts restoreHeight as a spelling of height', () {
    expect(parseRestoreQr('monero:?seed=a%20b&restoreHeight=42')!.restoreHeight, 42);
  });

  test('a non-numeric height is dropped, not fatal', () {
    final parsed = parseRestoreQr('monero:?seed=a%20b&height=soon');
    expect(parsed!.seed, 'a b');
    expect(parsed.restoreHeight, isNull);
  });

  test('a known scheme with no seed is rejected', () {
    expect(parseRestoreQr('monero:?height=100'), isNull);
  });

  test('empty input is rejected', () {
    expect(parseRestoreQr('   '), isNull);
  });

  test('an unknown scheme falls back to treating the whole payload as a seed', () {
    // A bitcoin: URI is not a restore code, but neither is it worth rejecting a
    // phrase that merely contains a colon.
    expect(parseRestoreQr('bitcoin:bc1qxyz')!.seed, 'bitcoin:bc1qxyz');
  });

  test('buildRestoreQr round-trips through the parser', () {
    final raw = buildRestoreQr(seed: 'one two three', height: 99);
    final parsed = parseRestoreQr(raw)!;
    expect(parsed.seed, 'one two three');
    expect(parsed.restoreHeight, 99);
  });
}
