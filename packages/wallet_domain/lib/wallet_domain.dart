/// Coin-agnostic wallet domain shared by Skylight Wallet and Spice Wallet.
///
/// Layering: `wallet_infra` (transport/storage/logging) <- `wallet_domain`
/// (this package) <- `wallet_monero` and future per-coin packages <- the apps.

library;

export 'src/alias.dart';
export 'src/amounts.dart';
export 'src/app_config.dart';
export 'src/background_sync_mode.dart';
export 'src/crypto_wallet.dart';
export 'src/seed/restore_qr.dart';
export 'src/seed/seed.dart';
export 'src/seed/seed_policy.dart';
export 'src/stores/seed_store.dart';
export 'src/stores/tx_notification_store.dart';
export 'src/stores/wallet_cache_store.dart';
export 'src/tx/broadcast_outcome.dart';
export 'src/tx/fee_share.dart';
export 'src/tx/tx_details.dart';
export 'src/tx/tx_notifications.dart';
export 'src/wallet_manager.dart';
