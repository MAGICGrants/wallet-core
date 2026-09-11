import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// The subaddress family. Both apps implement this, but only the persistence
/// half had landed here, so the probes that talk to the light-wallet server
/// were missing entirely.
///
/// Two things make this sensitive. The request carries the **private view key**,
/// so where it may and may not go is a privacy property. And handing out a
/// subaddress the server never provisioned means the payment arrives and is
/// never reported.

/// An incoming transaction that consumed subaddress [index] on account 0.
NativeTxInfo _received({
  required String hash,
  required int index,
  int account = 0,
  int height = 3000000,
}) => NativeTxInfo(
  direction: txDirectionIncoming,
  hash: hash,
  amount: BigInt.from(1500000000000),
  fee: BigInt.zero,
  timestamp: 1700000000,
  blockHeight: height,
  confirmations: 10,
  subaddrAccount: account,
  subaddrIndex: '$index',
  isPending: false,
  isFailed: false,
  paymentId: '',
  // Incoming: wallet2 has no key for a transaction it did not sign.
  txKey: '',
);

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;
  late MemoryLogSink logs;

  /// URLs and bodies the unproxied POST path was handed.
  late List<({Uri url, String body})> posts;
  late int postStatus;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_subaddress');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    logs = MemoryLogSink();
    WalletLog.sink = logs;
    WalletLog.isVerbose = () async => true;

    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);

    posts = [];
    postStatus = 200;
    wallet.postJson = (url, body) async {
      posts.add((url: url, body: body));
      return postStatus;
    };
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Defaults to a **loopback** LWS server; a self-hosted `monero-lws`, which
  /// is a real configuration and one where plaintext HTTP is genuinely fine
  /// (loopback is confidential, so the derived scheme stays http).
  ///
  /// It used to default to `lws.example.com:18090`, a routable host, which the
  /// wallet now forces to https. Leaving it there would have made most of this
  /// file assert against an https request, and, before the scheme was derived,
  /// turned the three "wrong route" tests below vacuous by tripping the
  /// confidentiality throw before ever reaching the Tor and proxy logic they
  /// exist to pin.
  void connect({
    String type = 'lws',
    String proxyPort = '',
    bool useTor = false,
    String address = '127.0.0.1:18090',
  }) => wallet.setConnection(
    address: address,
    proxyPort: proxyPort,
    useTor: useTor,
    connectionType: type,
  );

  Future<void> openWallet({String type = 'lws'}) async {
    connect(type: type);
    backend.existingWalletPaths.add(await wallet.walletPathForType(type));
    await wallet.openExisting(password: 'pw');
  }

  Future<String> logged() async {
    await Future<void>.delayed(Duration.zero);
    return logs.records.map((r) => r.line).join('\n');
  }

  group('loadSubaddressSupport', () {
    test('a node needs no probe — it scans locally', () async {
      await openWallet(type: 'node');
      await wallet.loadSubaddressSupport();

      expect(wallet.serverSupportsSubaddresses, isTrue);
      expect(posts, isEmpty, reason: 'no view key leaves the device for a node');
    });

    test('an LWS server is asked, and a 200 means yes', () async {
      await openWallet();
      await wallet.loadSubaddressSupport();

      expect(wallet.serverSupportsSubaddresses, isTrue);
      expect(posts.single.url.toString(), 'http://127.0.0.1:18090/upsert_subaddrs');
      expect(posts.single.body, contains('"get_all":false'));
    });

    test('a server that refuses is recorded as unsupported', () async {
      await openWallet();
      postStatus = 500;
      await wallet.loadSubaddressSupport();

      expect(wallet.serverSupportsSubaddresses, isFalse);
    });

    test('the answer is persisted, so a reopen does not re-probe', () async {
      await openWallet();
      await wallet.loadSubaddressSupport();

      final reopened = MoneroWallet(backend: backend);
      addTearDown(reopened.dispose);
      await reopened.loadPersistedSubaddressState();
      expect(reopened.serverSupportsSubaddresses, isTrue);
    });

    test('a routable host derives https', () async {
      // No SSL toggle: a routable host forces https on its own.
      wallet.setConnection(address: 'lws.example.com:18090', proxyPort: '', useTor: false);
      backend.existingWalletPaths.add(await wallet.walletPathForType('lws'));
      await wallet.openExisting(password: 'pw');
      await wallet.loadSubaddressSupport();

      expect(posts.single.url.scheme, 'https');
    });

    test('a probe failure leaves the flag alone rather than throwing', () async {
      await openWallet();
      wallet.postJson = (url, body) async => throw const SocketException('refused');

      await expectLater(wallet.loadSubaddressSupport(), completes);
      expect(wallet.serverSupportsSubaddresses, isNull);
    });
  });

  group('loadUnusedSubaddressIndex', () {
    test('starts at 1 — index 0 is the primary address', () async {
      await openWallet();
      await wallet.loadUnusedSubaddressIndex();
      expect(wallet.unusedSubaddressIndex, 1);
    });

    test('skips indices the history has already received on', () async {
      backend.transactions = [
        _received(hash: 'a', index: 1),
        _received(hash: 'b', index: 2),
        _received(hash: 'c', index: 4),
      ];
      await openWallet();
      await wallet.refreshTxHistory();
      await wallet.loadUnusedSubaddressIndex();

      // 1 and 2 are used, so the first gap is 3; reusing one would link the two
      // payments to each other for whoever sent them.
      expect(wallet.unusedSubaddressIndex, 3);
    });

    test('a coinbase payout to the primary address consumes no subaddress', () async {
      // p2pool pays index 0, because a coinbase output has to pay a standard
      // address; it cannot pay a subaddress at all. So a mining wallet's history
      // fills with index-0 receipts, and none of them may push the fresh-address
      // walk along: a miner who received a hundred payouts would otherwise be
      // handed subaddress 101 and have ninety-nine provisioned for nothing.
      backend.transactions = [
        _received(hash: 'p2pool-1', index: 0),
        _received(hash: 'p2pool-2', index: 0),
      ];
      await openWallet();
      await wallet.refreshTxHistory();
      await wallet.loadUnusedSubaddressIndex();

      expect(wallet.unusedSubaddressIndex, 1);
    });

    test('only account 0 counts', () async {
      backend.transactions = [_received(hash: 'a', index: 1, account: 7)];
      await openWallet();
      await wallet.refreshTxHistory();
      await wallet.loadUnusedSubaddressIndex();

      expect(wallet.unusedSubaddressIndex, 1);
    });

    test('switching to a node clears a stale not-supported flag', () async {
      // An LWS that has run out of subaddresses persists isSupported: false. The
      // index is shared across both modes, so after the switch it often has not
      // moved -- and the unchanged-index early return must not be allowed to
      // carry that false into node mode, or the receive screen warns about a
      // subaddress limit that only a light-wallet server can have.
      await openWallet();
      wallet.postJson = (url, body) async => throw const SocketException('out of subaddresses');
      await wallet.loadUnusedSubaddressIndex();
      await wallet.setUnusedSubaddressIndex(1, isSupported: false);
      expect(wallet.unusedSubaddressIndexIsSupported, isFalse);

      await openWallet(type: 'node');
      await wallet.loadUnusedSubaddressIndex();

      expect(
        wallet.unusedSubaddressIndexIsSupported,
        isTrue,
        reason: 'a node has no subaddress limit',
      );
      expect(wallet.unusedSubaddressIndex, 1, reason: 'the index itself is unchanged');
    });

    test('an unchanged index does not re-probe the server', () async {
      await openWallet();
      await wallet.loadUnusedSubaddressIndex();
      expect(posts, hasLength(1));

      await wallet.loadUnusedSubaddressIndex();
      expect(posts, hasLength(1), reason: 'the probe carries the view key; do not repeat it');
    });

    test('a node provisions nothing, so no probe and always supported', () async {
      await openWallet(type: 'node');
      await wallet.loadUnusedSubaddressIndex();

      expect(wallet.unusedSubaddressIndex, 1);
      expect(wallet.unusedSubaddressIndexIsSupported, isTrue);
      expect(posts, isEmpty);
    });

    test('a new transaction re-derives the index', () async {
      await openWallet();
      await wallet.loadUnusedSubaddressIndex();
      expect(wallet.unusedSubaddressIndex, 1);

      // Someone pays into index 1; the wallet must stop handing it out.
      backend.transactions = [_received(hash: 'a', index: 1)];
      await wallet.refreshTxHistory();
      await wallet.onTxHistoryGrew();

      expect(wallet.unusedSubaddressIndex, 2);
    });

    test('does not regress the index on an incomplete history (LWS→node switch)', () async {
      // The index pref is shared across modes. LWS had walked it to 6; the node
      // it just switched to has not synced its history yet, so it reads empty.
      await openWallet(type: 'node');
      await wallet.setUnusedSubaddressIndex(6, isSupported: true);
      expect(wallet.unusedSubaddressIndex, 6);

      backend.transactions = [];
      await wallet.refreshTxHistory();
      await wallet.loadUnusedSubaddressIndex();

      // Regressing to 1 would hand out an already-used address until restart.
      expect(wallet.unusedSubaddressIndex, 6);
    });
  });

  group('the receive address', () {
    test('is the subaddress the server provisioned', () async {
      backend.defaultAddress = '8${'s' * 94}';
      await openWallet();
      await wallet.loadSubaddressSupport();
      await wallet.loadUnusedSubaddressIndex();

      expect(wallet.getReceiveAddress(), backend.defaultAddress);
    });

    test('falls back one index when the server would not provision the next', () async {
      // The regression this file exists for. The wallet asks for index 3, the
      // server refuses, so the newest index it will actually scan is 2;
      // handing out 3 means the payment arrives and is never reported.
      backend.transactions = [_received(hash: 'a', index: 1), _received(hash: 'b', index: 2)];
      await openWallet();
      await wallet.refreshTxHistory();

      postStatus = 500;
      await wallet.loadSubaddressSupport();
      await wallet.loadUnusedSubaddressIndex();

      expect(wallet.unusedSubaddressIndex, 3);
      expect(wallet.unusedSubaddressIndexIsSupported, isFalse);
      expect(backend.addressIndexRequests.last, 2, reason: 'the highest index the server accepted');
    });

    test('falls back to the primary address when the server has no subaddresses', () async {
      await openWallet();
      postStatus = 500;
      await wallet.loadSubaddressSupport();
      await wallet.loadPrimaryAddress();

      expect(wallet.serverSupportsSubaddresses, isFalse);
      expect(wallet.getReceiveAddress(), wallet.getPrimaryAddress());
    });

    test('survives a reload with an unchanged index (cache is runtime-only)', () async {
      // The subaddress cache is not persisted; it was only filled inside
      // setUnusedSubaddressIndex, which loadUnusedSubaddressIndex skips when the
      // index is unchanged. So a fresh wallet object (an app restart) that loads
      // the same persisted index left getUnusedSubaddress null, a permanent
      // spinner on the receive screen. load() now refreshes the cache every time.
      backend.defaultAddress = '8${'s' * 94}';
      await openWallet();
      await wallet.load();
      expect(wallet.getUnusedSubaddress(), isNotNull);

      // A second wallet on the same prefs + backend: index reads back from prefs
      // (cache starts null) and loadUnusedSubaddressIndex early-returns.
      final reopened = MoneroWallet(backend: backend);
      reopened.postJson = (url, body) async => 200;
      addTearDown(reopened.dispose);
      reopened.setConnection(
        address: 'lws.example.com:18090',
        proxyPort: '',
        useTor: false,
        connectionType: 'lws',
      );
      await reopened.openExisting(password: 'pw');
      await reopened.load();

      expect(reopened.getUnusedSubaddress(), isNotNull);
    });
  });

  group('the view key does not leave by the wrong route', () {
    test('a Tor connection with no Tor available sends nothing', () async {
      await openWallet();
      await TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);
      connect(useTor: true);

      // Fail closed. Falling back to clearnet here would hand the view key
      // (and with it every incoming transaction, forever) to a passive observer.
      await expectLater(wallet.isSubaddressSupported(1), throwsA(isA<Exception>()));
      expect(posts, isEmpty);
    });

    test('a custom SOCKS port is used instead of a direct request', () async {
      await openWallet();
      // A custom proxy port must be honoured, not bypassed.
      connect(proxyPort: '9050');

      // Nothing is listening on 9050, so the SOCKS attempt fails, which is the
      // point: it went to the proxy rather than around it.
      await expectLater(wallet.isSubaddressSupported(1), throwsA(anything));
      expect(posts, isEmpty);
    });

    test('a proxy port that is not a number is an error, not a direct request', () async {
      await openWallet();
      connect(proxyPort: 'not-a-port');

      await expectLater(wallet.isSubaddressSupported(1), throwsA(isA<Exception>()));
      expect(posts, isEmpty);
    });

    test('a wallet that is not open cannot probe', () async {
      connect();
      expect(wallet.isSubaddressSupported(1), throwsA(isA<StateError>()));
    });
  });

  group('the view key leaves only over a protected channel', () {
    // The fail-closed Tor logic above answers "is the IP hidden". These answer
    // "are the bytes protected". There is no `useSsl` toggle: the
    // scheme is derived from the host, so a routable host is forced to https and
    // the view key is never sent in the clear, while an onion or LAN host
    // (each already confidential) stays plaintext. The upsert's
    // `requireConfidentialChannel` therefore cannot fire under the derivation; it
    // is defence in depth against a future derivation bug. These pin the derived
    // scheme on the direct path, which is the one the `postJson` seam records.

    test('a routable host is forced to https, never sent in the clear', () async {
      await openWallet();
      connect(address: 'lws.example.com:18090');

      expect(await wallet.isSubaddressSupported(1), isTrue);
      expect(posts.single.url.scheme, 'https');
    });

    test('an onion service is used in the clear — the address is the key', () async {
      await openWallet();
      const v3 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa234567';
      connect(address: '$v3.onion:18090');

      expect(await wallet.isSubaddressSupported(1), isTrue);
      expect(posts.single.url.scheme, 'http');
      expect(posts.single.url.host, '$v3.onion');
    });

    test('a LAN server is used in the clear', () async {
      await openWallet();
      connect(address: '192.168.1.50:18090');

      expect(await wallet.isSubaddressSupported(1), isTrue);
      expect(posts.single.url.scheme, 'http');
    });

    test('a routable host still loads without throwing out of the load path', () async {
      // Both callers catch, and the request now succeeds over https rather than
      // being refused, either way the load path completes.
      await openWallet();
      connect(address: 'lws.example.com:18090');

      await expectLater(wallet.loadSubaddressSupport(), completes);
      await expectLater(wallet.loadUnusedSubaddressIndex(), completes);
    });
  });

  group('logging', () {
    test('names neither the view key nor the primary address', () async {
      backend.secretViewKeyValue = 'a-real-view-key-would-be-64-hex-chars';
      backend.defaultAddress = '4${'p' * 94}';
      await openWallet();
      await wallet.loadPrimaryAddress();
      await wallet.loadSubaddressSupport();

      final written = await logged();
      expect(written, isNotEmpty, reason: 'the assertions below would be vacuous');
      expect(written, isNot(contains(backend.secretViewKeyValue)));
      expect(written, isNot(contains(backend.defaultAddress)));
      // Still diagnosable: the endpoint is the user's own configuration, and the
      // index and status code are what a support thread actually needs.
      expect(written, contains('127.0.0.1:18090'));
      expect(written, contains('index 1'));
    });

    test('the body sent to the server does carry the view key — only the log does not', () async {
      backend.secretViewKeyValue = 'the-view-key';
      await openWallet();
      await wallet.loadSubaddressSupport();

      // Worth pinning: a "redaction" that removed it from the request too would
      // silently break provisioning while looking like a privacy improvement.
      expect(posts.single.body, contains('the-view-key'));
    });
  });
}
