/// Shared design system: brand tokens/themes + pure UI primitives.
///
/// App-independent — no `wallet_domain` types. An app installs its palette via
/// `BrandColors.install(<palette>)` at startup, then consumes these primitives
/// through `brandLightTheme()`/`brandDarkTheme()`. Wallet-coupled widgets live
/// under `src/wallet/` and are exported from `wallet_ui.dart`.
library;

export 'src/design/brand.dart';
export 'src/design/action_button.dart';
export 'src/design/asset_row.dart';
export 'src/design/balance_text.dart';
export 'src/design/brand_button.dart';
export 'src/design/brand_card.dart';
export 'src/design/brand_screen_header.dart';
export 'src/design/brand_segmented.dart';
export 'src/design/brand_text_field.dart';
export 'src/design/coin_tile.dart';
export 'src/design/confirm_sheet.dart';
export 'src/design/fiat_controls.dart';
export 'src/design/fiat_modes_view.dart';
export 'src/design/icon_badge.dart';
export 'src/design/icon_circle_button.dart';
export 'src/design/mini_action_button.dart';
export 'src/design/mode_select_card.dart';
export 'src/design/radio_dot.dart';
export 'src/design/route_pill.dart';
export 'src/design/section_header.dart';
export 'src/design/settings_picker_sheets.dart';
export 'src/design/seed_grid.dart';
export 'src/design/settings_group.dart';
export 'src/design/share_anchor.dart';
export 'src/design/sheet.dart';
export 'src/design/status_pill.dart';
export 'src/design/step_dots.dart';
export 'src/design/toast.dart';
