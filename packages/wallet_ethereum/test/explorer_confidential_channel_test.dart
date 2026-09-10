import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ethereum/wallet_ethereum.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The confidentiality gate on the Blockscout explorer client.
///
/// An explorer request carries the user's own address in the URL path, so it is
/// a secret-carrying egress in the same sense the Monero view-key upload is. The
/// shared [requireConfidentialChannel] existed but was wired only into Monero;
/// this pins that the Ethereum explorer now refuses to hand that address to a
/// plaintext channel, including a plaintext `http://` routed through Tor, where
/// the IP is hidden but an arbitrary exit node still reads the path.
///
/// The check is the first line of the request path, before any socket is opened,
/// so these assert without a network: a refused request never reaches I/O.
void main() {
  const address = '0x1234567890abcdef1234567890abcdef12345678';
  const contract = '0xdac17f958d2ee523a2206206994597c13d831ec7';

  late EthereumExplorerClient client;
  setUp(() => client = EthereumExplorerClient());

  group('a plaintext clearnet explorer is refused', () {
    test('fetchTxList', () {
      expect(
        () => client.fetchTxList('http://blockscout.example.org', address),
        throwsA(isA<InsecureChannelException>()),
      );
    });

    test('fetchTokenTransfers', () {
      expect(
        () => client.fetchTokenTransfers('http://blockscout.example.org', address, contract),
        throwsA(isA<InsecureChannelException>()),
      );
    });

    test('probe — so an insecure explorer is rejected at setup, not saved', () {
      expect(
        () => client.probe('http://blockscout.example.org'),
        throwsA(isA<InsecureChannelException>()),
      );
    });

    test('routing through a Tor SOCKS port does not make it acceptable', () {
      // The IP is hidden by the proxy; the address in the path is not. So the
      // refusal must not depend on socksPort being absent.
      expect(
        () => client.fetchTxList('http://blockscout.example.org', address, socksPort: 9050),
        throwsA(isA<InsecureChannelException>()),
      );
    });
  });

  test('the refusal names the endpoint but not the address', () async {
    try {
      await client.fetchTxList('http://blockscout.example.org', address);
      fail('a plaintext clearnet explorer must be refused');
    } on InsecureChannelException catch (e) {
      final message = e.toString();
      expect(message, contains('blockscout.example.org'));
      // The address is what this refusal exists to protect; it must not leak
      // into the error that reports the refusal.
      expect(message, isNot(contains(address)));
    }
  });

  group('a confidential channel passes the gate', () {
    // These prove the gate is not over-blocking. It lets the request through, so
    // the failure that surfaces is a connection error, never the gate's refusal.

    test('a loopback (local) explorer is allowed through', () {
      // 127.0.0.1 is local, the bytes never reach a routable network, so the
      // gate passes and the closed port surfaces something other than a refusal.
      expect(
        () => client.fetchTxList('http://127.0.0.1:1', address),
        throwsA(isNot(isA<InsecureChannelException>())),
      );
    });

    test('an https explorer is allowed through', () {
      // TLS is confidential, so the gate passes; the unresolvable host then fails
      // with a network error rather than the refusal.
      expect(
        () => client.fetchTxList('https://blockscout.invalid', address),
        throwsA(isNot(isA<InsecureChannelException>())),
      );
    });
  });

  test('a schemeless base normalizes to https and is allowed through', () {
    // `_normalizeBase` prepends https, so a bare host is confidential by default
    // and only an explicit `http://` opts into the refusal above.
    expect(
      () => client.fetchTxList('blockscout.invalid', address),
      throwsA(isNot(isA<InsecureChannelException>())),
    );
  });
}
