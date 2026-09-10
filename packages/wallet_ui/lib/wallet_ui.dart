/// Shared Flutter widgets built on the wallet engine.
///
/// Kept separate so `wallet_infra` and `wallet_domain` stay Material-free, and
/// so an app that doesn't want these widgets doesn't compile them.
///
/// Widgets carry no localization. The app passes its own translated strings in
/// (e.g. [TxDetailsLabels]) instead of the package depending on app l10n.
library;

export 'design.dart';
export 'src/export_logs_dialog.dart';

// Onboarding views — presentational (injected labels + callbacks).
export 'src/onboarding/create_password_view.dart';
export 'src/onboarding/create_wallet_view.dart';
export 'src/onboarding/fiat_setup_view.dart';
export 'src/onboarding/generate_seed_view.dart';
export 'src/onboarding/restore_wallet_view.dart';
export 'src/onboarding/scan_from_card.dart';
export 'src/onboarding/scan_qr_view.dart';
export 'src/onboarding/tor_choice_view.dart';
export 'src/onboarding/unlock_view.dart';
export 'src/onboarding/welcome_view.dart';

// Wallet-coupled widgets (depend on wallet_domain / wallet_fiat).
export 'src/wallet/coin_badge.dart';
export 'src/wallet/coin_mark.dart';
export 'src/wallet/confirm_send_view.dart';
export 'src/wallet/connection_address.dart';
export 'src/wallet/connection_form.dart';
export 'src/wallet/contact_picker_sheet.dart';
export 'src/wallet/connection_pills.dart';
export 'src/wallet/format.dart';
export 'src/wallet/key_reveal_view.dart';
export 'src/wallet/lws_keys_view.dart';
export 'src/wallet/receive_view.dart';
export 'src/wallet/send_view.dart';
export 'src/wallet/tx_activity_row.dart';
export 'src/wallet/tx_details_sheet.dart';
