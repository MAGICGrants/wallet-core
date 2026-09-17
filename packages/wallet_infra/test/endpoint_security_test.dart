import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The three plaintext cases the old `uri.scheme == 'https'` test could not
/// tell apart are the reason this file exists, so each has its own group. The
/// property under test is not "is this https"; it is "may a secret cross this".
void main() {
  group('TLS', () {
    test('https is confidential', () {
      expect(
        classifyEndpoint(Uri.parse('http://example.com'), viaTor: true),
        ChannelConfidentiality.none,
      );
      expect(
        classifyEndpoint(Uri.parse('https://example.com'), viaTor: true),
        ChannelConfidentiality.tls,
      );
      expect(
        classifyEndpoint(Uri.parse('HTTPS://example.com'), viaTor: true),
        ChannelConfidentiality.tls,
      );
      expect(
        classifyEndpoint(Uri.parse('wss://example.com'), viaTor: true),
        ChannelConfidentiality.tls,
      );
    });
  });

  group('onion', () {
    // A v3 address is 56 base32 characters. Content is irrelevant to the shape
    // check, so this is 'a' * 51 + '234567': valid base32, right length.
    const v3 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa234567';
    const v2 = 'abcdefghij234567';

    test('plaintext to a v3 onion is confidential', () {
      expect(v3.length, 56);
      expect(
        classifyEndpoint(Uri.parse('http://$v3.onion:18090'), viaTor: true),
        ChannelConfidentiality.onion,
      );
      expect(
        classifyEndpoint(Uri.parse('http://$v3.onion'), viaTor: true),
        ChannelConfidentiality.onion,
      );
    });

    test('the retired v2 shape still classifies', () {
      expect(v2.length, 16);
      expect(
        classifyEndpoint(Uri.parse('http://$v2.onion'), viaTor: true),
        ChannelConfidentiality.onion,
      );
    });

    test('a subdomain of an onion is still that onion service', () {
      expect(
        classifyEndpoint(Uri.parse('http://sub.$v3.onion'), viaTor: true),
        ChannelConfidentiality.onion,
      );
    });

    test('a trailing root dot does not defeat the match', () {
      expect(
        classifyEndpoint(Uri.parse('http://$v3.onion./x'), viaTor: true),
        ChannelConfidentiality.onion,
      );
    });

    test('an onion reached WITHOUT Tor is not confidential', () {
      // The hole this parameter closes. An onion address can be saved with Tor
      // off -- the connection form forces `useTor` false when Tor is globally
      // disabled -- and the old hostname-only test then waved the view-key
      // upload through onto an unproxied plaintext socket.
      expect(
        classifyEndpoint(Uri.parse('http://$v3.onion:18090'), viaTor: false),
        ChannelConfidentiality.none,
      );
      expect(
        () => requireConfidentialChannel(
          Uri.parse('http://$v3.onion:18090/upsert_subaddrs'),
          carrying: 'the private view key',
          viaTor: false,
        ),
        throwsA(isA<InsecureChannelException>()),
      );
    });

    test('the route does not rescue a plaintext clearnet host', () {
      // The converse, so the parameter cannot be read as "Tor makes it safe":
      // Tor to a routable host still terminates at an exit node that reads and
      // can rewrite everything.
      expect(
        classifyEndpoint(Uri.parse('http://lws.example.com'), viaTor: true),
        ChannelConfidentiality.none,
      );
    });

    test('https and local stay confidential regardless of route', () {
      for (final viaTor in [true, false]) {
        expect(
          classifyEndpoint(Uri.parse('https://example.com'), viaTor: viaTor),
          ChannelConfidentiality.tls,
          reason: 'viaTor: $viaTor',
        );
        expect(
          classifyEndpoint(Uri.parse('http://192.168.1.10:18090'), viaTor: viaTor),
          ChannelConfidentiality.local,
          reason: 'viaTor: $viaTor',
        );
      }
    });

    test('a mistyped onion is NOT promoted to confidential', () {
      // The whole risk of a suffix test: `myserver.onion` looks like an onion,
      // will never resolve, and must not be treated as protecting a view key.
      expect(
        classifyEndpoint(Uri.parse('http://myserver.onion'), viaTor: true),
        ChannelConfidentiality.none,
      );
      // Right length, wrong alphabet (base32 has no '0', '1', '8' or '9').
      const bad = '00000000000000000000000000000000000000000000000000234567';
      expect(bad.length, 56);
      expect(
        classifyEndpoint(Uri.parse('http://$bad.onion'), viaTor: true),
        ChannelConfidentiality.none,
      );
    });

    test('.onion as a non-final label does not count', () {
      // `evil.com` is the host that is actually contacted here.
      expect(
        classifyEndpoint(Uri.parse('http://$v3.onion.evil.com'), viaTor: true),
        ChannelConfidentiality.none,
      );
    });
  });

  group('local', () {
    test('loopback by name and by literal', () {
      for (final host in ['localhost', 'foo.localhost', '127.0.0.1', '127.1.2.3', '[::1]']) {
        expect(
          classifyEndpoint(Uri.parse('http://$host:18081'), viaTor: true),
          ChannelConfidentiality.local,
          reason: host,
        );
      }
    });

    test('RFC 1918 and link-local', () {
      for (final host in [
        '10.0.0.1',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.1',
        '169.254.1.1',
        '[fd00::1]', // IPv6 unique-local
        '[fe80::1]', // IPv6 link-local
      ]) {
        expect(
          classifyEndpoint(Uri.parse('http://$host:18081'), viaTor: true),
          ChannelConfidentiality.local,
          reason: host,
        );
      }
    });

    test('an IPv4-mapped IPv6 private address resolves to its IPv4 form', () {
      expect(
        classifyEndpoint(Uri.parse('http://[::ffff:192.168.1.10]:18081'), viaTor: true),
        ChannelConfidentiality.local,
      );
    });

    test('an mDNS .local name is a LAN name, not a routable host', () {
      // A self-hosted node advertised over Bonjour/Avahi. Before this, `.local`
      // fell through to `none` and got forced to https, breaking the plaintext
      // port such a node serves.
      for (final host in ['mynode.local', 'monerod.local']) {
        expect(
          classifyEndpoint(Uri.parse('http://$host:18081'), viaTor: true),
          ChannelConfidentiality.local,
          reason: host,
        );
        expect(requiresSecureTransport(host), isFalse, reason: host);
      }
    });

    test('near-misses outside the private ranges are not local', () {
      for (final host in [
        '172.15.0.1', // below 172.16/12
        '172.32.0.1', // above 172.16/12
        '11.0.0.1',
        '192.169.1.1',
        '8.8.8.8',
        '100.64.0.1', // CGNAT: routable inside a carrier network, shared
      ]) {
        expect(
          classifyEndpoint(Uri.parse('http://$host:18081'), viaTor: true),
          ChannelConfidentiality.none,
          reason: host,
        );
      }
    });
  });

  group('fails closed', () {
    test('a schemeless host:port is not confidential', () {
      // The trap this guards: connection addresses are stored as a bare
      // `host:port`, and `Uri.parse` puts the host in `scheme` and leaves
      // `host` empty. A caller that forgot the scheme must be refused.
      final uri = Uri.parse('example.com:18090');
      expect(uri.host, isEmpty);
      expect(classifyEndpoint(uri, viaTor: true), ChannelConfidentiality.none);
    });

    test('an empty URI is not confidential', () {
      expect(classifyEndpoint(Uri.parse(''), viaTor: true), ChannelConfidentiality.none);
    });
  });

  group('requireConfidentialChannel', () {
    test('throws for plaintext clearnet, and names neither the secret nor the path', () {
      Object? caught;
      try {
        requireConfidentialChannel(
          Uri.parse('http://lws.example.com:18090/upsert_subaddrs?token=abc'),
          carrying: 'the private view key',
          viaTor: true,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<InsecureChannelException>());
      final text = caught.toString();
      expect(text, contains('the private view key'));
      expect(text, contains('lws.example.com:18090'));
      // The path and query are not this exception's business to repeat.
      expect(text, isNot(contains('upsert_subaddrs')));
      expect(text, isNot(contains('token')));
    });

    test('permits each confidential shape', () {
      const v3 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa234567';
      for (final url in [
        'https://lws.example.com/upsert_subaddrs',
        'http://$v3.onion/upsert_subaddrs',
        'http://127.0.0.1:18090/upsert_subaddrs',
        'http://192.168.1.50:18090/upsert_subaddrs',
      ]) {
        expect(
          () => requireConfidentialChannel(
            Uri.parse(url),
            carrying: 'the private view key',
            viaTor: true,
          ),
          returnsNormally,
          reason: url,
        );
      }
    });
  });

  group('isUnroutedOnion', () {
    // The rule a connection is gated on before any request exists, so it takes
    // the bare `host:port` connection addresses are stored as, and answers only
    // about the route. Everything else is [classifyEndpoint]'s job.
    const v3 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa234567';
    const v2 = 'aaaaaaaaaaaaaaaa';

    test('an onion with nothing routing it is refused', () {
      expect(isUnroutedOnion('$v3.onion:18090', viaProxy: false), isTrue);
      expect(isUnroutedOnion('$v2.onion', viaProxy: false), isTrue);
    });

    test('any SOCKS route satisfies it', () {
      // Tor's own port or the user's proxy. A non-Tor proxy cannot resolve
      // `.onion`, so it fails to connect rather than leaking the name.
      expect(isUnroutedOnion('$v3.onion:18090', viaProxy: true), isFalse);
    });

    test('a non-onion address is never its business', () {
      for (final address in [
        'lws.example.com:18090',
        '127.0.0.1:18090',
        '192.168.1.50:18090',
        'node.local:18081',
        // A typo that is not a real onion label; promoting it would be wrong in
        // both directions, and here it must simply not match.
        'myserver.onion:18090',
      ]) {
        expect(isUnroutedOnion(address, viaProxy: false), isFalse, reason: address);
      }
    });

    test('a scheme the caller left on is tolerated, not silently mismatched', () {
      // Addresses are stored bare, but the host is parsed rather than string
      // matched, so a caller that kept a scheme still gets the right answer.
      expect(isUnroutedOnion('$v3.onion:18090', viaProxy: false), isTrue);
      expect(isUnroutedOnion('$v3.ONION:18090', viaProxy: false), isTrue);
    });
  });

  test('isConfidential is the one question a secret-holder asks', () {
    expect(ChannelConfidentiality.tls.isConfidential, isTrue);
    expect(ChannelConfidentiality.onion.isConfidential, isTrue);
    expect(ChannelConfidentiality.local.isConfidential, isTrue);
    expect(ChannelConfidentiality.none.isConfidential, isFalse);
  });
}
