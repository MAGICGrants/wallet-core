// monero.dart marks almost its whole surface `@Deprecated("TODO")`, the
// generator's marker for "not yet exercised"; there is no replacement API.
// ignore_for_file: deprecated_member_use

import 'dart:io';
import 'dart:isolate';

import 'package:monero/monero.dart' as monero;
import 'package:polyseed/polyseed.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import '../monero_wallet.dart';

/// One TLS check against the real native library.
typedef NativeTlsCheck = ({String name, Future<void> Function(Directory workDir) run});

/// Thrown when a [NativeTlsCheck] finds TLS behaving wrongly. Any test runner
/// reports it as a failure.
class NativeTlsCheckFailure implements Exception {
  NativeTlsCheckFailure(this.message);
  final String message;

  @override
  String toString() => 'NativeTlsCheckFailure: $message';
}

/// The two ways the wallet reaches its server: an LWS through LWSF, or a node
/// through wallet2. They share OpenSSL and epee's verification but configure
/// it separately, so every check runs against both.
enum TlsMode {
  lws,
  node;

  bool get lightWallet => this == lws;
}

/// The TLS behaviour the wallet relies on, checked against the native library
/// for the platform the checks run on.
///
/// Every check stands up loopback servers from [TestPki] and judges the
/// library by what reached the server: a completed handshake, a request, or
/// nothing. They cover both modes, direct and through a SOCKS proxy (the Tor
/// route), and the wallet's own connect path from Dart:
///
///  - a chain to the CA file that names the host is accepted;
///  - a valid certificate for another host, and a chain to another root, are
///    rejected;
///  - an `https` server that speaks plaintext gets no plaintext request;
///  - a CA file that cannot be read is an error, never a fallback to some
///    other trust store;
///  - LWS makes a fresh TLS session after the server closes a connection.
///
/// [libPath] points `monero.libPath` at a host build; null keeps the
/// platform's default, which is what an app's integration test wants.
List<NativeTlsCheck> nativeTlsChecks({String? libPath}) => [
  for (final mode in TlsMode.values) ...[
    (
      name: '${mode.name}: accepts a chain to the CA file that names the host',
      run: (dir) => _expectAccepted(mode, libPath, dir),
    ),
    (
      name: '${mode.name}: rejects a valid certificate for another host',
      run: (dir) => _expectRejected(
        mode,
        libPath,
        dir,
        chain: TestPki.wrongHostChain,
        key: TestPki.wrongHostKey,
      ),
    ),
    (
      name: '${mode.name}: rejects a chain to a root outside the CA file',
      run: (dir) => _expectRejected(
        mode,
        libPath,
        dir,
        chain: TestPki.untrustedServerCert,
        key: TestPki.untrustedServerKey,
      ),
    ),
    (
      name: '${mode.name}: never falls back to plaintext',
      run: (dir) => _expectNoPlaintextFallback(mode, libPath, dir),
    ),
    (
      name: '${mode.name}: an unreadable CA file is an error, not a fallback',
      run: (dir) => _expectMissingCaFileRefused(mode, libPath, dir),
    ),
    (
      name: '${mode.name}: through a SOCKS proxy, verifies the name it asked for',
      run: (dir) => _expectSocksVerifiesName(mode, libPath, dir),
    ),
    (
      name: '${mode.name}: the wallet connect path verifies with the CA bundle',
      run: (dir) => _expectWalletConnectVerifies(mode, dir),
    ),
  ],
  (
    name: 'lws: a new TLS session after the server closes the connection',
    run: (dir) => _expectLwsReconnects(libPath, dir),
  ),
];

/// The packaged CA bundle reaches the app directory intact. Needs a Flutter
/// binding to load the asset, so only an app's integration test runs it.
Future<void> checkShippedCaBundle() async {
  CaBundle.resetForTesting();
  final pem = await File(await CaBundle.path()).readAsString();
  final certificates = RegExp('-----BEGIN CERTIFICATE-----').allMatches(pem).length;
  _expect(certificates > 100, 'the shipped CA bundle holds $certificates certificates');
}

void _expect(bool ok, String failure) {
  if (!ok) throw NativeTlsCheckFailure(failure);
}

String _describe(TlsTestServer server, _Outcome outcome) =>
    'server: ${server.handshakes} handshakes, ${server.failedHandshakes} failed, '
    '${server.requests.length} requests; library: $outcome';

String _freshSeed() => Polyseed.create().encode(
  PolyseedLang.getByEnglishName('English'),
  PolyseedCoin.POLYSEED_MONERO,
);

Future<String> _writeRootCa(Directory dir) async {
  final file = File('${dir.path}/test-root-ca.pem');
  await file.writeAsString(TestPki.rootCa);
  return file.path;
}

/// What the library reported for one wallet's connection attempts.
typedef _Outcome = ({bool? caAccepted, bool initOk, List<bool> connected, String error});

var _walletCounter = 0;

/// Creates a throwaway wallet in [mode], optionally hands it [caFile], and
/// connects to [daemonAddress] [connects] times. Runs in its own isolate, so
/// the calling isolate stays free to serve the TLS server.
Future<_Outcome> _connect(
  TlsMode mode, {
  required String? libPath,
  required Directory dir,
  required String daemonAddress,
  String proxyAddress = '',
  String? caFile,
  int connects = 1,
}) {
  final walletPath = '${dir.path}/wallet_${mode.name}_${_walletCounter++}';
  final mnemonic = _freshSeed();
  final lightWallet = mode.lightWallet;
  return Isolate.run(() {
    if (libPath != null) monero.libPath = libPath;
    final wm = lightWallet
        ? monero.WalletManagerFactory_getLWSFWalletManager()
        : monero.WalletManagerFactory_getWalletManager();
    final wallet = monero.WalletManager_createWalletFromPolyseed(
      wm,
      path: walletPath,
      password: 'tls-test',
      mnemonic: mnemonic,
      seedOffset: '',
      newWallet: true,
      restoreHeight: 0,
      kdfRounds: 1,
    );
    final createError = monero.Wallet_errorString(wallet);
    if (createError.isNotEmpty) throw StateError('wallet creation failed: $createError');

    final caAccepted = caFile == null ? null : monero.Wallet_setCaFilePath(wallet, caFile);
    final initOk = monero.Wallet_init(
      wallet,
      daemonAddress: daemonAddress,
      proxyAddress: proxyAddress,
      useSsl: daemonAddress.startsWith('https://'),
      lightWallet: lightWallet,
    );
    final connected = [for (var i = 0; i < connects; i++) monero.Wallet_connectToDaemon(wallet)];
    final error = monero.Wallet_errorString(wallet);
    monero.WalletManager_closeWallet(wm, wallet, false);
    return (caAccepted: caAccepted, initOk: initOk, connected: connected, error: error);
  });
}

Future<T> _withServer<T>(
  Future<TlsTestServer> server,
  Future<T> Function(TlsTestServer server) body,
) async {
  final started = await server;
  try {
    return await body(started);
  } finally {
    await started.close();
  }
}

Future<void> _expectAccepted(TlsMode mode, String? libPath, Directory dir) => _withServer(
  TlsTestServer.start(chainPem: TestPki.serverChain, keyPem: TestPki.serverKey),
  (server) async {
    final outcome = await _connect(
      mode,
      libPath: libPath,
      dir: dir,
      daemonAddress: 'https://127.0.0.1:${server.port}',
      caFile: await _writeRootCa(dir),
    );
    _expect(outcome.caAccepted == true, 'the library did not take the CA file: $outcome');
    _expect(
      server.handshakes > 0 && server.requests.isNotEmpty,
      'a certificate the CA file vouches for, for this host, must be accepted. '
      '${_describe(server, outcome)}',
    );
  },
);

Future<void> _expectRejected(
  TlsMode mode,
  String? libPath,
  Directory dir, {
  required String chain,
  required String key,
}) => _withServer(TlsTestServer.start(chainPem: chain, keyPem: key), (server) async {
  final outcome = await _connect(
    mode,
    libPath: libPath,
    dir: dir,
    daemonAddress: 'https://127.0.0.1:${server.port}',
    caFile: await _writeRootCa(dir),
  );
  _expect(
    server.handshakes == 0 && server.requests.isEmpty,
    'the certificate must be rejected during the handshake. ${_describe(server, outcome)}',
  );
  _expect(!outcome.connected.any((c) => c), 'the library reported a connection: $outcome');
});

Future<void> _expectNoPlaintextFallback(TlsMode mode, String? libPath, Directory dir) async {
  final server = await PlainHttpTestServer.start();
  try {
    final outcome = await _connect(
      mode,
      libPath: libPath,
      dir: dir,
      daemonAddress: 'https://127.0.0.1:${server.port}',
      caFile: await _writeRootCa(dir),
    );
    _expect(server.tlsAttempts > 0, 'the library never attempted TLS: $outcome');
    _expect(
      server.requests.isEmpty,
      'asked for https, the library sent ${server.requests.length} plaintext requests '
      '(${server.requests.map((r) => '${r.method} ${r.target}').join(', ')}): $outcome',
    );
  } finally {
    await server.close();
  }
}

Future<void> _expectMissingCaFileRefused(TlsMode mode, String? libPath, Directory dir) =>
    _withServer(TlsTestServer.start(chainPem: TestPki.serverChain, keyPem: TestPki.serverKey), (
      server,
    ) async {
      final missing = '${dir.path}/no-such-ca.pem';
      final outcome = await _connect(
        mode,
        libPath: libPath,
        dir: dir,
        daemonAddress: 'https://127.0.0.1:${server.port}',
        caFile: missing,
      );
      if (mode == TlsMode.node) {
        _expect(outcome.caAccepted == false, 'wallet2 accepted a missing CA file: $outcome');
      } else {
        _expect(
          !outcome.initOk && outcome.error.contains(missing),
          'LWSF must fail init on a missing CA file and name it: $outcome',
        );
      }
      _expect(
        server.handshakes == 0 && server.requests.isEmpty,
        'nothing may connect without the CA file. ${_describe(server, outcome)}',
      );
    });

Future<void> _expectSocksVerifiesName(TlsMode mode, String? libPath, Directory dir) async {
  final good = await TlsTestServer.start(chainPem: TestPki.serverChain, keyPem: TestPki.serverKey);
  final wrong = await TlsTestServer.start(
    chainPem: TestPki.wrongHostChain,
    keyPem: TestPki.wrongHostKey,
  );
  final toGood = await SocksTestProxy.start({TestPki.routableHost: good.port});
  final toWrong = await SocksTestProxy.start({TestPki.routableHost: wrong.port});
  try {
    final caFile = await _writeRootCa(dir);
    final accepted = await _connect(
      mode,
      libPath: libPath,
      dir: dir,
      daemonAddress: 'https://${TestPki.routableHost}:443',
      proxyAddress: toGood.address,
      caFile: caFile,
    );
    _expect(
      toGood.requested.contains(TestPki.routableHost),
      'the library did not ask the proxy for ${TestPki.routableHost} '
      '(asked for ${toGood.requested}): $accepted',
    );
    _expect(
      good.handshakes > 0 && good.requests.isNotEmpty,
      'through the proxy, a valid certificate for the name must be accepted. '
      '${_describe(good, accepted)}',
    );

    final rejected = await _connect(
      mode,
      libPath: libPath,
      dir: dir,
      daemonAddress: 'https://${TestPki.routableHost}:443',
      proxyAddress: toWrong.address,
      caFile: caFile,
    );
    _expect(
      wrong.handshakes == 0 && wrong.requests.isEmpty,
      'through the proxy, a certificate for another name must be rejected. '
      '${_describe(wrong, rejected)}',
    );
  } finally {
    await toGood.close();
    await toWrong.close();
    await good.close();
    await wrong.close();
  }
}

Future<void> _expectLwsReconnects(String? libPath, Directory dir) => _withServer(
  // Every answer closes the connection, as a server does when a keep-alive
  // ends, so each request needs a new TCP connection and a new TLS session.
  TlsTestServer.start(chainPem: TestPki.serverChain, keyPem: TestPki.serverKey),
  (server) async {
    final outcome = await _connect(
      TlsMode.lws,
      libPath: libPath,
      dir: dir,
      daemonAddress: 'https://127.0.0.1:${server.port}',
      caFile: await _writeRootCa(dir),
      connects: 2,
    );
    _expect(
      server.requests.length >= 2 && server.failedHandshakes == 0,
      'every connection after the first must open its own TLS session. '
      '${_describe(server, outcome)}',
    );
  },
);

/// The wallet's own connect path, through Dart: the CA bundle is provisioned
/// and handed to the library on this platform, in this mode. The bundle is the
/// test root here, and the server is reached by name through a SOCKS proxy, so
/// the wallet treats it as routable and requires TLS.
Future<void> _expectWalletConnectVerifies(TlsMode mode, Directory dir) async {
  final good = await TlsTestServer.start(chainPem: TestPki.serverChain, keyPem: TestPki.serverKey);
  final untrusted = await TlsTestServer.start(
    chainPem: TestPki.untrustedServerCert,
    keyPem: TestPki.untrustedServerKey,
  );
  final toGood = await SocksTestProxy.start({TestPki.routableHost: good.port});
  final toUntrusted = await SocksTestProxy.start({TestPki.routableHost: untrusted.port});
  const address = '${TestPki.routableHost}:443';

  SharedPreferencesService.store = MemoryPreferenceStore();
  WalletSecrets.store = MemorySecretStore();
  WalletFileCrypto.kdf = const FastTestPbkdf2();
  WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(dir));
  useTestCaBundle();
  final logs = MemoryLogSink();
  WalletLog.sink = logs;
  String warnings() =>
      logs.records.where((r) => r.level == LogLevel.warn).map((r) => r.line).join(' | ');
  final wallet = MoneroWallet();
  void reachThrough(SocksTestProxy proxy) => wallet.setConnection(
    address: address,
    proxyPort: '${proxy.port}',
    useTor: false,
    connectionType: mode.name,
  );
  try {
    reachThrough(toGood);
    await wallet.restoreFromSeed(
      seed: PolyseedSeed(_freshSeed()),
      from: const RestorePoint.newWallet(),
      password: 'tls-test',
    );

    // Connects the way the app does: one connect at a time, alongside the
    // wallet's own timers, which reconnect on their own.
    await wallet.connectToDaemon();
    _expect(
      good.handshakes > 0 && good.requests.isNotEmpty,
      'the wallet must verify a server against the CA bundle and connect. '
      'server: ${good.handshakes} handshakes, ${good.failedHandshakes} failed; '
      'wallet log: ${warnings()}',
    );

    reachThrough(toUntrusted);
    await wallet.connectToDaemon();
    _expect(
      untrusted.handshakes == 0 && untrusted.requests.isEmpty,
      'the wallet must reject a server outside the CA bundle. '
      'server: ${untrusted.handshakes} handshakes, ${untrusted.requests.length} requests',
    );
  } finally {
    // Deletes the way the app does, which holds the timers off and waits for
    // any native call still running on the wallet before freeing it, and
    // before its directory goes away.
    await wallet.delete();
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    WalletFileCrypto.kdf = const WebCryptoPbkdf2();
    await toGood.close();
    await toUntrusted.close();
    await good.close();
    await untrusted.close();
  }
}
