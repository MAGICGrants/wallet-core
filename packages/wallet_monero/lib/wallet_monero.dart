/// Monero implementation of `CryptoWallet`: LWSF and full-node modes,
/// polyseed / BIP39 / 25-word legacy restore, subaddresses, fee estimation.
///
/// `MoneroWallet` itself lands after `CryptoWallet` exists in `wallet_domain`;
/// it extends that class, so the base has to be reconciled first. What is here
/// now is the coin-specific material that does not depend on it.
library;

export 'src/consts.dart';
export 'src/fake_monero_backend.dart';
export 'src/ffi_monero_backend.dart';
export 'src/height_by_date.dart';
export 'src/monero_backend.dart';
export 'src/monero_wallet.dart';
export 'src/seed/bip39_legacy.dart';
