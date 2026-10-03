import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The CA bundle is the only trust store the wallet uses for TLS to a Monero
/// server, natively and in Dart. These tests pin what it contains, where it is
/// written for the native library, and that a context built from it verifies
/// both the chain and the hostname.
void main() {
  group('the packaged bundle', () {
    // Read from the package itself: the asset the apps ship.
    final pem = File('assets/cacert.pem').readAsStringSync();
    final certificates = RegExp('-----BEGIN CERTIFICATE-----').allMatches(pem).length;

    test('is a full root set, not a stub or a truncated file', () {
      expect(certificates, greaterThan(100));
      expect(
        RegExp('-----END CERTIFICATE-----').allMatches(pem).length,
        certificates,
        reason: 'every certificate must be complete',
      );
    });

    test('carries the roots behind the certificates LWS and node operators use', () {
      // Each certificate is preceded by its root's name, underlined with '='.
      final roots = RegExp(
        r'^(.+)\n=+\n-----BEGIN CERTIFICATE-----',
        multiLine: true,
      ).allMatches(pem).map((m) => m.group(1)!.trim()).toSet();
      expect(roots, hasLength(certificates), reason: 'every certificate is named');

      // Let's Encrypt (both chains), Google Trust Services, DigiCert and Sectigo.
      expect(
        roots,
        containsAll([
          'ISRG Root X1',
          'ISRG Root X2',
          'GTS Root R1',
          'DigiCert Global Root G2',
          'USERTrust RSA Certification Authority',
        ]),
      );
    });

    test('loads into a TLS context in full', () {
      // BoringSSL rejects the whole file when any certificate in it is malformed.
      expect(
        () =>
            SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(pem)),
        returnsNormally,
      );
    });

    test('is not stale', () {
      // Mozilla adds and distrusts roots every few months; a bundle this old
      // starts rejecting new servers. Refresh with scripts/update-cacert.sh.
      if (Platform.environment['CHECK_CACERT_AGE'] != '1') {
        return markTestSkipped('set CHECK_CACERT_AGE=1 (the nightly job does)');
      }
      final asOf = RegExp(
        r'Certificate data from Mozilla as of: \w{3} (\w{3}) +(\d+) [\d:]+ (\d{4})',
      ).firstMatch(pem);
      expect(asOf, isNotNull, reason: 'the bundle header carries its date');
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final date = DateTime.utc(
        int.parse(asOf!.group(3)!),
        months.indexOf(asOf.group(1)!) + 1,
        int.parse(asOf.group(2)!),
      );
      expect(
        DateTime.now().toUtc().difference(date).inDays,
        lessThan(400),
        reason: 'the CA bundle dates from $date; refresh it',
      );
    });
  });

  group('CaBundle.path', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ca_bundle');
      WalletPaths.install(
        linuxDirName: '.wallet_test',
        windowsAppDataDir: 'Wallet Test',
        directories: FixedDirectories(tmp),
      );
      useTestCaBundle();
    });

    tearDown(() {
      CaBundle.resetForTesting();
      WalletPaths.resetForTesting();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('writes the bundle into the app directory', () async {
      final path = await CaBundle.path();

      expect(path, '${tmp.path}${Platform.pathSeparator}cacert.pem');
      expect(File(path).readAsStringSync(), TestPki.rootCa);
      expect(
        tmp.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
        ['cacert.pem'],
        reason: 'no temporary file is left behind',
      );
    });

    test('rewrites a file that differs from the shipped bundle', () async {
      // An app update that refreshes the bundle must reach the native library,
      // and so must a file that was damaged on disk.
      File('${tmp.path}/cacert.pem').writeAsStringSync(TestPki.untrustedCa);

      final path = await CaBundle.path();

      expect(File(path).readAsStringSync(), TestPki.rootCa);
    });

    test('writes it again when it disappears', () async {
      final path = await CaBundle.path();
      File(path).deleteSync();

      expect(await CaBundle.path(), path);
      expect(File(path).readAsStringSync(), TestPki.rootCa);
    });

    test('concurrent callers share one result', () async {
      final paths = await Future.wait(List.generate(8, (_) => CaBundle.path()));

      expect(paths.toSet(), hasLength(1));
      expect(File(paths.first).readAsStringSync(), TestPki.rootCa);
    });

    test('refuses a bundle without a certificate, and writes nothing', () async {
      CaBundle.resetForTesting();
      CaBundle.load = () async => Uint8List.fromList(utf8.encode('<html>not a bundle</html>'));

      await expectLater(CaBundle.path(), throwsA(isA<FormatException>()));
      expect(File('${tmp.path}/cacert.pem').existsSync(), isFalse);
    });

    test('without the asset, the copy already written is used', () async {
      final path = await CaBundle.path();
      CaBundle.resetForTesting();
      CaBundle.load = () async => throw StateError('no asset bundle in this isolate');

      expect(await CaBundle.path(), path);
    });

    test('without the asset or a usable copy, there is no path', () async {
      CaBundle.resetForTesting();
      CaBundle.load = () async => throw StateError('no asset bundle in this isolate');

      await expectLater(CaBundle.path(), throwsA(isA<StateError>()));

      File('${tmp.path}/cacert.pem').writeAsStringSync('truncated');
      await expectLater(CaBundle.path(), throwsA(isA<StateError>()));
    });

    test('a failure is retried on the next call', () async {
      var attempts = 0;
      CaBundle.resetForTesting();
      CaBundle.load = () async {
        if (attempts++ == 0) throw const FileSystemException('transient');
        return Uint8List.fromList(utf8.encode(TestPki.rootCa));
      };

      await expectLater(CaBundle.path(), throwsA(isA<FileSystemException>()));
      expect(File(await CaBundle.path()).readAsStringSync(), TestPki.rootCa);
    });
  });

  group('CaBundle.securityContext', () {
    setUp(useTestCaBundle);
    tearDown(CaBundle.resetForTesting);

    Future<int> get(TlsTestServer server, {required String host, SocksTestProxy? proxy}) async {
      final context = await CaBundle.securityContext();
      if (proxy != null) {
        final response = await makeSocksHttpRequest(
          'GET',
          'https://$host:${server.port}/probe',
          (host: InternetAddress.loopbackIPv4, port: proxy.port),
          timeout: const Duration(seconds: 10),
          securityContext: context,
        );
        return response.statusCode;
      }
      final client = HttpClient(context: context);
      try {
        final request = await client.getUrl(Uri.parse('https://$host:${server.port}/probe'));
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    test('accepts a server whose chain leads to the bundle and names the host', () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
      );
      addTearDown(server.close);

      expect(await get(server, host: '127.0.0.1'), 404);
      expect(server.requests.single.target, '/probe');
    });

    test('rejects a valid certificate for another host', () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.wrongHostChain,
        keyPem: TestPki.wrongHostKey,
      );
      addTearDown(server.close);

      await expectLater(get(server, host: '127.0.0.1'), throwsA(isA<HandshakeException>()));
      expect(server.requests, isEmpty);
    });

    test('rejects a chain to a root outside the bundle', () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.untrustedServerCert,
        keyPem: TestPki.untrustedServerKey,
      );
      addTearDown(server.close);

      await expectLater(get(server, host: '127.0.0.1'), throwsA(isA<HandshakeException>()));
      expect(server.requests, isEmpty);
    });

    test('verifies the name asked for through a SOCKS proxy, not the proxy', () async {
      final good = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
      );
      final wrong = await TlsTestServer.start(
        chainPem: TestPki.wrongHostChain,
        keyPem: TestPki.wrongHostKey,
      );
      final proxy = await SocksTestProxy.start({TestPki.routableHost: good.port});
      final wrongProxy = await SocksTestProxy.start({TestPki.routableHost: wrong.port});
      addTearDown(() async {
        await proxy.close();
        await wrongProxy.close();
        await good.close();
        await wrong.close();
      });

      expect(await get(good, host: TestPki.routableHost, proxy: proxy), 404);
      expect(proxy.requested, [TestPki.routableHost]);

      await expectLater(
        get(wrong, host: TestPki.routableHost, proxy: wrongProxy),
        throwsA(isA<HandshakeException>()),
      );
      expect(wrong.requests, isEmpty);
    });

    test('without the bundle, the OS store does not know the test root', () async {
      // The control for the tests above: they pass because of the context the
      // bundle builds, not because the platform happens to trust the test root.
      final server = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
      );
      addTearDown(server.close);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      await expectLater(
        client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/')).then((r) => r.close()),
        throwsA(isA<HandshakeException>()),
      );
    });
  });
}
