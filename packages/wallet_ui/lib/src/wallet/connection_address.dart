// Classification of a connection address (node/LWS/electrum host:port) into the
// transport it implies — shared by the connection form and the asset screen so
// both label a connection the same way.

import 'package:wallet_infra/wallet_infra.dart' show isUnroutedOnion;

// Host shapes, matched against a whole host: no port, no path.
final _ipHost = RegExp(
  r'^(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}$',
);
final _domainHost = RegExp(r'^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$');
final _onionHost = RegExp(r'^(?:[a-z0-9-]+\.)*[a-z2-7]{56}\.onion$');

/// Strips a leading `http(s)://` scheme, trailing slashes and surrounding
/// whitespace; connection addresses are stored/entered as `host:port`, with an
/// optional path after it (a server behind a reverse proxy at `/wallet`, an RPC
/// endpoint's `/v3/...`).
///
/// Only a *leading* scheme goes: a path may itself contain `http://`.
String cleanConnectionAddress(String value) => value
    .trim()
    .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
    .replaceFirst(RegExp(r'/+$'), '');

/// A scheme-stripped connection address split into its parts: the host, an
/// optional port, and an optional path (with any query) after them. Null when
/// [value] is not shaped like one at all.
///
/// Every rule below judges the host alone. Matching the raw string instead let
/// a path change the answer: `8.8.8.8:18081/wallet` no longer looked like an IP
/// literal, so it would have slipped past the "no public IP" rule. Whether a
/// path is allowed at all is the connection's call ([validateConnectionAddress]).
({String host, int? port, String path})? splitConnectionAddress(String value) {
  final uri = Uri.tryParse('http://$value');
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  return (host: uri.host, port: uri.hasPort ? uri.port : null, path: path);
}

/// The host of a connection address, or the text before its first `:` when it
/// does not parse (so a malformed value is judged, not ignored).
String _hostOf(String value) => splitConnectionAddress(value)?.host ?? value.split(':').first;

/// Whether [value]'s host is a v3 onion service (or a subdomain of one).
bool isOnionAddress(String value) => _onionHost.hasMatch(_hostOf(value));

/// A public (remote) IPv4 literal — an IP address that isn't in a private/LAN
/// range. These aren't allowed as a connection: use a domain (SSL) or a local
/// IP. Only IP literals are judged; domains and onion hosts are never "remote"
/// by this test.
bool isRemoteIp(String value) {
  final host = _hostOf(value);
  return _ipHost.hasMatch(host) && !isLocalIp(host);
}

/// A private/LAN IPv4 host (RFC 1918 ranges + loopback), or one in the RFC 6598
/// shared space (100.64/10) that Tailscale-style VPNs assign from. Keep in step
/// with `isLocalHost` in wallet_infra, which gates what may be sent in plaintext.
bool isLocalIp(String host) {
  if (host.startsWith('192.168.') || host.startsWith('10.') || host.startsWith('127.')) {
    return true;
  }
  final match = RegExp(r'^172\.(\d{1,3})\.').firstMatch(host);
  if (match != null) {
    final second = int.tryParse(match.group(1)!) ?? 0;
    return second >= 16 && second <= 31;
  }
  final shared = RegExp(r'^100\.(\d{1,3})\.').firstMatch(host);
  if (shared != null) {
    final second = int.tryParse(shared.group(1)!) ?? 0;
    return second >= 64 && second <= 127;
  }
  return false;
}

/// True when the address is a clearnet domain — the only case that speaks HTTPS.
/// Onion, IP and `.local` hosts do not.
bool addressUsesSsl(String value) {
  final host = _hostOf(value);
  if (_onionHost.hasMatch(host)) return false;
  if (_ipHost.hasMatch(host)) return false;
  if (host.endsWith('.local')) return false;
  return _domainHost.hasMatch(host);
}

/// The transport a scheme-stripped address implies, for the "removing protocol"
/// notice. Onion is HTTP over Tor — checked first so it isn't mislabelled local.
enum AddressProtocolHint { onion, secure, plain }

AddressProtocolHint addressProtocolHint(String value) {
  if (isOnionAddress(value)) return AddressProtocolHint.onion;
  if (addressUsesSsl(value)) return AddressProtocolHint.secure;
  return AddressProtocolHint.plain;
}

/// Pure analysis of a raw connection-address input, shared by both apps' forms.
class AddressInput {
  final String cleaned;
  final bool hadProtocol;
  final bool isOnion;
  final bool isRemoteIp;
  final AddressProtocolHint protocolHint;

  const AddressInput({
    required this.cleaned,
    required this.hadProtocol,
    required this.isOnion,
    required this.isRemoteIp,
    required this.protocolHint,
  });
}

AddressInput analyzeAddressInput(String raw) {
  final cleaned = cleanConnectionAddress(raw);
  return AddressInput(
    cleaned: cleaned,
    hadProtocol: RegExp(r'^\s*https?://', caseSensitive: false).hasMatch(raw),
    isOnion: isOnionAddress(cleaned),
    isRemoteIp: isRemoteIp(cleaned),
    protocolHint: addressProtocolHint(cleaned),
  );
}

/// Why a connection address is rejected before a test/save; each app maps it to
/// its own message.
enum ConnectionAddressError { remoteIp, pathNotSupported, localOverTor, onionNeedsTor }

/// Shared pre-test/pre-save address rules: no public IP, no path where the
/// connection cannot use one ([allowPath], the wallet's
/// `connectionAllowsPath`), no local host over Tor, no onion without a
/// Tor/proxy route.
ConnectionAddressError? validateConnectionAddress({
  required String address,
  required bool useTor,
  required bool hasProxy,
  bool allowPath = true,
}) {
  if (isRemoteIp(address)) return ConnectionAddressError.remoteIp;
  if (!allowPath && (splitConnectionAddress(address)?.path.isNotEmpty ?? false)) {
    return ConnectionAddressError.pathNotSupported;
  }
  if (useTor && addressIsLocal(address)) return ConnectionAddressError.localOverTor;
  if (isUnroutedOnion(address, viaProxy: useTor || hasProxy)) {
    return ConnectionAddressError.onionNeedsTor;
  }
  return null;
}

/// True for a LAN address — a private IP or a `.local` host.
bool addressIsLocal(String value) {
  final host = _hostOf(value);
  if (_ipHost.hasMatch(host)) return isLocalIp(host);
  return host.endsWith('.local');
}
