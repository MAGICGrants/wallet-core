import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Deleting a wallet frees the native handle, and `CryptoWallet` documents what
/// a timer tick racing that free costs: "a use-after-free on the freed handle;
/// a SIGSEGV in the native lib, not a Dart exception".
///
/// [CryptoWallet.runWithSyncSuspended] is the guard for it, and the LWS<->node
/// rebuild already takes it (see `monero_mode_switch_test.dart`, "a timer tick
/// during the close is a no-op"). Delete closes the same handle and must hold
/// the timers off the same way.

const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _password = 'the-existing-password';

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('delete_race');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void connect(String type) => wallet.setConnection(
    address: type == 'node' ? 'node.example.com:18081' : 'lws.example.com:18090',
    proxyPort: '',
    useTor: false,
    connectionType: type,
  );

  Future<void> openIn(String mode) async {
    connect(mode);
    await wallet.restoreFromSeed(
      seed: MoneroLegacySeed(_legacy25),
      from: RestorePoint.height(2_800_000),
      password: _password,
    );
    final path = await wallet.walletPathForType(mode);
    await File(path).writeAsString('wallet');
    backend.existingWalletPaths.add(path);
    backend.reset();
  }

  test('a timer tick during delete is a no-op', () async {
    await openIn('node');

    final closeGate = Completer<void>();
    backend.pauseNextClose = closeGate;
    backend.closeStarted = Completer<void>();

    // Start the delete; it blocks in closeWallet with the handle mid-free.
    final deleting = wallet.delete();
    await backend.closeStarted!.future;

    final callsAtClose = List.of(backend.calls);

    // Drive the timers by hand, the way the periodic ones would fire here: the
    // connection tick runs every second while a wallet is syncing, so this is
    // the window a user lands in by tapping Delete on a syncing wallet.
    await wallet.refreshTask();
    await wallet.checkConnectionTask();

    expect(
      backend.calls,
      callsAtClose,
      reason: 'refresh/connection ticks must not touch the wallet during a delete',
    );

    closeGate.complete();
    await deleting;
  });

  test('delete waits for a tick already inside a native call', () async {
    await openIn('node');

    // Pin a connection tick inside walletStats -- the native call the 1s poll
    // sits in while a wallet syncs.
    final statsGate = Completer<void>();
    backend.pauseNextWalletStats = statsGate;
    backend.walletStatsStarted = Completer<void>();

    final tick = wallet.checkConnectionTask();
    await backend.walletStatsStarted!.future;

    // Delete now. The handle must not be freed while that call is outstanding:
    // the drain in runWithSyncSuspended is the other half of the guard, for the
    // tick that started before the delete rather than after it.
    final deleting = wallet.delete();
    await pumpEventQueue();

    expect(
      backend.called('closeWallet'),
      isFalse,
      reason: 'the handle was freed with a native call still outstanding',
    );

    statsGate.complete();
    await tick;
    await deleting;

    expect(backend.called('closeWallet'), isTrue);
  });
}
