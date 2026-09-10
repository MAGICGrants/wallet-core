/// Monero protocol constants.
class MoneroConsts {
  MoneroConsts._();

  /// Piconero per XMR: 1 XMR = 10^12 piconero.
  static const decimals = 12;

  /// Digits shown before the display truncates. Monero's 12 decimals are more
  /// precision than a balance readout needs.
  static const smallerDigits = 9;

  /// Confirmations before an output is spendable.
  static const requiredConfirmations = 10;

  /// Ring size used when building a transaction.
  static const mixinCount = 15;

  /// Mainnet. Matches monero_c's `NetworkType` enum.
  static const mainnetNetworkType = 0;

  /// Stagenet, from the same enum (0 mainnet, 1 testnet, 2 stagenet).
  ///
  /// Unused by the apps, which ship mainnet only. It exists for the test fixture
  /// wallets, whose seeds are committed in the clear: a stagenet wallet derives an
  /// address that cannot hold mainnet value, so "never fund these" is a property
  /// rather than a promise.
  static const stagenetNetworkType = 2;
}
