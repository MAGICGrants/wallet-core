// Classification of a connection address (node/LWS/electrum host:port) into the
// transport it implies — shared by the connection form and the asset screen so
// both label a connection the same way.

import 'package:wallet_infra/wallet_infra.dart' show isUnroutedOnion;

final ipAddressRegex = RegExp(
  r'(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}(?::\d{1,5})?$',
);
final domainAddressRegex = RegExp(
  r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(?::\d{1,5})?$',
);
final onionAddressRegex = RegExp(r'[a-z2-7]{56}.onion(:\d{1,5})?$');

/// Strips a leading `http(s)://` scheme and surrounding whitespace — connection
/// addresses are stored/entered as bare `host:port`.
String cleanConnectionAddress(String value) => value.trim().replaceAll(RegExp(r'https?:\/\/'), '');

/// A public (remote) IPv4 literal — an IP address that isn't in a private/LAN
/// range. These aren't allowed as a connection: use a domain (SSL) or a local
/// IP. Only IP literals are judged; domains and onion hosts are never "remote"
/// by this test.
bool isRemoteIp(String value) {
  final host = value.split(':').first;
  return ipAddressRegex.hasMatch(value) && !isLocalIp(host);
}

/// Whether [value] is a usable connection address: a well-formed IP / onion /
/// domain `host:port` that isn't a public IP literal.
bool isValidConnectionAddress(String value) {
  final connectionUrlRegex = RegExp(
    [ipAddressRegex.pattern, onionAddressRegex.pattern, domainAddressRegex.pattern].join('|'),
  );
  if (!connectionUrlRegex.hasMatch(value)) return false;
  return !isRemoteIp(value);
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
  final host = value.split(':').first;
  if (onionAddressRegex.hasMatch(value)) return false;
  if (ipAddressRegex.hasMatch(value)) return false;
  if (host.endsWith('.local')) return false;
  return domainAddressRegex.hasMatch(value);
}

/// The transport a scheme-stripped address implies, for the "removing protocol"
/// notice. Onion is HTTP over Tor — checked first so it isn't mislabelled local.
enum AddressProtocolHint { onion, secure, plain }

AddressProtocolHint addressProtocolHint(String value) {
  if (onionAddressRegex.hasMatch(value)) return AddressProtocolHint.onion;
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
    hadProtocol: RegExp(r'https?:\/\/').hasMatch(raw),
    isOnion: onionAddressRegex.hasMatch(cleaned),
    isRemoteIp: isRemoteIp(cleaned),
    protocolHint: addressProtocolHint(cleaned),
  );
}

/// Why a connection address is rejected before a test/save; each app maps it to
/// its own message.
enum ConnectionAddressError { remoteIp, localOverTor, onionNeedsTor }

/// Shared pre-test/pre-save address rules: no public IP, no local host over Tor,
/// no onion without a Tor/proxy route.
ConnectionAddressError? validateConnectionAddress({
  required String address,
  required bool useTor,
  required bool hasProxy,
}) {
  if (isRemoteIp(address)) return ConnectionAddressError.remoteIp;
  if (useTor && addressIsLocal(address)) return ConnectionAddressError.localOverTor;
  if (isUnroutedOnion(address, viaProxy: useTor || hasProxy)) {
    return ConnectionAddressError.onionNeedsTor;
  }
  return null;
}

/// True for a LAN address — a private IP or a `.local` host.
bool addressIsLocal(String value) {
  final host = value.split(':').first;
  if (ipAddressRegex.hasMatch(value)) return isLocalIp(host);
  return host.endsWith('.local');
}
