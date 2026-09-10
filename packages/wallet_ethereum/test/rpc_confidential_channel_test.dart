import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ethereum/wallet_ethereum.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The confidentiality gate on the JSON-RPC client.
///
/// Most RPC calls carry the user's address in their params: a balance, a nonce,
/// a gas estimate; so a plaintext request to a routable host hands that address
/// to anyone on the path, an arbitrary Tor exit included. There is no `useSsl`
/// toggle: `configure` defaults a schemeless URL to https, and an explicit
/// `http://` to a routable host is refused before any socket opens. Local and
/// onion endpoints, already confidential, are allowed.
///
/// The check runs at the head of the request path, so these assert with no
/// network: a refused call never reaches I/O, and an allowed one fails later
/// with a *different* error (an unresolved host), never the gate's refusal.
void main() {
  EthereumRpcClient client() => EthereumRpcClient(coinSymbol: 'ETH');

  test('an explicit http:// to a routable host is refused', () {
    final c = client()..configure(url: 'http://rpc.example.com');
    expect(c.chainId(), throwsA(isA<InsecureChannelException>()));
  });

  test('the refusal names the endpoint but not a secret', () async {
    final c = client()..configure(url: 'http://rpc.example.com');
    try {
      await c.chainId();
      fail('a plaintext clearnet RPC must be refused');
    } on InsecureChannelException catch (e) {
      expect(e.toString(), contains('rpc.example.com'));
      expect(e.toString(), contains('your wallet address'));
    }
  });

  group('a confidential channel passes the gate', () {
    // Not over-blocking: the gate passes, so what surfaces is a network error,
    // never the confidentiality refusal.
    test('a schemeless URL defaults to https and is allowed', () {
      final c = client()..configure(url: 'rpc.invalid');
      expect(c.chainId(), throwsA(isNot(isA<InsecureChannelException>())));
    });

    test('an explicit https URL is allowed', () {
      final c = client()..configure(url: 'https://rpc.invalid');
      expect(c.chainId(), throwsA(isNot(isA<InsecureChannelException>())));
    });

    test('a loopback http URL is allowed', () {
      final c = client()..configure(url: 'http://127.0.0.1:1');
      expect(c.chainId(), throwsA(isNot(isA<InsecureChannelException>())));
    });
  });
}
