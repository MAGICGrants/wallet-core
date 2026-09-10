import 'dart:convert';
import 'dart:io';

import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_bitcoin/wallet_bitcoin.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// `BitcoinChainWallet` orchestration against [FakeElectrumClient].
///
/// The groups run in risk order: derivation, persistence, the scripthash/refresh
/// layer, history, and the send path last, where a mistake costs money rather
/// than a wrong display.
const _mnemonic =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _password = 'wallet-password';

// BIP84's own test vectors for this mnemonic at account m/84'/0'/0'. Treat a
// failure here the way the Monero vectors are treated: the change is wrong, not
// the vector.
const _receive0 = 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu';
const _receive1 = 'bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g';
const _change0 = 'bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el';

/// Somebody else's address, for the outgoing-transaction shapes. BIP173's
/// mainnet P2WPKH example.
const _theirs = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';

final _txidIn = 'a1${'0' * 62}';
final _txidOut = 'b2${'0' * 62}';

/// The persisted `cachedTxBlobs` entries, decrypted off disk.
///
/// Read through [WalletCacheStore] rather than the wallet's own
/// `cacheGetString`, which is `@protected`, and going to the file is the
/// stronger assertion anyway: it is what a restart actually reads.
Future<List<Map<String, dynamic>>> _persistedTxBlobs() async {
  final cache = await WalletCacheStore.load('BTC', _password);
  final blob = cache['cachedTxBlobs'] as String?;
  if (blob == null) return const [];
  final entries = (jsonDecode(blob) as Map<String, dynamic>)['entries'] as List<dynamic>;
  return entries.cast<Map<String, dynamic>>();
}

String _sh(String address) =>
    BitcoinAddressUtils.scriptHash(address, network: BitcoinNetwork.mainnet);

void main() {
  late Directory tmp;
  late FakeElectrumClient fake;
  late BitcoinWallet wallet;
  late MemoryLogSink logs;

  // Real PBKDF2 at the production round count, run in pure Dart, costs seconds
  // per wallet-file round trip and most cases here do at least one.
  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bitcoin_wallet');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    logs = MemoryLogSink();
    WalletLog.sink = logs;
    WalletLog.isVerbose = () async => true;
    fake = FakeElectrumClient();
    wallet = BitcoinWallet(client: fake);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Everything written to the log sink so far.
  ///
  /// `walletLog` does not await `log()`, and `log()` awaits the verbose check
  /// before writing; so a line emitted immediately before a `throw` has not
  /// reached the sink yet when the test resumes. Yielding to the event loop
  /// drains the pending microtasks.
  Future<String> logged() async {
    await Future<void>.delayed(Duration.zero);
    return logs.records.map((r) => r.line).join('\n');
  }

  Future<void> restore() => wallet.restoreFromSeed(
    seed: const Bip39Seed(_mnemonic),
    from: RestorePoint.date(DateTime.utc(2026, 3, 14)),
    password: _password,
  );

  void setConnection() =>
      wallet.setConnection(address: 'electrum.example.com:50002', proxyPort: '', useTor: false);

  /// Answers the subscribe/history/listunspent trio for the scripthashes in
  /// [used], and reports "no history" for everything else, which is what makes
  /// the gap-limit walk terminate.
  void scriptUsed(Map<String, ({int valueSats, int height, String txHash, int vout})> used) {
    String? statusFor(String sh) => used.containsKey(sh) ? 'status-$sh' : null;

    fake.handlers['blockchain.scripthash.subscribe'] = (params) => statusFor(params[0] as String);
    fake.handlers['blockchain.scripthash.get_history'] = (params) {
      final entry = used[params[0] as String];
      if (entry == null) return <Map<String, dynamic>>[];
      return [ElectrumFixtures.historyEntry(txHash: entry.txHash, height: entry.height)];
    };
    fake.handlers['blockchain.scripthash.listunspent'] = (params) {
      final entry = used[params[0] as String];
      if (entry == null) return <Map<String, dynamic>>[];
      return [
        ElectrumFixtures.utxo(
          txHash: entry.txHash,
          vout: entry.vout,
          valueSats: entry.valueSats,
          height: entry.height,
        ),
      ];
    };
    // The history read asks for each discovered transaction; nothing in these
    // cases needs the body, so answer with an error rather than a wrong shape.
    fake.failing['blockchain.transaction.get'] = StateError('no tx bodies in this fixture');
  }

  Future<void> connectAndRefresh() async {
    setConnection();
    await wallet.connectToDaemon();
    await wallet.refresh();
  }

  group('derivation is pinned to the BIP84 vectors', () {
    test('mainnet receive and change addresses', () {
      final boot = bootstrapBitcoinWalletFromMnemonic(
        mnemonic: _mnemonic,
        bip84AccountPath: "m/84'/0'/0'",
        coinSymbol: 'BTC',
        isTestnet: false,
        gapLimit: 2,
        externalChain: 0,
        internalChain: 1,
      );

      String at({required int index, required bool change}) =>
          boot.addresses.firstWhere((a) => a.index == index && a.isChange == change).address;

      expect(at(index: 0, change: false), _receive0);
      expect(at(index: 1, change: false), _receive1);
      expect(at(index: 0, change: true), _change0);
    });

    test('testnet uses a different account path, so a different wallet', () {
      final boot = bootstrapBitcoinWalletFromMnemonic(
        mnemonic: _mnemonic,
        bip84AccountPath: "m/84'/1'/0'",
        coinSymbol: 'TBTC',
        isTestnet: true,
        gapLimit: 1,
        externalChain: 0,
        internalChain: 1,
      );
      final first = boot.addresses.firstWhere((a) => !a.isChange).address;
      expect(first, startsWith('tb1'));
      expect(first, isNot(_receive0));
    });

    test('the account xprv is carried out so a reopen skips the KDF', () {
      final boot = bootstrapBitcoinWalletFromMnemonic(
        mnemonic: _mnemonic,
        bip84AccountPath: "m/84'/0'/0'",
        coinSymbol: 'BTC',
        isTestnet: false,
        gapLimit: 1,
        externalChain: 0,
        internalChain: 1,
      );
      expect(boot.accountXprv, isNotNull);
      expect(boot.accountXprv, startsWith('xprv'));
    });
  });

  group('lifecycle', () {
    test('no wallet before a restore, one after', () async {
      expect(await wallet.hasExistingWallet(), isFalse);
      await restore();
      expect(await wallet.hasExistingWallet(), isTrue);
      expect(wallet.isLoaded, isTrue);
      expect(wallet.getPrimaryAddress(), _receive0);
    });

    test('a restored wallet reopens to the same addresses', () async {
      await restore();

      final reopened = BitcoinWallet(client: FakeElectrumClient());
      addTearDown(reopened.dispose);
      await reopened.openExisting(password: _password);

      expect(reopened.getPrimaryAddress(), _receive0);
      expect(reopened.getReceiveAddress(), _receive0);
    });

    test('the wrong password fails to open rather than opening something else', () async {
      await restore();
      final reopened = BitcoinWallet(client: FakeElectrumClient());
      addTearDown(reopened.dispose);
      expect(reopened.openExisting(password: 'wrong'), throwsA(isA<FormatException>()));
    });

    test('a polyseed is refused — Bitcoin cannot derive from one', () async {
      expect(
        wallet.restoreFromSeed(
          seed: const PolyseedSeed('sixteen words which this coin cannot use at all ok'),
          from: const RestorePoint.newWallet(),
          password: _password,
        ),
        throwsA(isA<UnsupportedSeedFormatException>()),
      );
    });

    test('a seed passphrase is refused rather than silently ignored', () async {
      // Honouring it would change every derived address, and the wallet file has
      // nowhere to persist it; so the next open would come up empty.
      expect(
        wallet.restoreFromSeed(
          seed: const Bip39Seed(_mnemonic, passphrase: 'extra'),
          from: const RestorePoint.newWallet(),
          password: _password,
        ),
        throwsA(isA<UnsupportedSeedFormatException>()),
      );
    });

    test('an empty password is refused', () async {
      expect(
        wallet.restoreFromSeed(
          seed: const Bip39Seed(_mnemonic),
          from: const RestorePoint.newWallet(),
          password: '',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('a height restore point is recorded where getRestoreHeight reads it', () async {
      await wallet.restoreFromSeed(
        seed: const Bip39Seed(_mnemonic),
        from: const RestorePoint.height(800000),
        password: _password,
      );
      expect(await wallet.getRestoreHeight(), 800000);
    });

    test('delete removes the file and the in-memory state', () async {
      await restore();
      await wallet.deleteFiles();
      expect(await wallet.hasExistingWallet(), isFalse);
      expect(await wallet.getCurrentHeight(), 0);
    });
  });

  group('connect', () {
    test('parses host:port and subscribes to headers', () async {
      await restore();
      setConnection();
      await wallet.connectToDaemon();

      expect(fake.connections.single.host, 'electrum.example.com');
      expect(fake.connections.single.port, 50002);
      expect(fake.calls, contains('blockchain.headers.subscribe'));
      expect(wallet.isConnected, isTrue);
      // headerSubscription's default height, picked up as the chain tip.
      expect(await wallet.getCurrentHeight(), 800000);
    });

    test('a malformed address is rejected before a socket is opened', () async {
      await restore();
      wallet.setConnection(address: 'electrum.example.com', proxyPort: '', useTor: false);
      expect(wallet.connectToDaemon(), throwsA(isA<FormatException>()));
      expect(fake.connections, isEmpty);
    });

    test('a non-numeric port is rejected', () async {
      await restore();
      wallet.setConnection(address: 'electrum.example.com:https', proxyPort: '', useTor: false);
      expect(wallet.connectToDaemon(), throwsA(isA<FormatException>()));
    });

    test('connecting twice reuses the socket', () async {
      await restore();
      setConnection();
      await wallet.connectToDaemon();
      await wallet.connectToDaemonImpl(address: 'electrum.example.com:50002');
      expect(fake.countOf('connect'), 1);
    });

    group('TLS is derived from the host, not a toggle', () {
      // Electrum is raw TCP with no scheme, so there is no `useSsl` to set. A
      // routable server is connected with TLS; an onion or local one is left
      // plaintext, since each is already confidential without it.
      test('a routable host connects with TLS', () async {
        await restore();
        await wallet.connectToDaemonImpl(address: 'electrum.example.com:50002');
        expect(fake.connections.single.useSsl, isTrue);
      });

      test('an onion host connects in the clear — the circuit is the encryption', () async {
        await restore();
        const v3 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa234567';
        await wallet.connectToDaemonImpl(address: '$v3.onion:50001');
        expect(fake.connections.single.useSsl, isFalse);
      });

      test('a LAN host connects in the clear', () async {
        await restore();
        await wallet.connectToDaemonImpl(address: '192.168.1.50:50001');
        expect(fake.connections.single.useSsl, isFalse);
      });
    });
  });

  group('refresh and balances', () {
    test('sums confirmed and unconfirmed across scripthashes', () async {
      await restore();
      scriptUsed({
        _sh(_receive0): (valueSats: 150000, height: 799990, txHash: _txidIn, vout: 0),
        _sh(_change0): (valueSats: 25000, height: 0, txHash: _txidOut, vout: 1),
      });
      await connectAndRefresh();
      await wallet.loadTotalBalance();
      await wallet.loadUnlockedBalance();

      expect(wallet.totalBalanceBaseUnits, BigInt.from(175000));
      // Bitcoin has no lock; the pending output is spendable.
      expect(wallet.unlockedBalanceBaseUnits, BigInt.from(175000));
      expect(wallet.canSpendPendingBalance, isTrue);
    });

    test('an unused wallet stops after one gap-limit window per chain', () async {
      await restore();
      scriptUsed(const {});
      await connectAndRefresh();

      // 10 receive + 10 change subscribes, and nothing to fetch after them.
      expect(fake.countOf('blockchain.scripthash.subscribe'), 20);
      expect(fake.countOf('blockchain.scripthash.get_history'), 0);
      expect(wallet.getReceiveAddress(), _receive0);
    });

    test('a used index advances the receive address and extends the walk', () async {
      await restore();
      scriptUsed({_sh(_receive0): (valueSats: 1000, height: 800000, txHash: _txidIn, vout: 0)});
      await connectAndRefresh();

      // Index 0 is used, so the walk opens a second window on that chain.
      expect(fake.countOf('blockchain.scripthash.subscribe'), 30);
      expect(wallet.getReceiveAddress(), _receive1);
    });

    test('an unchanged status skips the refetch on the next refresh', () async {
      await restore();
      scriptUsed({_sh(_receive0): (valueSats: 1000, height: 800000, txHash: _txidIn, vout: 0)});
      await connectAndRefresh();
      final firstFetches = fake.countOf('blockchain.scripthash.get_history');
      expect(firstFetches, 1);

      await wallet.refresh();
      expect(fake.countOf('blockchain.scripthash.get_history'), firstFetches);
    });

    test('a status push marks the scripthash stale and it is refetched', () async {
      await restore();
      final sh = _sh(_receive0);
      scriptUsed({sh: (valueSats: 1000, height: 800000, txHash: _txidIn, vout: 0)});
      await connectAndRefresh();

      fake.pushScripthashStatus(sh, 'a-different-status');
      await wallet.refresh();
      expect(fake.countOf('blockchain.scripthash.get_history'), 2);
    });

    test('a dropped connection clears the subscriptions so reconnect resubscribes', () async {
      await restore();
      scriptUsed(const {});
      await connectAndRefresh();
      expect(fake.countOf('blockchain.scripthash.subscribe'), 20);

      fake.dropConnection();
      await fake.connect(host: 'electrum.example.com', port: 50002);
      await wallet.refresh();
      expect(fake.countOf('blockchain.scripthash.subscribe'), 40);
    });

    test('refresh is a no-op while disconnected rather than an error', () async {
      await restore();
      await wallet.refresh();
      expect(fake.batches, isEmpty);
    });

    test('sync state follows the header subscription', () async {
      await restore();
      scriptUsed(const {});
      await connectAndRefresh();
      await wallet.loadIsSynced();
      await wallet.loadSyncedHeight();
      expect(wallet.isSynced, isTrue);
      expect(wallet.syncedHeight, 800000);
    });
  });

  group('transaction history', () {
    /// Seeds the tx cache the way a reopen does, through the encrypted cache,
    /// so this covers `_loadTxCache` as well as the rendering.
    Future<void> seedTxCache(List<Map<String, dynamic>> verboseMaps) async {
      final entries = [
        for (final (i, v) in verboseMaps.indexed)
          {
            'txid': v['txid'],
            'verbose': v,
            'height': v['height'] ?? 0,
            'first_seen_at': 1700000000 + i,
          },
      ];
      wallet.setCachePassword(_password);
      await WalletCacheStore.save('BTC', {
        'cachedTxBlobs': jsonEncode({'entries': entries}),
      }, _password);
      setConnection();
      await wallet.loadCache();
      await wallet.loadPersistedSnapshot();
    }

    Map<String, dynamic> incoming() => {
      'hash': _txidIn,
      'txid': _txidIn,
      'height': 800000,
      'blocktime': 1700000100,
      // An input we know nothing about, which is what makes this incoming.
      'vin': <Map<String, dynamic>>[<String, dynamic>{}],
      'vout': [
        {
          'value': 0.0005,
          'scriptPubKey': {'address': _receive0},
        },
      ],
    };

    Map<String, dynamic> outgoing() => {
      'hash': _txidOut,
      'txid': _txidOut,
      'height': 800001,
      'blocktime': 1700000200,
      'vin': [
        {
          'prevout': {
            'value': 0.002,
            'scriptPubKey': {'address': _receive0},
          },
        },
      ],
      'vout': [
        {
          'value': 0.001,
          'scriptPubKey': {'address': _theirs},
        },
        {
          'value': 0.0009,
          'scriptPubKey': {'address': _change0},
        },
      ],
    };

    /// A sweep to somebody else: one destination, no change output, so the fee is
    /// the whole difference between the input and that single output.
    ///
    /// 200,000 sats in, 199,455 to them; the 545-sat fee the send group's sweep
    /// pays for a 1-in 1-out P2WPKH spend at the default rate.
    Map<String, dynamic> sweptToThem() => {
      'hash': _txidOut,
      'txid': _txidOut,
      'height': 800001,
      'blocktime': 1700000200,
      'vin': [
        {
          'prevout': {
            'value': 0.002,
            'scriptPubKey': {'address': _receive0},
          },
        },
      ],
      'vout': [
        {
          'value': 0.00199455,
          'scriptPubKey': {'address': _theirs},
        },
      ],
    };

    /// A swept churn: one destination, no change, and that destination is our
    /// own; so every input is ours, the single output is ours, and the only
    /// value that actually left the wallet is the fee.
    ///
    /// 200,000 sats in, 199,455 out; a 545-sat fee, which is what the send
    /// group's sweep pays for a 1-in 1-out P2WPKH spend at the default rate. The
    /// destination is `_receive1`, a *receive* address rather than a change one:
    /// a churn, not a wallet shuffling its own change.
    Map<String, dynamic> sweptChurn() => {
      'hash': _txidOut,
      'txid': _txidOut,
      'height': 800001,
      'blocktime': 1700000200,
      'vin': [
        {
          'prevout': {
            'value': 0.002,
            'scriptPubKey': {'address': _receive0},
          },
        },
      ],
      'vout': [
        {
          'value': 0.00199455,
          'scriptPubKey': {'address': _receive1},
        },
      ],
    };

    test('an incoming transaction is credited in satoshis, not BTC', () async {
      await restore();
      await seedTxCache([incoming()]);

      final tx = wallet.readTxHistory().single;
      expect(tx.direction, txDirectionIncoming);
      // 0.0005 BTC, kept as exact base units rather than a double.
      expect(tx.amountBaseUnits, BigInt.from(50000));
      expect(tx.feeBaseUnits, BigInt.zero);
      expect(tx.height, 800000);
      expect(tx.timestamp, 1700000100);
      expect(tx.recipients.single.address, _receive0);
      expect(tx.recipients.single.amountBaseUnits, BigInt.from(50000));
    });

    test('an outgoing transaction reports the amount that left, and the fee', () async {
      await restore();
      await seedTxCache([outgoing()]);

      final tx = wallet.readTxHistory().single;
      expect(tx.direction, txDirectionOutgoing);
      // 0.001 to them; the 0.0009 back to our own change is not "sent".
      expect(tx.amountBaseUnits, BigInt.from(100000));
      // 0.002 in, 0.0019 out.
      expect(tx.feeBaseUnits, BigInt.from(10000));

      final change = tx.recipients.firstWhere((r) => r.isChange);
      expect(change.address, _change0);
      expect(change.amountBaseUnits, BigInt.from(90000));
      expect(tx.recipients.where((r) => !r.isChange).single.address, _theirs);
    });

    test('a sweep records the fee even with no change output to derive it from', () async {
      await restore();
      await seedTxCache([sweptToThem()]);

      final tx = wallet.readTxHistory().single;
      expect(tx.direction, txDirectionOutgoing);
      // Everything went to them, so unlike a normal send there is no change
      // output whose absence could be mistaken for a much larger fee.
      expect(tx.amountBaseUnits, BigInt.from(199455));
      expect(tx.feeBaseUnits, BigInt.from(545));
      expect(tx.amountBaseUnits + tx.feeBaseUnits, BigInt.from(200000), reason: 'the input, whole');

      expect(tx.recipients.single.address, _theirs);
      expect(tx.recipients.where((r) => r.isChange), isEmpty, reason: 'a sweep leaves no change');
    });

    test('a churn records the fee, and nothing as sent', () async {
      await restore();
      await seedTxCache([sweptChurn()]);

      final tx = wallet.readTxHistory().single;

      // Every input was ours, so this is a spend, not a 199,455-sat receipt,
      // which is what an address-only reading of the outputs would make it.
      expect(tx.direction, txDirectionOutgoing);

      // The fee is the whole cost of the transaction, so getting it from the
      // input/output difference is the only thing that records it at all: the
      // amount that "left the wallet" is zero.
      expect(tx.feeBaseUnits, BigInt.from(545));
      expect(tx.amountBaseUnits, BigInt.zero);

      // What the balance actually moves by. Both halves have to be right for
      // this to hold; a fee read as zero, or an amount that counted our own
      // output as sent, would each break it.
      expect(tx.amountBaseUnits + tx.feeBaseUnits, BigInt.from(545));

      // Ours, and not change: the output goes to a receive address, so nothing
      // here may be filed as change to be netted off a display.
      expect(tx.recipients.single.address, _receive1);
      expect(tx.recipients.single.isChange, isFalse);
    });

    test('a churn is one history entry, not one per address it touched', () async {
      // Electrum history is per scripthash, and a churn touches two of ours,
      // the one it spends from and the one it pays, so the server returns it
      // twice, once under each. Counting it twice doubles the fee in any total
      // built from this list.
      await restore();
      await seedTxCache([sweptChurn(), sweptChurn()]);

      final history = wallet.readTxHistory();
      expect(history, hasLength(1));
      expect(history.single.feeBaseUnits, BigInt.from(545));
    });

    test('confirmations come off the chain tip, and history is newest first', () async {
      await restore();
      scriptUsed(const {});
      await connectAndRefresh(); // sets the tip to 800000
      await seedTxCache([incoming(), outgoing()]);

      final history = wallet.readTxHistory();
      expect(history.map((t) => t.hash), [_txidOut, _txidIn]);
      // Tip 800000, tx at 800000 -> 1 confirmation.
      expect(history.last.confirmations, 1);
      expect(wallet.isTxConfirmed(history.last), isTrue);
      // The outgoing one claims a height above the tip, so nothing is claimed.
      expect(history.first.confirmations, 0);
    });

    test('a corrupt tx cache degrades to no history rather than throwing', () async {
      await restore();
      wallet.setCachePassword(_password);
      await WalletCacheStore.save('BTC', {'cachedTxBlobs': 'not json at all'}, _password);
      setConnection();
      await wallet.loadCache();
      await wallet.loadPersistedSnapshot();
      expect(wallet.readTxHistory(), isEmpty);
    });
  });

  group('send', () {
    /// One 200,000-sat confirmed output on the first receive address.
    Future<void> fundedWallet() async {
      await restore();
      scriptUsed({_sh(_receive0): (valueSats: 200000, height: 799990, txHash: _txidIn, vout: 0)});
      await connectAndRefresh();
    }

    test('builds a signed transaction with change, at the default fee rate', () async {
      await fundedWallet();

      // No histogram and no estimatefee from this server, so the rate is the
      // 5 sat/vB default: a 1-in 2-out P2WPKH spend is 140 vbytes.
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);

      expect(tx, isA<BitcoinPendingTx>());
      expect(tx.amountBaseUnits, BigInt.from(50000));
      expect(tx.feeBaseUnits, BigInt.from(700));

      final btc = tx as BitcoinPendingTx;
      expect(btc.rawHex, isNotEmpty);
      expect(btc.spentOutpoints.single.txHash, _txidIn);
      expect(btc.spentOutpoints.single.vout, 0);
    });

    test('a sweep spends everything and pays the 1-output fee', () async {
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.zero, true);
      // 109 vbytes at 5 sat/vB.
      expect(tx.feeBaseUnits, BigInt.from(545));
      expect(tx.amountBaseUnits, BigInt.from(200000 - 545));
    });

    test('a sweep churned back to ourselves still pays the fee', () async {
      // Churning is not free, and the fee cannot come out of thin air: a sweep
      // has no change output, so whatever is not the fee is the amount. An
      // implementation that recognised the destination as its own and skipped the
      // deduction would build a transaction whose outputs equal its inputs;
      // rejected by every node, after the user was told it was sent.
      await fundedWallet();
      final tx = await wallet.createTx(_receive1, BigInt.zero, true);

      expect(tx.feeBaseUnits, BigInt.from(545), reason: 'same 1-output fee as a sweep to anyone');
      expect(tx.amountBaseUnits, BigInt.from(200000 - 545));

      // The whole balance is spent, and the arithmetic closes.
      final btc = tx as BitcoinPendingTx;
      expect(btc.spentOutpoints.single.txHash, _txidIn);
      expect(tx.amountBaseUnits + tx.feeBaseUnits, BigInt.from(200000));
    });

    test('an amount above the supply cap is refused, not silently wrapped', () async {
      await fundedWallet();
      // BigInt.toInt() truncates to 64 bits on the VM, so an unchecked
      // conversion here would sign a transaction for a different number.
      expect(
        wallet.createTx(_theirs, BigInt.parse('9' * 30), false),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a negative amount is refused', () async {
      await fundedWallet();
      expect(wallet.createTx(_theirs, BigInt.from(-1), false), throwsA(isA<ArgumentError>()));
    });

    test('more than the wallet holds is refused', () async {
      await fundedWallet();
      expect(wallet.createTx(_theirs, BigInt.from(500000), false), throwsA(isA<Exception>()));
    });

    test('an empty wallet cannot send', () async {
      await restore();
      scriptUsed(const {});
      await connectAndRefresh();
      expect(wallet.createTx(_theirs, BigInt.from(1000), false), throwsA(isA<Exception>()));
    });

    test('an invalid destination is refused without naming it', () async {
      await fundedWallet();
      // The message reaches a log and a snackbar, and a destination address is
      // pseudonymous-only.
      await expectLater(
        wallet.createTx('not-a-bitcoin-address', BigInt.from(1000), false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains('not-a-bitcoin-address')),
          ),
        ),
      );
    });

    test('address validation accepts every payable form and rejects junk', () {
      expect(wallet.isAddressValid(_receive0), isTrue, reason: 'p2wpkh');
      expect(wallet.isAddressValid('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'), isTrue, reason: 'p2pkh');
      expect(wallet.isAddressValid('3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy'), isTrue, reason: 'p2sh');
      expect(wallet.isAddressValid(''), isFalse);
      expect(wallet.isAddressValid('not-an-address'), isFalse);
      // A testnet address is not payable from a mainnet wallet.
      expect(wallet.isAddressValid('tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx'), isFalse);
    });

    test('a broadcast retires the spent output from the spendable set', () async {
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      await wallet.commitTx(tx, _theirs);

      expect(fake.broadcasts.single, (tx as BitcoinPendingTx).rawHex);

      // The point of the optimistic removal: the same outpoint cannot be
      // selected again before the server has indexed the spend.
      await expectLater(
        wallet.createTx(_theirs, BigInt.from(50000), false),
        throwsA(isA<Exception>()),
      );

      // The displayed balance deliberately does NOT move. It is the server's
      // confirmed/unconfirmed figure, summed at fetch time, and it stays put
      // until a scripthash status push marks the state stale and refresh
      // refetches it, which a real server does within seconds of a broadcast.
      await wallet.loadTotalBalance();
      expect(wallet.totalBalanceBaseUnits, BigInt.from(200000));
    });

    group('the fee rate is not capped', () {
      // No fee cap. A `clamp(1, 1000)` here would silently rewrite a legitimate
      // 1500 sat/vB send down to 1000 and build a transaction paying less than
      // the user was quoted. Pinned so nobody reintroduces a ceiling without a
      // failing test to argue with.

      test('a rate far above the old 1000 sat/vB ceiling is used as given', () async {
        await fundedWallet();
        // Priority 0 → 6 blocks → 6,000,000 vbytes of capacity, so one bucket
        // that fills it sets the rate.
        fake.feeHistogramValue = [
          [1500, 6000000],
        ];

        final tx = await wallet.createTx(_theirs, BigInt.zero, true);
        // 109 vbytes for a 1-in 1-out sweep, at the full 1500, not 1000.
        expect(tx.feeBaseUnits, BigInt.from(109 * 1500));
      });

      test('a negative estimatefee falls through to the default, not to a negative fee', () async {
        await fundedWallet();
        // Some Electrum servers signal "no estimate" with -1. A floor here is
        // protocol, not policy: at or below zero nothing relays the result.
        fake.estimateFeeValue = -1;

        final tx = await wallet.createTx(_theirs, BigInt.zero, true);
        expect(tx.feeBaseUnits, BigInt.from(545), reason: '109 vbytes at the 5 sat/vB default');
      });

      test('a zero estimatefee also falls through to the default', () async {
        await fundedWallet();
        fake.estimateFeeValue = 0;

        final tx = await wallet.createTx(_theirs, BigInt.zero, true);
        expect(tx.feeBaseUnits, BigInt.from(545));
      });
    });

    test('a rejected broadcast surfaces rather than looking sent', () async {
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      fake.broadcastError = StateError('txn-mempool-conflict');

      await expectLater(wallet.commitTx(tx, _theirs), throwsA(isA<StateError>()));
      await wallet.loadTotalBalance();
      expect(wallet.totalBalanceBaseUnits, BigInt.from(200000));
    });

    test('a rejection leaves no record and no spent outputs', () async {
      // Rejected means nothing moved: the inputs are still ours, and the history
      // must not gain an entry. This is the case that was previously recorded as
      // a completed send, because any string reply was taken as a txid.
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      final txid = computeTxid((tx as BitcoinPendingTx).rawHex);
      fake.broadcastError = const BroadcastFailure(
        BroadcastOutcome.rejected,
        detail: 'the server refused the transaction',
      );

      await expectLater(
        wallet.commitTx(tx, _theirs),
        throwsA(
          isA<BroadcastFailure>().having((e) => e.outcome, 'outcome', BroadcastOutcome.rejected),
        ),
      );
      expect(wallet.readTxHistory().map((t) => t.hash), isNot(contains(txid)));

      // The outpoint is still spendable, so a retry can build the same send.
      await expectLater(wallet.createTx(_theirs, BigInt.from(50000), false), completes);
    });

    test('an unresolved broadcast is recorded, flagged, and reported', () async {
      // The case that had no representation at all: the bytes went out and no
      // answer came back. Guessing either way is wrong; "rejected" invites a
      // double-send, "sent" invites a false receipt; so all three of these must
      // hold at once.
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      final txid = computeTxid((tx as BitcoinPendingTx).rawHex);
      fake.broadcastError = const BroadcastFailure(
        BroadcastOutcome.unknown,
        detail: 'the connection ended before the server answered',
      );

      await expectLater(
        wallet.commitTx(tx, _theirs),
        throwsA(
          isA<BroadcastFailure>().having((e) => e.outcome, 'outcome', BroadcastOutcome.unknown),
        ),
      );

      // Recorded; it may well confirm, and an invisible transaction is the
      // worse half of this bug.
      final entry = wallet.readTxHistory().firstWhere((t) => t.hash == txid);
      expect(entry.status, TxStatus.unknown);

      // And its inputs are not offered again.
      await expectLater(
        wallet.createTx(_theirs, BigInt.from(50000), false),
        throwsA(isA<Exception>()),
      );
    });

    test('a txid-shaped answer that is not ours is not trusted', () async {
      // A server can return 64 valid hex characters and still not be talking
      // about our transaction. Shape alone was never enough.
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      final ours = computeTxid((tx as BitcoinPendingTx).rawHex);
      fake.broadcastTxid = 'd' * 64;

      await expectLater(
        wallet.commitTx(tx, _theirs),
        throwsA(
          isA<BroadcastFailure>().having((e) => e.outcome, 'outcome', BroadcastOutcome.unknown),
        ),
      );

      // Keyed on our id, not the one we were handed. The server does not get to
      // rename a transaction we signed.
      final hashes = wallet.readTxHistory().map((t) => t.hash);
      expect(hashes, contains(ours));
      expect(hashes, isNot(contains('d' * 64)));
    });

    test('a server that already has the transaction is a success', () async {
      // Re-broadcasting, or a first attempt whose reply was lost. Reporting
      // failure here would push the user into paying twice.
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      final txid = computeTxid((tx as BitcoinPendingTx).rawHex);
      fake.broadcastError = const BroadcastFailure(
        BroadcastOutcome.alreadyKnown,
        detail: 'the server already has this transaction',
      );

      await expectLater(wallet.commitTx(tx, _theirs), completes);
      final entry = wallet.readTxHistory().firstWhere((t) => t.hash == txid);
      expect(entry.status, TxStatus.ok);
    });

    test('an unresolved broadcast is written to the cache as unresolved', () async {
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      final txid = computeTxid((tx as BitcoinPendingTx).rawHex);
      fake.broadcastError = const BroadcastFailure(BroadcastOutcome.unknown);
      await expectLater(wallet.commitTx(tx, _theirs), throwsA(isA<BroadcastFailure>()));

      // "We do not know" has to be durable; resolving it to "sent" on the next
      // launch would be the original bug with extra steps. Asserted on the
      // persisted bytes rather than by reloading: `loadPersistedSnapshot` merges
      // into the live cache, so a round trip in one wallet would still pass if
      // the field were dropped on the way out. `TxDetails`'s own round trip is
      // covered in `wallet_domain/test/tx_details_test.dart`.
      wallet.setCachePassword(_password);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      final entries = await _persistedTxBlobs();
      final persisted = entries.firstWhere((e) => e['txid'] == txid);
      expect(persisted['status'], 'unknown');
    });

    test('a normal send writes no status key at all', () async {
      // The common case must not grow a field. An older build reading this cache
      // sees exactly the bytes it saw before.
      await fundedWallet();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      await wallet.commitTx(tx, _theirs);
      wallet.setCachePassword(_password);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      for (final e in await _persistedTxBlobs()) {
        expect(e.containsKey('status'), isFalse);
      }
    });

    test('committing something built by another coin is refused', () async {
      await fundedWallet();
      expect(wallet.commitTx(_NotABitcoinTx(), _theirs), throwsA(isA<ArgumentError>()));
    });
  });

  group('logging is redacted', () {
    test('a full send names no txid, scripthash or address in plaintext', () async {
      await restore();
      scriptUsed({_sh(_receive0): (valueSats: 200000, height: 799990, txHash: _txidIn, vout: 0)});
      await connectAndRefresh();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      await wallet.commitTx(tx, _theirs);

      final written = await logged();
      expect(written, isNotEmpty, reason: 'the assertions below would be vacuous');
      for (final secret in [
        _txidIn,
        _txidOut,
        computeTxid((tx as BitcoinPendingTx).rawHex),
        _sh(_receive0),
        _receive0,
        _theirs,
      ]) {
        expect(written, isNot(contains(secret)));
      }
      // The server endpoint is configuration, not a secret, and is the whole
      // point of a connection bug.
      expect(written, contains('electrum.example.com:50002'));
    });

    test('a broadcast is still traceable through a fingerprint', () async {
      await restore();
      scriptUsed({_sh(_receive0): (valueSats: 200000, height: 799990, txHash: _txidIn, vout: 0)});
      await connectAndRefresh();
      final tx = await wallet.createTx(_theirs, BigInt.from(50000), false);
      final txid = computeTxid((tx as BitcoinPendingTx).rawHex);
      await wallet.commitTx(tx, _theirs);

      final broadcastLine = (await logged())
          .split('\n')
          .firstWhere((l) => l.contains('broadcast ok'));
      expect(broadcastLine, contains(Redact.id(txid)));
    });
  });
}

class _NotABitcoinTx implements PendingTransaction {
  @override
  BigInt get amountBaseUnits => BigInt.one;

  @override
  BigInt get feeBaseUnits => BigInt.one;
}
