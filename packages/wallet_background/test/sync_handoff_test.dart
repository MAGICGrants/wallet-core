import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_background/wallet_background.dart';
import 'package:wallet_domain/wallet_domain.dart';

/// The app and the Continuous Sync service take turns holding the wallets,
/// never both: two holders in one process are two writers on the same files.

/// The app's wallets, as far as the link can see them.
class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  bool open = false;
  int announced = 0;

  @override
  List<CryptoWallet> get loadedWallets => open ? [_Loaded()] : const <CryptoWallet>[];

  @override
  List<CryptoWallet> get activeWallets => const [];

  @override
  Future<void> notifyNewIncomingTxsAll({bool announce = true}) async => announced++;
}

/// Only its presence in [_Manager.loadedWallets] matters.
class _Loaded extends Fake implements CryptoWallet {}

/// The service, as the link reaches it: records what it is told, and lets go
/// when asked unless [answers] is false.
class _Service extends SyncLinkTransport {
  bool running = true;
  bool answers = true;
  int restarts = 0;
  final sent = <Map<String, Object>>[];
  late ForegroundSyncLink link;

  @override
  Future<bool> isServiceRunning() async => running;

  @override
  void sendToService(Map<String, Object> message) {
    sent.add(message);
    if (answers && SyncMessage.opOf(message) == 'hello') {
      scheduleMicrotask(() => link.onMessage(SyncMessage.released));
    }
  }

  @override
  Future<void> restartService() async => restarts++;
}

void main() {
  group('SyncHandoff (the service side)', () {
    test('the app that started the service holds until it says otherwise', () {
      final h = SyncHandoff();
      h.onTick();
      h.onTick();
      expect(h.serviceShouldHold, isFalse);
    });

    test('an app that stops answering is gone: the service takes over', () {
      final h = SyncHandoff(missedPongLimit: 2);
      for (var i = 0; i < 3; i++) {
        h.onTick();
      }
      expect(h.serviceShouldHold, isTrue);
      h.onPong(appHolds: true);
      expect(h.serviceShouldHold, isFalse, reason: 'it is back, and holds');
    });

    test('an app at its lock screen with nothing open: the service holds', () {
      final h = SyncHandoff()..onPong(appHolds: false);
      expect(h.serviceShouldHold, isTrue);
    });

    test('hello: the app holds from now on', () {
      final h = SyncHandoff()..onPong(appHolds: false);
      h.onHello();
      expect(h.serviceShouldHold, isFalse);
    });
  });

  group('ForegroundSyncLink (the app side)', () {
    late _Manager manager;
    late _Service service;
    late ForegroundSyncLink link;
    late DateTime now;

    setUp(() {
      manager = _Manager();
      service = _Service();
      now = DateTime.utc(2026, 10, 16, 12);
      link = ForegroundSyncLink(
        manager: manager,
        transport: service,
        claimTimeout: const Duration(milliseconds: 50),
        clock: () => now,
      );
      service.link = link;
    });

    tearDown(() => manager.dispose());

    Map<String, Object> lastPong() => service.sent.lastWhere((m) => SyncMessage.opOf(m) == 'pong');

    test('claim waits for the service to let go before anything opens', () async {
      await link.claim();
      expect(service.sent.map(SyncMessage.opOf), ['hello']);
      expect(service.restarts, 0);
    });

    test('a service that does not let go is restarted, never shared', () async {
      service.answers = false;
      await link.claim();
      expect(service.restarts, 1);
    });

    test('no service running: nothing to ask', () async {
      service.running = false;
      await link.claim();
      expect(service.sent, isEmpty);
    });

    test('at the lock screen with nothing open, the app says it holds nothing', () {
      link.onMessage(SyncMessage.ping);
      expect(lastPong()['holds'], isFalse);
      expect(manager.announced, 0, reason: 'the service announces then');
    });

    test('with its wallets open the app holds them and announces itself', () {
      manager.open = true;
      link.onMessage(SyncMessage.ping);
      expect(lastPong()['holds'], isTrue);
      expect(manager.announced, 1);
    });

    test('claim asks a periodic run holding the wallets first, then the service', () async {
      final asked = <String>[];
      final spared = <String?>[];
      link = ForegroundSyncLink(
        manager: manager,
        transport: service,
        claimTimeout: const Duration(milliseconds: 50),
        ask: (name, message, timeout) async {
          asked.add('$name ${SyncMessage.opOf(message)}');
          return SyncMessage.released;
        },
        closeOrphans: ({exceptToken}) async => spared.add(exceptToken),
      );
      service.link = link;
      await link.claim();
      expect(asked, ['${WalletHolders.periodicRunName} hello']);
      // Wallets an earlier app isolate left open are closed; never its own.
      expect(spared, [WalletIsolate.token]);
      expect(service.sent.map(SyncMessage.opOf), ['hello']);
    });

    test('answers a periodic run: holding nothing, it may run', () async {
      final reply = ReceivePort();
      link.onHolderMessage({...WalletHolders.holdsQuery, 'reply': reply.sendPort});
      expect(await reply.first, {'op': 'holds', 'holds': false, 'token': WalletIsolate.token});
      expect(manager.announced, 0);
    });

    test('answers a periodic run: holding them, it skips, and the app announces', () async {
      manager.open = true;
      final reply = ReceivePort();
      link.onHolderMessage({...WalletHolders.holdsQuery, 'reply': reply.sendPort});
      expect(await reply.first, {'op': 'holds', 'holds': true, 'token': WalletIsolate.token});
      expect(manager.announced, 1);
    });

    test('a claim holds while the open it precedes runs, not forever', () async {
      await link.claim();
      link.onMessage(SyncMessage.ping);
      expect(lastPong()['holds'], isTrue);

      now = now.add(const Duration(minutes: 3));
      link.onMessage(SyncMessage.ping);
      expect(lastPong()['holds'], isFalse, reason: 'the open never loaded anything');
    });
  });
}
