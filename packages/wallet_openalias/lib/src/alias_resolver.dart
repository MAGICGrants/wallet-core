import 'package:wallet_domain/wallet_domain.dart';

import 'openalias_ffi.dart';
import 'openalias_records.dart';

/// `wallet_domain`'s [AliasResolver], backed by this package's DNSSEC-over-Tor
/// resolver.
///
/// Install it once, from the app's `main()`:
///
/// ```dart
/// CryptoWallet.aliasResolver = resolveOpenAlias;
/// ```
///
/// ## What this does and does not decide
///
/// It decides which record to pay; the compatibility rule and priority
/// ordering, in [resolveFromLookups], and nothing about whether the answer is
/// safe. `CryptoWallet.resolveAlias` bounds every field, validates addresses
/// against the coin, and strips hostile display text.
///
/// So values pass through here verbatim, hostile or not.
///
/// ## Never null
///
/// The signature permits null, but this resolver always returns a record or
/// throws. A DNSSEC failure must propagate rather than read as "nothing here",
/// so anything that is not an answer is raised.
Future<ResolvedAlias?> resolveOpenAlias({
  required String alias,
  required String network,
  required String asset,
  required int socksPort,
  String? nativeAsset,
}) async {
  final result = await OpenAliasFfi.resolve(
    alias: alias,
    network: network,
    asset: asset,
    socksPort: socksPort,
    nativeAsset: nativeAsset,
  );

  return resolvedAliasFrom(result);
}

/// Flattens an [OpenAliasResult] into the wallet layer's [ResolvedAlias].
///
/// Public because it is the whole non-native half of [resolveOpenAlias]: split
/// out, the mapping can be tested against records built by hand, with no DNS and
/// no dylib. Everything this package does except the lookup itself is then
/// covered by `flutter test`.
///
/// The alternatives are the other records this wallet could pay, in the
/// recipient's stated priority order. They arrive flat and stay flat; an
/// alternative has no alternatives of its own, which is also what stops a
/// recursive record set from smuggling a second tier past validation.
ResolvedAlias resolvedAliasFrom(OpenAliasResult result) {
  final metadata = result.metadata;
  return _payment(result.payment, metadata).withAlternatives([
    for (final alternative in result.alternatives) _payment(alternative, metadata),
  ]);
}

ResolvedAlias _payment(OpenAliasPayment payment, Map<String, String>? metadata) => ResolvedAlias(
  address: payment.address,
  // v1 publishes the name on the payment record itself; v2 moves it to the
  // separate metadata record, so one of the two is always null.
  recipientName: metadata?['name'] ?? payment.recipientName,
  description: payment.description ?? metadata?['description'],
  // An exact decimal string, never parsed to a double here; the send path
  // converts it with `decimalToBaseUnits`.
  requestedAmount: payment.amount,
  memo: payment.memo,
);
