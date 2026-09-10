import 'seed.dart';

/// The app's seed rules, injected once at startup.
///
/// A Monero-only wallet generates a polyseed and accepts anything Monero can
/// restore. A multicoin wallet needs one BIP39 seed that derives every asset.
/// The core never branches on which kind of app it is in; it only reads this
/// object.
class SeedPolicy {
  const SeedPolicy({required this.generate, required this.acceptedForRestore});

  /// Format used when the app generates a brand-new wallet.
  final SeedFormat generate;

  /// Formats the app will accept on restore. The *effective* set for a given
  /// coin is this intersected with `CryptoWallet.supportedSeedFormats`, so a
  /// polyseed can never reach a Bitcoin wallet even if a policy allowed it.
  final Set<SeedFormat> acceptedForRestore;

  /// Monero-only, polyseed by default, restores anything Monero understands.
  static const skylight = SeedPolicy(
    generate: SeedFormat.polyseed,
    acceptedForRestore: {SeedFormat.polyseed, SeedFormat.bip39, SeedFormat.moneroLegacy},
  );

  /// Multicoin: one BIP39 seed reused across every asset.
  static const spice = SeedPolicy(
    generate: SeedFormat.bip39,
    acceptedForRestore: {SeedFormat.bip39},
  );

  bool accepts(SeedFormat format) => acceptedForRestore.contains(format);

  /// Throws [UnsupportedSeedFormatException] unless [seed] is permitted both by
  /// this policy and by [coinSupported].
  void check(
    SeedSource seed, {
    required Set<SeedFormat> coinSupported,
    required String coinSymbol,
  }) {
    if (!accepts(seed.format)) {
      throw UnsupportedSeedFormatException(
        seed.format,
        'this app does not accept ${seed.format.name} seeds',
      );
    }
    if (!coinSupported.contains(seed.format)) {
      throw UnsupportedSeedFormatException(
        seed.format,
        '$coinSymbol cannot be derived from a ${seed.format.name} seed',
      );
    }
  }
}
