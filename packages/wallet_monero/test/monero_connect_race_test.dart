import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Connects racing connection changes: the settings form saving a new server
/// or mode while a connect, or a timer tick, is still inside the native wallet.
///
/// Each case here was a way to end up not syncing until the app restarted: the
/// wallet left pointed at the server the user moved away from, two native
/// inits on one wallet, the LWS one-shot refresh blocking on a node wallet
/// mid-scan, or the LWS<->node rebuild closing a wallet a connect was using.

const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _password = 'the-existing-password';

/// Holds chosen native calls open, and records which handle each init and
/// close touched, so a test can pin a connect mid-flight and see what lands
/// on which wallet.
class _GatedBackend extends FakeMoneroBackend {
  Completer<void>? holdCaFile;
  Completer<void>? holdLogin;
  Completer<void>? holdRefresh;

  /// Completed as the held call is entered.
  final caFileEntered = Completer<void>();
  final loginEntered = Completer<void>();
  final refreshEntered = Completer<void>();

  final List<({int handle, String daemonAddress, bool lightWallet})> inits = [];
  final Set<int> closed = {};

  @override
  Future<bool> setCaFilePath(NativeHandle wallet, String path) async {
    final gate = holdCaFile;
    if (gate != null) {
      holdCaFile = null;
      caFileEntered.complete();
      await gate.future;
    }
    return super.setCaFilePath(wallet, path);
  }

  @override
  Future<void> init(
    NativeHandle wallet, {
    required String daemonAddress,
    required String proxyAddress,
    required bool useSsl,
    required bool lightWallet,
  }) async {
    inits.add((handle: wallet.id, daemonAddress: daemonAddress, lightWallet: lightWallet));
    await super.init(
      wallet,
      daemonAddress: daemonAddress,
      proxyAddress: proxyAddress,
      useSsl: useSsl,
      lightWallet: lightWallet,
    );
  }

  @override
  Future<bool> connectToDaemon(NativeHandle wallet) async {
    final gate = holdLogin;
    if (gate != null) {
      holdLogin = null;
      loginEntered.complete();
      await gate.future;
    }
    return super.connectToDaemon(wallet);
  }

  @override
  Future<bool> refresh(NativeHandle wallet) async {
    final gate = holdRefresh;
    if (gate != null) {
      holdRefresh = null;
      refreshEntered.complete();
      await gate.future;
    }
    return super.refresh(wallet);
  }

  @override
  Future<bool> closeWallet(NativeHandle manager, NativeHandle wallet, {required bool store}) {
    closed.add(wallet.id);
    return super.closeWallet(manager, wallet, store: store);
  }
}

/// Lets every pending microtask and short timer run.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late Directory tmp;
  late _GatedBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('connect_race');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    // Stands in for the packaged CA bundle, which needs a Flutter binding to load.
    useTestCaBundle();
    backend = _GatedBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// What the connection form does on save, before it applies the change.
  Future<void> save(String type, String address) async {
    wallet.setConnection(address: address, proxyPort: '', useTor: false, connectionType: type);
    await wallet.persistCurrentConnection();
  }

  Future<void> restoreIn(String type, String address) async {
    await save(type, address);
    await wallet.restoreFromSeed(
      seed: MoneroLegacySeed(_legacy25),
      from: RestorePoint.height(2800000),
      password: _password,
    );
  }

  group('saving a new server while a connect is still running', () {
    test('the wallet ends up on the new server, not the one it left', () async {
      await restoreIn('lws', 'old.example.com:18090');

      // A connect to the old server, paused before its native init.
      backend.holdCaFile = Completer<void>();
      final releaseOld = backend.holdCaFile!;
      final oldConnect = wallet.connectToDaemon();
      await backend.caFileEntered.future;

      await save('lws', 'new.example.com:18090');
      final apply = wallet.applyConnectionChange(password: _password);
      await _settle();
      releaseOld.complete();
      await oldConnect;
      await apply;

      expect(
        backend.inits.map((i) => i.daemonAddress),
        ['https://old.example.com:18090', 'https://new.example.com:18090'],
        reason: 'the stale connect inited last and repointed the wallet at the old server',
      );
    });

    test('a restore never runs two native connects at once', () async {
      await restoreIn('lws', 'lws.example.com:18090');

      // The connection tick's connect, landing inside restoreAll after the
      // restored wallet is marked loaded.
      backend.holdLogin = Completer<void>();
      final releaseFirst = backend.holdLogin!;
      final tickConnect = wallet.connectToDaemon();
      await backend.loginEntered.future;

      // The end of restoreAll, then the glue's syncInBackground().
      await wallet.loadPersistedConnection();
      final load = wallet.load();
      await _settle();

      expect(
        backend.inits,
        hasLength(1),
        reason: 'a second init ran while the first was mid-login',
      );

      releaseFirst.complete();
      await tickConnect;
      await load;
      expect(backend.inits, hasLength(2), reason: 'the new settings still get their own connect');
    });

    test('a connect that finishes for old settings reports nothing for the new', () async {
      await restoreIn('lws', 'old.example.com:18090');

      backend.holdLogin = Completer<void>();
      final releaseOld = backend.holdLogin!;
      final oldConnect = wallet.connectToDaemon();
      await backend.loginEntered.future;

      await save('lws', 'new.example.com:18090');
      expect(wallet.isConnected, isFalse);

      releaseOld.complete();
      await oldConnect;
      expect(
        wallet.isConnected,
        isFalse,
        reason: 'the old server\'s login was reported as the new server\'s connection',
      );
      expect(wallet.hasAttemptedConnection, isFalse);
    });
  });

  group('the LWS<->node rebuild', () {
    test('waits for a running connect before closing the wallet it is in', () async {
      await restoreIn('lws', 'old.example.com:18090');
      final lwsHandle = backend.inits.isEmpty ? null : backend.inits.first.handle;
      expect(lwsHandle, isNull, reason: 'nothing has connected yet');

      backend.holdCaFile = Completer<void>();
      final releaseOld = backend.holdCaFile!;
      final oldConnect = wallet.connectToDaemon();
      await backend.caFileEntered.future;

      await save('node', 'node.example.com:18081');
      final apply = wallet.applyConnectionChange(password: _password);
      await _settle();
      expect(backend.closed, isEmpty, reason: 'the rebuild closed the wallet under the connect');

      releaseOld.complete();
      await oldConnect;
      await apply;

      expect(backend.closed, hasLength(1));
      final closedHandle = backend.closed.single;
      final onClosed = backend.inits.where((i) => i.handle == closedHandle).toList();
      expect(onClosed, hasLength(1));
      expect(
        onClosed.single.lightWallet,
        isTrue,
        reason: 'the LWS wallet was inited with the node flag, which LWSF rejects',
      );
      expect(backend.inits.last.daemonAddress, 'https://node.example.com:18081');
      expect(backend.inits.last.lightWallet, isFalse);
      expect(backend.inits.last.handle, isNot(closedHandle));
    });

    test('waits for the refresh a reconnect tick started', () async {
      await restoreIn('lws', 'old.example.com:18090');

      // The tick's reconnect, now inside its LWS refresh.
      backend.holdRefresh = Completer<void>();
      final releaseRefresh = backend.holdRefresh!;
      await wallet.checkConnectionTask();
      await backend.refreshEntered.future;

      await save('node', 'node.example.com:18081');
      final apply = wallet.applyConnectionChange(password: _password);
      await _settle();
      expect(backend.closed, isEmpty, reason: 'the rebuild closed the wallet under the refresh');

      releaseRefresh.complete();
      await apply;
      expect(backend.closed, hasLength(1));
    });
  });

  group('between saving a new mode and the rebuild', () {
    /// A node wallet partway through its first scan: connected, far behind,
    /// no balance read yet.
    Future<void> scanningOnNode() async {
      await restoreIn('node', 'node.example.com:18081');
      backend.connectedValue = 1;
      backend.synchronizedValue = false;
      backend.walletHeight = 2900000;
      backend.chainHeight = 3500000;
      await wallet.load();
      backend.calls.clear();
    }

    test('the timers leave the old wallet alone', () async {
      await scanningOnNode();

      await save('lws', 'lws.example.com:18090');
      expect(wallet.isActive, isFalse);

      // The 1s tick (a fresh connectivity check, and the reconnect it would
      // fire) and the 20s refresh tick.
      await wallet.checkConnectionTask();
      await _settle();
      await wallet.refreshTask();
      await _settle();

      expect(
        backend.calls,
        isEmpty,
        reason: 'a tick ran LWS calls (the blocking one-shot refresh) on the node wallet',
      );
      expect(
        wallet.isConnected,
        isFalse,
        reason: 'the node wallet\'s connection was read as LWS\'s',
      );
    });

    test('the rebuild ends the gap and the new mode connects', () async {
      await scanningOnNode();

      await save('lws', 'lws.example.com:18090');
      await wallet.applyConnectionChange(password: _password);

      expect(wallet.isActive, isTrue);
      expect(backend.called('closeWallet'), isTrue);
      expect(backend.inits.last.daemonAddress, 'https://lws.example.com:18090');
      expect(backend.inits.last.lightWallet, isTrue);
    });
  });

  group('LWS connection state', () {
    test('a successful login counts as connected before any refresh', () async {
      await restoreIn('lws', 'lws.example.com:18090');
      // LWSF's own connected() stays false after a login until a refresh has
      // set up its feed.
      backend.connectedValue = 0;

      await wallet.connectToDaemon();

      expect(wallet.isConnected, isTrue);
      expect(
        wallet.isReconnectDue(DateTime.now().add(const Duration(hours: 1))),
        isFalse,
        reason: 'a reconnect would re-run init, which logs out again',
      );
    });

    test('a failed refresh drops it, and a failed login never raises it', () async {
      await restoreIn('lws', 'lws.example.com:18090');
      backend.connectedValue = 0;

      await wallet.connectToDaemon();
      expect(await wallet.getIsConnected(), isTrue);

      backend.refreshResult = false;
      await wallet.refresh();
      expect(await wallet.getIsConnected(), isFalse);

      backend.connectToDaemonResult = false;
      await wallet.connectToDaemon();
      expect(wallet.isConnected, isFalse);
    });

    test('node mode still goes by the library', () async {
      await restoreIn('node', 'node.example.com:18081');
      backend.connectedValue = 0;

      await wallet.connectToDaemon();

      expect(wallet.isConnected, isFalse);
    });
  });
}
