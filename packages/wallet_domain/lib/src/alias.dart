/// Alias resolution (OpenAlias v1 and v2), as the wallet layer sees it.
///
/// **Coin-agnostic.** Both OpenAlias versions carry a network and an asset, and
/// aliases resolve for Bitcoin and Ethereum as well as Monero. Hence one
/// resolver on `CryptoWallet` rather than one per chain.
///
/// **Resolution must happen outside monero_c.** Its path is v1-only, Monero-only,
/// and sends DNS out directly; leaking the recipient's domain at the moment of
/// payment. Resolution goes through a DNSSEC-validating resolver over Tor
/// instead.
///
/// The resolver is injected, and these types are the boundary. It lives in
/// `wallet_openalias`; the app installs it.
library;

/// A payable record resolved from an alias.
///
/// Carries more than an address on purpose. OA2 records can name the recipient
/// and describe the payment, and showing that back to the user before they
/// confirm is the main defence against a lookalike alias; dropping it to a
/// bare address, as a v1-shaped interface would, throws away the one thing that
/// makes an alias safer to use than a pasted address.
class ResolvedAlias {
  const ResolvedAlias({
    required this.address,
    this.recipientName,
    this.description,
    this.requestedAmount,
    this.memo,
    this.alternatives = const [],
  });

  final String address;

  /// Recipient name as published in the record. Display only; it is asserted
  /// by the recipient's DNS, so it proves control of the domain and nothing
  /// more. Never present it as verified identity.
  final String? recipientName;

  final String? description;

  /// Amount the record asks for, as an exact decimal string. Never a double;
  /// the send path parses it with `decimalToBaseUnits`.
  final String? requestedAmount;

  final String? memo;

  /// Other records this wallet could also pay, when the alias published more
  /// than one usable option.
  ///
  /// Flat, matching the resolver's own shape; an alternative has no
  /// alternatives of its own.
  final List<ResolvedAlias> alternatives;

  /// The same record with a different [alternatives] list.
  ///
  /// Exists for one caller: `CryptoWallet.resolveAlias`, which drops the
  /// alternatives this coin cannot pay. Named rather than a general `copyWith`
  /// so it cannot quietly be used to rewrite an address.
  ResolvedAlias withAlternatives(List<ResolvedAlias> alternatives) => ResolvedAlias(
    address: address,
    recipientName: recipientName,
    description: description,
    requestedAmount: requestedAmount,
    memo: memo,
    alternatives: alternatives,
  );
}

/// Bounds on everything a resolver hands back.
///
/// Every field of a [ResolvedAlias] is published by the **counterparty's DNS**.
/// It reaches this process through a native resolver that applies no size limit
/// of its own; the plugin's job is to prove the answer is DNSSEC-secure, not to
/// decide it is reasonable; so these are the first bounds the data meets.
///
/// The limits are deliberately far above any real record and far below anything
/// that hurts: the longest Monero address is a 106-character integrated one, and
/// no legitimate publisher needs a kilobyte of recipient name.
abstract final class AliasLimits {
  /// Comfortably past a Monero integrated address (106) and a Bech32m address.
  static const int maxAddressLength = 256;

  /// `recipientName`, `description`, `memo`.
  static const int maxDisplayTextLength = 256;

  /// `requestedAmount`. It is parsed into a `BigInt`, and parsing a very long
  /// digit string is superlinear; a megabyte of digits is a hang, not a value.
  static const int maxAmountLength = 64;

  /// A picker the user chooses from. A record set larger than this is not a
  /// generous publisher.
  static const int maxAlternatives = 16;
}

/// Characters that must never reach a screen where someone is deciding whether
/// to send money.
///
/// C0/C1 controls and the line separators break a confirmation dialog's layout;
/// the bidi overrides and isolates (U+202A–U+202E, U+2066–U+2069) **reorder what
/// is rendered**, so a name can display as something other than what it is; and
/// the zero-width characters hide content inside an otherwise ordinary-looking
/// string. None of them has a legitimate place in a payment record.
final RegExp _unsafeForDisplay = RegExp(
  '['
  '\u0000-\u001F' // C0 controls, including NUL, CR and LF
  '\u007F-\u009F' // DEL and the C1 controls
  '\u200B-\u200F' // zero-width space and joiners, LRM/RLM
  '\u2028\u2029' // line and paragraph separators
  '\u202A-\u202E' // bidi embeddings and overrides
  '\u2066-\u2069' // bidi isolates
  '\uFEFF' // zero-width no-break space / BOM
  ']',
);

/// Returns [value] when it is safe to display, and null otherwise.
///
/// **Dropped, never truncated or stripped.** A name cut in half or with its
/// direction marks removed is still a name the publisher chose the shape of,
/// and showing a mangled version of it is worse than showing none; the user
/// reads whatever is on screen as the recipient's own words.
String? safeAliasText(String? value, {int maxLength = AliasLimits.maxDisplayTextLength}) {
  if (value == null) return null;
  if (value.isEmpty || value.length > maxLength) return null;
  if (_unsafeForDisplay.hasMatch(value)) return null;
  return value;
}

/// Whether [address] is worth handing to a coin's own validator.
///
/// A cheap pre-check, not a substitute: the per-coin validator is the real one.
/// This exists because that validator is a subclass's regex applied to a string
/// of unbounded length from an untrusted source, and a coin whose check is
/// permissive, or quadratic, should not be the only thing standing between a
/// hostile record and the send screen.
bool aliasAddressWithinBounds(String address) =>
    address.isNotEmpty &&
    address.length <= AliasLimits.maxAddressLength &&
    !_unsafeForDisplay.hasMatch(address);

/// Thrown when the input is a raw address rather than an alias.
///
/// Distinct from a resolution failure: the send screen should quietly treat the
/// input as an address, not show the user a DNS error for something they typed
/// correctly.
class NotAnAliasException implements Exception {
  const NotAnAliasException(this.input);

  final String input;

  @override
  String toString() => 'NotAnAliasException: "$input" is an address, not an alias';
}

/// Resolves [alias], an FQDN or an email-style `name@domain`, to a payable
/// record, over Tor, requiring a DNSSEC-secure answer.
///
/// [network] and [asset] say what the caller can pay; [nativeAsset] is that
/// network's native asset per the OA2 network list, which is what a v2 record
/// omitting `asset` denotes. All three are separate because OA2 separates them;
/// collapsing them into one "asset" string is a v1 assumption that does not
/// survive contact with the spec.
///
/// Returns null when the alias publishes nothing this wallet can pay. Throws
/// [NotAnAliasException] for a raw address, and any other exception when
/// resolution fails, including when Tor is unavailable, which must never
/// degrade to an unproxied lookup.
typedef AliasResolver =
    Future<ResolvedAlias?> Function({
      required String alias,
      required String network,
      required String asset,
      required int socksPort,
      String? nativeAsset,
    });
