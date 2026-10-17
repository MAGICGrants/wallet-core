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
}
