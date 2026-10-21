import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

void main() {
  final onion = '${'a' * 56}.onion';

  group('analyzeAddressInput', () {
    test('onion over http: onion hint, strips scheme, needs Tor', () {
      final r = analyzeAddressInput('http://$onion:18089');
      expect(r.cleaned, '$onion:18089');
      expect(r.hadProtocol, isTrue);
      expect(r.isOnion, isTrue);
      expect(r.isRemoteIp, isFalse);
      expect(r.protocolHint, AddressProtocolHint.onion);
    });

    test('clearnet domain over https: secure hint', () {
      final r = analyzeAddressInput('https://node.example.com:18089');
      expect(r.hadProtocol, isTrue);
      expect(r.isOnion, isFalse);
      expect(r.protocolHint, AddressProtocolHint.secure);
    });

    test('local IP over http: plain hint, not remote', () {
      final r = analyzeAddressInput('http://192.168.1.10:18081');
      expect(r.protocolHint, AddressProtocolHint.plain);
      expect(r.isRemoteIp, isFalse);
    });

    test('public IP: flagged remote, no scheme', () {
      final r = analyzeAddressInput('8.8.8.8:18081');
      expect(r.hadProtocol, isFalse);
      expect(r.isRemoteIp, isTrue);
    });

    test('bare address: trimmed, no protocol notice', () {
      final r = analyzeAddressInput('  example.com  ');
      expect(r.cleaned, 'example.com');
      expect(r.hadProtocol, isFalse);
    });
  });

  group('validateConnectionAddress', () {
    test('public IP is rejected', () {
      expect(
        validateConnectionAddress(address: '8.8.8.8:18081', useTor: false, hasProxy: false),
        ConnectionAddressError.remoteIp,
      );
    });

    test('local host over Tor is rejected, but allowed without Tor', () {
      expect(
        validateConnectionAddress(address: '192.168.1.10:18081', useTor: true, hasProxy: false),
        ConnectionAddressError.localOverTor,
      );
      expect(
        validateConnectionAddress(address: '192.168.1.10:18081', useTor: false, hasProxy: false),
        isNull,
      );
    });

    test('onion needs a route: rejected bare, allowed via Tor or proxy', () {
      expect(
        validateConnectionAddress(address: '$onion:18089', useTor: false, hasProxy: false),
        ConnectionAddressError.onionNeedsTor,
      );
      expect(
        validateConnectionAddress(address: '$onion:18089', useTor: true, hasProxy: false),
        isNull,
      );
      expect(
        validateConnectionAddress(address: '$onion:18089', useTor: false, hasProxy: true),
        isNull,
      );
    });

    test('clearnet domain passes', () {
      expect(
        validateConnectionAddress(
          address: 'node.example.com:18089',
          useTor: false,
          hasProxy: false,
        ),
        isNull,
      );
    });
  });

  // A user whose server is on their tailnet types its Tailscale IP. It is a
  // network they control (WireGuard), not a public IP, so the form must take it.
  group('a Tailscale user', () {
    const tailscale = '100.101.102.103:18090';

    test('their Tailscale IP is accepted, as plain HTTP, not as a public IP', () {
      final r = analyzeAddressInput('http://$tailscale');
      expect(r.cleaned, tailscale);
      expect(r.isRemoteIp, isFalse);
      expect(r.protocolHint, AddressProtocolHint.plain);
      expect(addressUsesSsl(tailscale), isFalse);
    });

    test('it saves without Tor, and is refused with Tor like any local host', () {
      expect(validateConnectionAddress(address: tailscale, useTor: false, hasProxy: false), isNull);
      expect(
        validateConnectionAddress(address: tailscale, useTor: true, hasProxy: false),
        ConnectionAddressError.localOverTor,
      );
    });

    test('an address just outside the Tailscale range is a public IP', () {
      for (final address in ['100.63.255.255:18090', '100.128.0.1:18090']) {
        expect(isRemoteIp(address), isTrue, reason: address);
        expect(
          validateConnectionAddress(address: address, useTor: false, hasProxy: false),
          ConnectionAddressError.remoteIp,
          reason: address,
        );
      }
    });
  });

  // A server's QR code may carry a path after host:port: a node or light-wallet
  // server behind a reverse proxy at `/wallet`, an RPC endpoint's `/v3/...`.
  // The path is the server's business; every rule judges the host alone.
  group('addresses with a path (QR codes)', () {
    test('a path is allowed after any kind of host, where the connection uses one', () {
      for (final address in [
        'node.example.com:18081/wallet',
        'node.example.com/wallet',
        'lws.example.com:443/some/deeper/path',
        '$onion:8444/wallet',
        '192.168.1.5:18081/wallet',
        '100.101.102.103:18090/wallet',
        'rpc.example.com/v3/abc123?network=mainnet',
      ]) {
        expect(
          validateConnectionAddress(
            address: address,
            useTor: isOnionAddress(address),
            hasProxy: false,
          ),
          isNull,
          reason: address,
        );
        expect(splitConnectionAddress(address)?.path, isNotEmpty, reason: address);
      }
    });

    test('a scanned URL is cleaned to host:port/path', () {
      expect(
        cleanConnectionAddress(' https://node.example.com:443/wallet/ '),
        'node.example.com:443/wallet',
      );
      expect(cleanConnectionAddress('HTTP://node.example.com/wallet'), 'node.example.com/wallet');
      // Only the leading scheme goes; a path may contain one.
      expect(
        cleanConnectionAddress('node.example.com/redirect/http://x'),
        'node.example.com/redirect/http://x',
      );
    });

    test('the parts come apart: host, port, path', () {
      final parts = splitConnectionAddress('node.example.com:18081/wallet')!;
      expect(parts.host, 'node.example.com');
      expect(parts.port, 18081);
      expect(parts.path, '/wallet');
      expect(splitConnectionAddress('node.example.com:18081')!.path, isEmpty);
    });

    test('a public IP is still refused, path or not', () {
      for (final address in ['8.8.8.8:18081/wallet', '8.8.8.8/wallet']) {
        expect(isRemoteIp(address), isTrue, reason: address);
        expect(
          validateConnectionAddress(address: address, useTor: false, hasProxy: false),
          ConnectionAddressError.remoteIp,
          reason: address,
        );
      }
    });

    test('an onion with a path is still an onion: Tor is turned on for it', () {
      final r = analyzeAddressInput('http://$onion:8444/wallet');
      expect(r.cleaned, '$onion:8444/wallet');
      expect(r.isOnion, isTrue);
      expect(r.protocolHint, AddressProtocolHint.onion);
      expect(
        validateConnectionAddress(address: r.cleaned, useTor: false, hasProxy: false),
        ConnectionAddressError.onionNeedsTor,
      );
    });

    test('a local host with a path is still local, and a domain still speaks https', () {
      expect(addressIsLocal('192.168.1.5:18081/wallet'), isTrue);
      expect(
        validateConnectionAddress(
          address: '192.168.1.5:18081/wallet',
          useTor: true,
          hasProxy: false,
        ),
        ConnectionAddressError.localOverTor,
      );
      expect(addressUsesSsl('node.example.com/wallet'), isTrue);
      expect(addressUsesSsl('192.168.1.5:18081/wallet'), isFalse);
    });

    test('a connection that cannot use a path refuses one, and only then', () {
      // A Monero node (wallet2 drops the path) or an Electrum server (raw TCP).
      expect(
        validateConnectionAddress(
          address: 'node.example.com:18081/wallet',
          useTor: false,
          hasProxy: false,
          allowPath: false,
        ),
        ConnectionAddressError.pathNotSupported,
      );
      expect(
        validateConnectionAddress(
          address: 'node.example.com:18081',
          useTor: false,
          hasProxy: false,
          allowPath: false,
        ),
        isNull,
      );
    });
  });
}
