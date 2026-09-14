import 'dart:io' show InternetAddress, InternetAddressType;

/// How a destination protects what is sent to it.
///
/// The question is "may this request carry a secret", not "should we do a TLS
/// handshake". Three plaintext cases the URL scheme cannot tell apart:
///
///   - `http://` to a `.onion` *carried inside Tor*: fine; the address is the
///     key and there is no exit node in the path. Outside Tor the same URL is
///     an ordinary plaintext request, so the route has to be passed in;
///   - `http://` to loopback or LAN: fine; the bytes never leave;
///   - `http://` to a routable host through Tor: unsafe; an exit node the user
///     did not choose reads and can rewrite every byte.
///
/// Only the third is unsafe, so "just require https" is the wrong fix: it breaks
/// the other two and pushes users off onion services. [classifyEndpoint] draws
/// the distinction, [requireConfidentialChannel] enforces it.
enum ChannelConfidentiality {
  /// TLS to the endpoint: confidential, and authenticated by a certificate.
  tls,

  /// A Tor onion service, reached through Tor: confidential and authenticated
  /// end-to-end by the address itself, because the `.onion` name is derived
  /// from the service's public key. Plaintext HTTP inside the circuit is not
  /// exposed to an exit, because there is no exit.
  ///
  /// Only ever returned when the caller says the request travels inside Tor.
  /// The protection comes from the circuit, not from the spelling of the host.
  ///
  /// Never describe this to a user as "TLS" or "SSL". No certificate is
  /// involved and no CA vouches for it; the guarantee has a different shape.
  onion,

  /// Loopback, or a private/link-local address. An on-path attacker here is
  /// already inside the host or the LAN.
  local,

  /// Plaintext to a routable host. Readable and rewritable by anyone on the
  /// path, and when the request is proxied through Tor, that is an arbitrary
  /// exit node.
  none;

  /// Whether bytes sent over this channel are protected from an on-path
  /// observer. The single question a caller holding a secret needs answered.
  bool get isConfidential => this != ChannelConfidentiality.none;
}

/// Classifies [uri]'s destination.
///
/// Fails closed: an unparseable or schemeless URI classifies as
/// [ChannelConfidentiality.none]. That matters because connection addresses are
/// stored in this repo as a bare `host:port`; `Uri.parse('example.com:18090')`
/// puts `example.com` in `scheme` and leaves `host` empty, so a caller that
/// forgot to prepend a scheme must be refused rather than waved through.
/// [viaTor] must say whether this request will actually be carried inside Tor.
/// It is required, not defaulted, because the answer cannot be derived from
/// [uri]: an onion address is confidential because of the circuit it travels
/// in, and a caller that does not route through Tor gets no protection from
/// the hostname alone. Defaulting it either way would let a call site inherit
/// a guarantee it never checked.
ChannelConfidentiality classifyEndpoint(Uri uri, {required bool viaTor}) {
  if (uri.host.isEmpty) return ChannelConfidentiality.none;

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https' || scheme == 'wss') return ChannelConfidentiality.tls;

  // Route first, then host. Without Tor this is a plaintext request whose
  // hostname goes to the system resolver: it normally fails to resolve, but a
  // resolver that answers anyway (ISP redirect pages, captive portals) points
  // it at a stranger, and the query alone reveals which service was wanted.
  if (viaTor && isOnionHost(uri.host)) return ChannelConfidentiality.onion;

  if (isLocalHost(uri.host)) return ChannelConfidentiality.local;

  return ChannelConfidentiality.none;
}

/// Thrown when a request carrying key material would go out over a channel that
/// does not protect it.
///
/// [carrying] names *what kind* of secret was about to be sent, never the value.
/// The endpoint is the user's own configuration and is already logged verbatim
/// on this path, so naming it here adds no disclosure and makes the error
/// actionable.
class InsecureChannelException implements Exception {
  const InsecureChannelException({required this.endpoint, required this.carrying});

  /// Scheme, host and port only; never the path or query, which can carry
  /// parameters this exception has no business repeating.
  final String endpoint;

  /// Human-readable description of the secret, e.g. "the private view key".
  final String carrying;

  @override
  String toString() =>
      'InsecureChannelException: refusing to send $carrying to $endpoint over an '
      'unauthenticated plaintext channel. Enable SSL for this endpoint, use its '
      'onion address *with Tor enabled*, or point it at a host on your own '
      'network.';
}

/// Throws [InsecureChannelException] unless [uri] protects what is sent to it.
///
/// Call this *before* reading the secret out of wherever it lives, so a refused
/// request never materialises the value at all.
void requireConfidentialChannel(Uri uri, {required String carrying, required bool viaTor}) {
  if (classifyEndpoint(uri, viaTor: viaTor).isConfidential) return;
  final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  throw InsecureChannelException(endpoint: '${uri.scheme}://$authority', carrying: carrying);
}

/// Whether a connection to [host] must use a secure transport (TLS for a raw
/// socket, `https`/`wss` for a URL).
///
/// There is no `useSsl` toggle. A routable clearnet host is forced secure; the
/// two already-confidential cases are left alone:
///
///  - **`.onion`**: the circuit is encrypted and authenticated to the address's
///    own key. Forcing TLS would only fail against the plaintext port onion
///    services actually run.
///  - **local / LAN**: the bytes never reach a routable network.
///
/// So this is the inverse of "confidential", minus the TLS case: a caller uses it
/// to *decide* whether to speak TLS, where [requireConfidentialChannel] is used
/// to *reject* a URL that already committed to plaintext. Onion and local return
/// false (plaintext is fine); everything else returns true.
bool requiresSecureTransport(String host) => !(isOnionHost(host) || isLocalHost(host));

/// Whether [host] is a Tor onion service.
///
/// The label before `.onion` must be a real onion address; 56 base32
/// characters for v3, or 16 for the retired v2; so that a typo like
/// `myserver.onion` is not silently promoted to "confidential". Tor itself
/// applies the same shape rule, so nothing that would actually connect is
/// rejected here.
bool isOnionHost(String host) {
  final h = _canonicalHost(host);
  if (!h.endsWith('.onion')) return false;
  final label = h.substring(0, h.length - '.onion'.length).split('.').last;
  if (label.length != 56 && label.length != 16) return false;
  return RegExp(r'^[a-z2-7]+$').hasMatch(label);
}

/// Whether [host] names this machine or a network the user controls.
bool isLocalHost(String host) {
  final h = _canonicalHost(host);
  if (h == 'localhost' || h == 'ip6-localhost' || h == 'ip6-loopback') return true;
  // RFC 6761 §6.3 reserves `.localhost` to the loopback interface.
  if (h.endsWith('.localhost')) return true;
  // RFC 6762 reserves `.local` to mDNS on the local link; a LAN name (a
  // self-hosted node advertised over Bonjour/Avahi), so the bytes never reach a
  // routable network. Treated like an RFC 1918 address below; forcing TLS here
  // would break the plaintext port such a node actually serves.
  if (h.endsWith('.local')) return true;

  final addr = _parseAddress(h);
  if (addr == null) return false;
  if (addr.isLoopback || addr.isLinkLocal) return true;

  final bytes = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4) {
    // RFC 1918 only. Deliberately **not** 100.64/10 (CGNAT): that range is
    // routed inside a carrier's network and shared with its other subscribers,
    // so it is not "never left my LAN" in any sense that protects a view key.
    if (bytes[0] == 10) return true;
    if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
    if (bytes[0] == 192 && bytes[1] == 168) return true;
    return false;
  }
  // IPv6 unique-local, fc00::/7.
  return (bytes[0] & 0xfe) == 0xfc;
}

/// Lowercased, with the root label's trailing dot and any IPv6 brackets removed.
///
/// `Uri.host` already strips brackets, but this is public API and a caller may
/// hand over a raw header value.
String _canonicalHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  return h;
}

/// Parses [host] as an IP literal, resolving IPv4-mapped IPv6 to its IPv4 form.
///
/// Without the unwrap, `::ffff:192.168.1.10` would miss the RFC 1918 test below
/// and classify as `none`. That is the safe direction, but it would refuse a
/// request that was in fact fine, so handle it properly.
InternetAddress? _parseAddress(String host) {
  final addr = InternetAddress.tryParse(host);
  if (addr == null) return null;
  if (addr.type != InternetAddressType.IPv6) return addr;

  final b = addr.rawAddress;
  final isV4Mapped = b.take(10).every((byte) => byte == 0) && b[10] == 0xff && b[11] == 0xff;
  if (!isV4Mapped) return addr;
  return InternetAddress.tryParse('${b[12]}.${b[13]}.${b[14]}.${b[15]}');
}
