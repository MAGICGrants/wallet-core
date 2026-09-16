import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// Connection settings are stored **per connection type**.
///
/// The bug that motivated it: an interrupted LWS→node switch left the mode and
/// the address disagreeing, and a light-wallet session then POSTed the private
/// view key to the user's own node. A guard at the send would have caught that
/// one request; storing the server under its type means the two cannot disagree
/// in the first place, whatever route the type took to change.
///
/// The property that makes it structural rather than merely careful: reads are
/// keyed by type, so a stale or half-written type selects *its own* server. The
/// pair is always self-consistent, even when it is out of date.

/// A coin with a server-kind toggle, as Monero has.
class _TypedWallet extends FakeWallet {
  _TypedWallet(super.symbol);

  @override
  List<String> get connectionTypeOptions => const ['lws', 'node'];
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conn_type');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    // Spice namespaces prefs as `xmr_<key>`; the legacy/torn-write tests below
    // have to name keys exactly, so the scheme matters.
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  _TypedWallet typed() {
    final w = _TypedWallet('XMR');
    addTearDown(w.dispose);
    return w;
  }

  /// Saves [address] under [type] and leaves that type active.
  Future<void> save(CryptoWallet w, String type, String address, {String proxyPort = ''}) async {
    w.setConnection(address: address, proxyPort: proxyPort, useTor: false, connectionType: type);
    await w.persistCurrentConnection();
  }

  group('each type keeps its own server', () {
    test('both are stored, and neither overwrites the other', () async {
      final w = typed();
      await save(w, 'lws', 'lws.example.com:18090');
      await save(w, 'node', 'node.example.com:18081');

      expect((await w.getPersistedConnectionForType('lws')).address, 'lws.example.com:18090');
      expect((await w.getPersistedConnectionForType('node')).address, 'node.example.com:18081');
    });

    test('a fresh launch loads the active type and its own server', () async {
      final w = typed();
      await save(w, 'lws', 'lws.example.com:18090');
      await save(w, 'node', 'node.example.com:18081');

      final fresh = typed();
      await fresh.loadPersistedConnection();

      expect(fresh.connectionType, 'node');
      expect(fresh.connectionAddress, 'node.example.com:18081');
    });

    test('a type with nothing stored reads back empty, not the other type', () async {
      // The alternative — falling back to whatever server exists — is the bug:
      // an unconfigured node mode would inherit the LWS server, and vice versa.
      final w = typed();
      await save(w, 'lws', 'lws.example.com:18090');

      final node = await w.getPersistedConnectionForType('node');
      expect(node.address, isEmpty);
      expect(node.connectionType, 'node');
    });

    test('the proxy and Tor settings are per type too', () async {
      final w = typed();
      await save(w, 'lws', 'lws.example.com:18090', proxyPort: '1080');
      await save(w, 'node', 'node.example.com:18081');

      expect((await w.getPersistedConnectionForType('lws')).proxyPort, '1080');
      expect((await w.getPersistedConnectionForType('node')).proxyPort, isEmpty);
    });
  });

  group('a half-written switch cannot cross the modes', () {
    test('a stale active type selects its own server, not the new one', () async {
      final w = typed();
      await save(w, 'lws', 'lws.example.com:18090');
      await save(w, 'node', 'node.example.com:18081');

      // `persistCurrentConnection` writes the record and the active type last,
      // so this is the state a crash mid-save leaves: the node server is on
      // disk, the active type still says lws. Before the split this read back
      // as "lws mode, node address" — the mismatch that leaked the view key.
      await SharedPreferencesService.set<String>('xmr_connectionType', 'lws');

      final fresh = typed();
      await fresh.loadPersistedConnection();

      expect(fresh.connectionType, 'lws');
      expect(fresh.connectionAddress, 'lws.example.com:18090');
    });

    test('an active type naming a mode never configured is unconfigured, not wrong', () async {
      final w = typed();
      await save(w, 'lws', 'lws.example.com:18090');
      await SharedPreferencesService.set<String>('xmr_connectionType', 'node');

      final fresh = typed();
      await fresh.loadPersistedConnection();

      expect(fresh.connectionType, 'node');
      expect(fresh.connectionAddress, isEmpty);
      // `isActive` requires an address, so the wallet reads as unconfigured and
      // the user lands in the setup form rather than on the wrong server.
      expect(fresh.isActive, isFalse);
    });
  });

  group('a pre-split install migrates into the right slot', () {
    /// The flat record shipped before the per-type split.
    Future<void> legacyRecord({required String address, String? type, String proxy = ''}) async {
      await SharedPreferencesService.set<String>('xmr_connectionAddress', address);
      await SharedPreferencesService.set<String>('xmr_connectionProxyPort', proxy);
      await SharedPreferencesService.set<bool>('xmr_connectionUseTor', false);
      if (type != null) await SharedPreferencesService.set<String>('xmr_connectionType', type);
    }

    test('the server is kept, under the type it was saved with', () async {
      await legacyRecord(address: 'old-lws.example.com:18090', type: 'lws', proxy: '1080');

      final w = typed();
      await w.loadPersistedConnection();

      expect(w.connectionAddress, 'old-lws.example.com:18090');
      expect(w.connectionProxyPort, '1080');
      expect(w.connectionType, 'lws');
    });

    test('a node record does not migrate into the LWS slot', () async {
      // Reading the flat record for whichever type asks would recreate the
      // exact defect: an LWS mode holding a node address.
      await legacyRecord(address: 'old-node.example.com:18081', type: 'node');

      final w = typed();
      expect((await w.getPersistedConnectionForType('lws')).address, isEmpty);
      expect((await w.getPersistedConnectionForType('node')).address, 'old-node.example.com:18081');
    });

    test('a record with no type at all belongs to the default mode', () async {
      // `''` was savable, and means the first option rather than a third mode.
      await legacyRecord(address: 'legacy.example.com:18090');

      final w = typed();
      expect((await w.getPersistedConnectionForType('lws')).address, 'legacy.example.com:18090');
      expect((await w.getPersistedConnectionForType('node')).address, isEmpty);
    });

    test('the old server survives a switch to the other mode and back', () async {
      // The upgrade path in full, and the reason the copy happens on load rather
      // than being left to the read fallback: that fallback only finds the flat
      // record while `connectionType` still names its type, so the first switch
      // to node would have stranded this user's LWS server for good.
      await legacyRecord(address: 'old-lws.example.com:18090', type: 'lws', proxy: '1080');

      final first = typed();
      await first.loadPersistedConnection();

      // Switch to a node and save.
      first.setConnection(
        address: 'node.example.com:18081',
        proxyPort: '',
        useTor: false,
        connectionType: 'node',
      );
      await first.persistCurrentConnection();

      // Both modes are now remembered independently.
      expect((await first.getPersistedConnectionForType('node')).address, 'node.example.com:18081');
      final lws = await first.getPersistedConnectionForType('lws');
      expect(lws.address, 'old-lws.example.com:18090');
      expect(lws.proxyPort, '1080');

      // And switching back lands on the original server, not the node.
      first.setConnection(
        address: lws.address,
        proxyPort: lws.proxyPort,
        useTor: lws.useTor,
        connectionType: 'lws',
      );
      await first.persistCurrentConnection();

      final next = typed();
      await next.loadPersistedConnection();
      expect(next.connectionType, 'lws');
      expect(next.connectionAddress, 'old-lws.example.com:18090');
    });

    test('the copy runs once and never overwrites a real per-type record', () async {
      await legacyRecord(address: 'old-lws.example.com:18090', type: 'lws');
      final w = typed();
      await save(w, 'lws', 'new-lws.example.com:18090');

      // A second load must not resurrect the stale flat record over the top.
      await w.loadPersistedConnection();
      expect(w.connectionAddress, 'new-lws.example.com:18090');
    });

    test('re-saving moves it to the per-type key and stops consulting the old one', () async {
      await legacyRecord(address: 'old-lws.example.com:18090', type: 'lws');
      final w = typed();
      await w.loadPersistedConnection();
      await w.persistCurrentConnection();

      // The flat key is now irrelevant: changing it must not move the wallet.
      await SharedPreferencesService.set<String>('xmr_connectionAddress', 'attacker.example.com');

      final fresh = typed();
      await fresh.loadPersistedConnection();
      expect(fresh.connectionAddress, 'old-lws.example.com:18090');
    });
  });

  group('a coin with no server-kind toggle is untouched', () {
    test('it keeps the flat keys, so nothing to migrate', () async {
      final btc = FakeWallet('BTC');
      addTearDown(btc.dispose);
      await save(btc, '', 'electrum.example.com:50002');

      expect(
        await SharedPreferencesService.get<String>('btc_connectionAddress'),
        'electrum.example.com:50002',
      );

      final fresh = FakeWallet('BTC');
      addTearDown(fresh.dispose);
      await fresh.loadPersistedConnection();
      expect(fresh.connectionAddress, 'electrum.example.com:50002');
      expect(fresh.connectionType, isEmpty);
    });
  });
}
