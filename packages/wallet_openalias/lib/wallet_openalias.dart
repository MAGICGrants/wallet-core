/// OpenAlias v1 and v2 resolution, DNSSEC-validated end to end and routed over
/// Tor, behind `wallet_domain`'s injected [AliasResolver].
///
/// Kept separate because the resolver is a Rust build, and putting it in
/// `wallet_domain` would drag a Rust toolchain into every consumer of the wallet
/// layer. Resolution policy stays on `CryptoWallet`; the app installs this
/// through the `AliasResolver` seam.
///
/// Not monero_c's own resolver: its DNS goes out directly, leaking the
/// recipient's domain at the moment of payment, and it is v1-only and
/// Monero-only.
///
/// ```dart
/// CryptoWallet.aliasResolver = resolveOpenAlias;
/// ```
///
/// ## Layers
///
/// | | |
/// | --- | --- |
/// | `rust/` | the only part that has to be trusted: fetches TXT records over the Tor SOCKS proxy and refuses anything not DNSSEC-secure |
/// | `src/openalias_records.dart` | the v1/v2 grammar and record selection; pure Dart, no FFI, so it is testable without a native build |
/// | `src/alias_resolver.dart` | adapts the result to `wallet_domain`'s `ResolvedAlias` |
///
/// The FFI surface returns records rather than an address, so everything above
/// it is unit-testable.
///
/// ## The native library keeps its own name
///
/// The Dart package is `wallet_openalias`; the Rust crate and its built library
/// are `openalias_ffi`. Flutter requires the plugin to match the package name,
/// while `DynamicLibrary.open()` asks for the crate name. Both are correct.
library;

export 'src/alias_resolver.dart';
export 'src/openalias_ffi.dart';
export 'src/openalias_records.dart';
