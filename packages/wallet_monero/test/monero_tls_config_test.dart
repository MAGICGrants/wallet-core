import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// How the wallet configures TLS before it connects, on the fake backend.
///
/// Every TLS connection to the server, LWS or node, must be verified against
/// the bundled CA set, so the bundle has to reach the native library before
/// `init` on every platform. Nothing here depends on the host OS: the decision
/// takes no platform input, which is exactly what these tests pin.
void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;
  late MemoryLogSink logs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_tls_config');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    useTestCaBundle();
    logs = MemoryLogSink();
    WalletLog.sink = logs;
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
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

  Future<void> open(String type, String address) async {
    wallet.setConnection(address: address, proxyPort: '', useTor: false, connectionType: type);
    backend.existingWalletPaths.add(await wallet.walletPathForType(type));
    await wallet.openExisting(password: 'pw');
    backend.calls.clear();
  }

  const onion = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa234567.onion:18090';

  for (final type in ['lws', 'node']) {
    group('$type over TLS', () {
      const address = 'xmr.example.com:443';

      test('hands the native library the CA bundle before init', () async {
        await open(type, address);

        await wallet.connectToDaemonImpl(address: address, proxyPort: '');

        final bundle = File(backend.caFilePaths.single);
        expect(bundle.path, startsWith(tmp.path), reason: 'written into the app directory');
        expect(bundle.readAsStringSync(), TestPki.rootCa);
        expect(
          backend.calls.indexOf('setCaFilePath'),
          lessThan(backend.calls.indexOf('init')),
          reason: 'the library reads the CA file in init',
        );
        expect(backend.initCalls.single, (daemonAddress: 'https://$address', useSsl: true));
      });

      test('the same file is used on every connect', () async {
        await open(type, address);

        await wallet.connectToDaemonImpl(address: address, proxyPort: '');
        await wallet.connectToDaemonImpl(address: address, proxyPort: '9050');

        expect(backend.caFilePaths.toSet(), hasLength(1));
      });

      test('a library that does not take the bundle is refused, before init', () async {
        await open(type, address);
        backend.setCaFilePathResult = false;

        await expectLater(
          wallet.connectToDaemonImpl(address: address, proxyPort: ''),
          throwsA(isA<StateError>()),
        );
        expect(backend.initCalls, isEmpty, reason: 'no connection without a trust store');
      });

      test('no bundle, no connection', () async {
        await open(type, address);
        CaBundle.resetForTesting();
        CaBundle.load = () async => throw const FileSystemException('asset missing');

        await expectLater(
          wallet.connectToDaemonImpl(address: address, proxyPort: ''),
          throwsA(isA<FileSystemException>()),
        );
        expect(backend.initCalls, isEmpty);
      });

      test('a bundle with no certificate in it is refused', () async {
        await open(type, address);
        CaBundle.resetForTesting();
        CaBundle.load = () async => Uint8List.fromList(utf8.encode('not a certificate'));

        await expectLater(
          wallet.connectToDaemonImpl(address: address, proxyPort: ''),
          throwsA(isA<FormatException>()),
        );
        expect(backend.initCalls, isEmpty);
      });

      test('a failed connect is logged with the library reason', () async {
        await open(type, address);
        backend.connectToDaemonResult = false;
        backend.connectToDaemonError = 'SSL certificate is not in the allowed list';

        await wallet.connectToDaemonImpl(address: address, proxyPort: '');
        await Future<void>.delayed(Duration.zero);

        expect(
          logs.records.map((r) => r.line),
          contains(allOf(contains('connectToDaemon failed'), contains('not in the allowed list'))),
        );
      });

      test('a failed connect with no reason is still logged', () async {
        await open(type, address);
        backend.connectToDaemonResult = false;

        await wallet.connectToDaemonImpl(address: address, proxyPort: '');
        await Future<void>.delayed(Duration.zero);

        expect(
          logs.records.where((r) => r.level == LogLevel.warn).map((r) => r.line),
          contains(contains('connectToDaemon failed')),
        );
      });
    });
  }

  group('without TLS', () {
    test('a LAN node needs no bundle', () async {
      await open('node', '192.168.1.10:18081');

      await wallet.connectToDaemonImpl(address: '192.168.1.10:18081', proxyPort: '');

      expect(backend.caFilePaths, isEmpty);
      expect(backend.initCalls.single.useSsl, isFalse);
    });

    test('an onion LWS through Tor needs no bundle, and does not fail without one', () async {
      await open('lws', onion);
      CaBundle.resetForTesting();
      CaBundle.load = () async => throw const FileSystemException('asset missing');

      await wallet.connectToDaemonImpl(address: onion, proxyPort: '9050');

      expect(backend.caFilePaths, isEmpty);
      expect(backend.initCalls.single, (daemonAddress: 'http://$onion', useSsl: false));
    });
  });

  group('Dart requests to the server trust the same bundle', () {
    /// Captures the context each [HttpClient] is created with, then lets the
    /// request fail: nothing listens at the address.
    Future<List<SecurityContext?>> contextsOf(Future<void> Function() body) async {
      final contexts = <SecurityContext?>[];
      await HttpOverrides.runZoned(
        () async {
          try {
            await body();
          } catch (_) {}
        },
        createHttpClient: (context) {
          contexts.add(context);
          return _RefusingHttpClient();
        },
      );
      return contexts;
    }

    test('the connection probe', () async {
      await open('lws', 'xmr.example.com:443');

      final contexts = await contextsOf(
        () => wallet.testConnection(address: 'xmr.example.com:443', useTor: false),
      );

      expect(contexts.single, same(await CaBundle.securityContext()));
    });

    test('the subaddress registration that carries the view key', () async {
      await open('lws', 'xmr.example.com:443');

      final contexts = await contextsOf(
        () => wallet.postJson(Uri.parse('https://xmr.example.com/upsert_subaddrs'), '{}'),
      );

      expect(contexts.single, same(await CaBundle.securityContext()));
    });

    test('a plaintext LAN probe is unaffected', () async {
      await open('node', '192.168.1.10:18081');

      final contexts = await contextsOf(
        () => wallet.testConnection(
          address: '192.168.1.10:18081',
          useTor: false,
          connectionType: 'node',
        ),
      );

      expect(contexts.single, isNull);
    });
  });
}

/// Fails every request at connect time, so a test sees which context the
/// client was built with and nothing leaves the machine.
class _RefusingHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #close) return null;
    throw const SocketException('refused by test');
  }
}
