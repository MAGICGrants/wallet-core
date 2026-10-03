import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// The connection probe (`testConnection`) through a SOCKS proxy the user set
/// up themselves, with Tor off.
///
/// The server is reached by a routable-looking name that only the proxy can
/// resolve, so the probe has to use TLS, has to hand the name to the proxy,
/// and passes only for a certificate that chains to the CA bundle.
void main() {
  late Directory tmp;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_connection_probe');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    // The test root stands in for the packaged CA bundle; the servers below
    // present chains to it.
    useTestCaBundle();
    WalletLog.sink = MemoryLogSink();
    wallet = MoneroWallet(backend: FakeMoneroBackend());
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const address = '${TestPki.routableHost}:443';

  /// Runs [body] against a TLS server answering with [respond], reachable as
  /// [TestPki.routableHost] only through the proxy.
  Future<void> throughProxy(
    TestResponse Function(ReceivedRequest request) respond,
    Future<void> Function(TlsTestServer server, SocksTestProxy proxy) body, {
    String chain = TestPki.serverChain,
    String key = TestPki.serverKey,
  }) async {
    final server = await TlsTestServer.start(chainPem: chain, keyPem: key, respond: respond);
    final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
    try {
      await body(server, proxy);
    } finally {
      await proxy.close();
      await server.close();
    }
  }

  /// Answers [method] [target] with [status] and [body], anything else with 404.
  TestResponse Function(ReceivedRequest) answer(
    String method,
    String target,
    int status, [
    String body = '',
  ]) =>
      (request) => request.method == method && request.target == target
      ? (status: status, body: body, close: true)
      : (status: 404, body: '', close: true);

  test('LWS: get_address_info answered 500 passes', () async {
    await throughProxy(answer('POST', '/get_address_info', 500), (server, proxy) async {
      await wallet.testConnection(
        address: address,
        proxyPort: '${proxy.port}',
        useTor: false,
        connectionType: 'lws',
      );

      expect(proxy.requested, [TestPki.routableHost], reason: 'the proxy resolves the name');
      expect(server.handshakes, 1);
      expect(server.requests.map((r) => '${r.method} ${r.target}'), ['POST /get_address_info']);
    });
  });

  test('node: get_height answered 200 with a height passes', () async {
    const reply = '{"height":3000000,"status":"OK"}';
    await throughProxy(answer('GET', '/get_height', 200, reply), (server, proxy) async {
      await wallet.testConnection(
        address: address,
        proxyPort: '${proxy.port}',
        useTor: false,
        connectionType: 'node',
      );

      expect(proxy.requested, [TestPki.routableHost], reason: 'the proxy resolves the name');
      expect(server.handshakes, 1);
      expect(server.requests.map((r) => '${r.method} ${r.target}'), ['GET /get_height']);
    });
  });

  test('a certificate outside the CA bundle fails the probe', () async {
    await throughProxy(
      answer('POST', '/get_address_info', 500),
      chain: TestPki.untrustedServerCert,
      key: TestPki.untrustedServerKey,
      (server, proxy) async {
        await expectLater(
          wallet.testConnection(
            address: address,
            proxyPort: '${proxy.port}',
            useTor: false,
            connectionType: 'lws',
          ),
          throwsA(isA<HandshakeException>()),
        );

        expect(proxy.requested, [TestPki.routableHost]);
        expect(server.handshakes, 0);
        expect(server.requests, isEmpty);
      },
    );
  });
}
