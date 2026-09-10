/// Fiat exchange-rate model shared by the apps: per-coin Kraken rates fetched
/// over Tor or clearnet, with the USD bridge for currencies Kraken doesn't quote
/// directly. Multicoin; an app with one coin is the degenerate case.
///
/// Kept separate so an app that shows no fiat price doesn't pull it in. The app
/// supplies the Tor proxy through [FiatRates.install]; this package does not own
/// Tor, because apps already run their own.
library;

export 'src/fiat_rate_model.dart';
