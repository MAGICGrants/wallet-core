import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_ethereum/wallet_ethereum.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// `EthereumChainWallet` and `Erc20ChainWallet` orchestration against
/// [FakeEthereumRpc] and [FakeEthereumExplorer].
///
/// Ethereum is where exact amounts matter most: wei is 18 decimals, so anything
/// above about 0.009 ETH is already outside a double's integer range. Several
/// groups below exist specifically to pin that the exact value survives.
const _mnemonic = 'test test test test test test test test test test test junk';
const _password = 'wallet-password';

/// Foundry's default accounts 0 and 1, both EIP-55 checksummed.
const _me = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const _theirs = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';

const _daiContract = '0x6B175474E89094C44Da98b954EedeAC495271d0F';

/// 2 ETH.
final _twoEth = BigInt.parse('2000000000000000000');

/// 21000 gas × (2 × 20 gwei + 2 gwei tip); the fee every default-priority send
/// in this file pays.
final _defaultFee = BigInt.parse('882000000000000');

String _hex(BigInt v) => '0x${v.toRadixString(16)}';

void main() {
  late Directory tmp;
  late FakeEthereumRpc rpc;
  late FakeEthereumExplorer explorer;
  late EthereumWallet wallet;
  late MemoryLogSink logs;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ethereum_wallet');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    logs = MemoryLogSink();
    WalletLog.sink = logs;
    WalletLog.isVerbose = () async => true;
    rpc = FakeEthereumRpc();
    explorer = FakeEthereumExplorer();
    wallet = EthereumWallet(rpc: rpc, explorer: explorer);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
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

  Future<void> restore([CryptoWallet? w]) => (w ?? wallet).restoreFromSeed(
    seed: const Bip39Seed(_mnemonic),
    from: RestorePoint.date(DateTime.utc(2026, 3, 14)),
    password: _password,
  );

  void setConnection([CryptoWallet? w]) =>
      (w ?? wallet).setConnection(address: 'https://rpc.example.com', proxyPort: '', useTor: false);

  Future<void> connectAndRefresh([CryptoWallet? w]) async {
    final target = w ?? wallet;
    setConnection(target);
    await target.connectToDaemon();
    await target.refresh();
  }

  group('metadata', () {
    test('the base unit is wei even though the display precision is not', () {
      expect(wallet.baseUnitDecimals, 18);
      expect(wallet.decimals, 10, reason: '18 decimals of a balance is unreadable');
    });

    test('a native coin pays its fee in itself', () {
      expect(wallet.feeCoinSymbol, 'ETH');
      expect(wallet.feeBaseUnitDecimals, 18);
      expect(wallet.feeIsForeign, isFalse);
    });

    test('only BIP39 — no EVM coin derives from a polyseed', () {
      expect(wallet.supportedSeedFormats, {SeedFormat.bip39});
    });

    test('an explorer is required, because the RPC cannot serve history', () {
      expect(wallet.supportsExplorerUrl, isTrue);
      expect(wallet.explorerAddressExample, isNotEmpty);
    });

    test('mainnet and Sepolia derive the same address, differing only by chain id', () async {
      final sepolia = EthereumSepoliaWallet(rpc: FakeEthereumRpc(chainIdValue: 11155111));
      addTearDown(sepolia.dispose);

      await restore();
      await restore(sepolia);

      expect(wallet.getPrimaryAddress(), _me);
      expect(sepolia.getPrimaryAddress(), _me);
      expect(wallet.chainId, 1);
      expect(sepolia.chainId, 11155111);
    });

    test('testnet coins resolve no aliases and borrow mainnet fiat', () {
      final sepolia = EthereumSepoliaWallet(rpc: FakeEthereumRpc(chainIdValue: 11155111));
      addTearDown(sepolia.dispose);
      // An alias publishes a mainnet address; offering to pay it from a testnet
      // wallet is the same mistake as for testnet Bitcoin.
      expect(sepolia.aliasNetwork, isEmpty);
      expect(sepolia.fiatBaseSymbol, 'ETH');
      expect(wallet.aliasNetwork, 'eth');
    });
  });

  group('lifecycle', () {
    test('no wallet before a restore, one after', () async {
      expect(await wallet.hasExistingWallet(), isFalse);
      await restore();
      expect(await wallet.hasExistingWallet(), isTrue);
      expect(wallet.getPrimaryAddress(), _me);
      expect(wallet.getReceiveAddress(), _me);
    });

    test('a restored wallet reopens to the same address', () async {
      await restore();
      final reopened = EthereumWallet(rpc: FakeEthereumRpc());
      addTearDown(reopened.dispose);
      await reopened.openExisting(password: _password);
      expect(reopened.getPrimaryAddress(), _me);
    });

    test('the wrong password fails to open', () async {
      await restore();
      final reopened = EthereumWallet(rpc: FakeEthereumRpc());
      addTearDown(reopened.dispose);
      expect(reopened.openExisting(password: 'wrong'), throwsA(isA<FormatException>()));
    });

    test('a polyseed is refused', () {
      expect(
        wallet.restoreFromSeed(
          seed: const PolyseedSeed('sixteen words which this coin cannot use at all ok'),
          from: const RestorePoint.newWallet(),
          password: _password,
        ),
        throwsA(isA<UnsupportedSeedFormatException>()),
      );
    });

    test('a seed passphrase is refused rather than silently ignored', () {
      expect(
        wallet.restoreFromSeed(
          seed: const Bip39Seed(_mnemonic, passphrase: 'extra'),
          from: const RestorePoint.newWallet(),
          password: _password,
        ),
        throwsA(isA<UnsupportedSeedFormatException>()),
      );
    });

    test('a height restore point is recorded where getRestoreHeight reads it', () async {
      await wallet.restoreFromSeed(
        seed: const Bip39Seed(_mnemonic),
        from: const RestorePoint.height(21000000),
        password: _password,
      );
      expect(await wallet.getRestoreHeight(), 21000000);
    });

    test('delete clears the file and the cached key material', () async {
      await restore();
      await wallet.deleteFiles();
      expect(await wallet.hasExistingWallet(), isFalse);
      expect(wallet.getPrimaryAddress(), isEmpty);
    });
  });

  group('connect', () {
    test('a chain-id mismatch is refused', () async {
      await restore();
      rpc.chainIdValue = 137; // Polygon
      setConnection();
      await expectLater(wallet.connectToDaemon(), throwsA(isA<Exception>()));
      expect(await wallet.getIsConnected(), isFalse);
    });

    test('the probe does not repoint the live connection', () async {
      await restore();
      await connectAndRefresh();
      final configuredUrl = rpc.url;

      // A separate client, so typing in the setup form cannot move the open
      // wallet onto a half-entered endpoint.
      await expectLater(
        wallet.testConnection(address: 'https://elsewhere.example.com', useTor: false),
        throwsA(anything),
      );
      expect(rpc.url, configuredUrl);
    });

    test('the explorer probe is separate from the node probe', () async {
      await wallet.testExplorerConnection(address: 'eth.blockscout.example', useTor: false);
      expect(explorer.probes.single, 'eth.blockscout.example');
    });

    test('sync state follows the block number', () async {
      await restore();
      await connectAndRefresh();
      await wallet.loadIsSynced();
      await wallet.loadSyncedHeight();
      expect(wallet.isSynced, isTrue);
      expect(wallet.syncedHeight, 21000000);
    });
  });

  group('balances survive the double barrier', () {
    test('a whole-wei balance is exact, and its double is not', () async {
      // 19 significant digits: past 2^53, so the double getter cannot represent
      // it and the base-unit getter must.
      final exact = BigInt.parse('1234567890123456789');
      rpc.balanceValue = exact;
      await restore();
      await connectAndRefresh();
      await wallet.loadTotalBalance();
      await wallet.loadUnlockedBalance();

      expect(wallet.totalBalanceBaseUnits, exact);
      expect(wallet.unlockedBalanceBaseUnits, exact);
      expect(wallet.totalBalanceString, '1.234567890123456789');

      // The display double, for contrast: reconstructing base units from it
      // does not give the value back. This is what Spice stored.
      final viaDouble = BigInt.from(wallet.totalBalance! * 1e18);
      expect(viaDouble, isNot(exact));
    });

    test('one wei is not lost', () async {
      rpc.balanceValue = BigInt.one;
      await restore();
      await connectAndRefresh();
      await wallet.loadTotalBalance();
      expect(wallet.totalBalanceBaseUnits, BigInt.one);
      expect(wallet.totalBalanceString, '0.000000000000000001');
    });

    test('a failed refresh marks the wallet disconnected and keeps the balance', () async {
      rpc.balanceValue = _twoEth;
      await restore();
      await connectAndRefresh();
      await wallet.loadTotalBalance();

      rpc.failing['getBalance'] = StateError('node down');
      await wallet.refresh();
      expect(await wallet.getIsConnected(), isFalse);
      expect(wallet.totalBalanceBaseUnits, _twoEth);
    });
  });

  group('transaction history', () {
    test('the explorer classifies incoming and outgoing by sender', () async {
      explorer.transfers = [
        ExplorerTx(
          hash: '0xaa',
          from: _theirs,
          to: _me,
          valueWei: BigInt.parse('1500000000000000000'),
          feeWei: BigInt.parse('21000000000000'),
          blockNumber: 20999999,
          status: 1,
          timestamp: 1700000100,
        ),
        ExplorerTx(
          hash: '0xbb',
          from: _me,
          to: _theirs,
          valueWei: BigInt.parse('500000000000000000'),
          feeWei: BigInt.parse('31500000000000'),
          blockNumber: 21000000,
          status: 1,
          timestamp: 1700000200,
        ),
      ];

      await restore();
      await connectAndRefresh();
      wallet.setExplorerConnection(address: 'eth.blockscout.example', proxyPort: '', useTor: false);
      await wallet.loadTxHistory(persistCount: false);

      final history = wallet.txHistory;
      expect(history.map((t) => t.hash), ['0xbb', '0xaa'], reason: 'newest first');

      final incoming = history.last;
      expect(incoming.direction, txDirectionIncoming);
      expect(incoming.amountBaseUnits, BigInt.parse('1500000000000000000'));
      // Somebody else paid for it, so we do not report a fee.
      expect(incoming.feeBaseUnits, BigInt.zero);
      expect(incoming.recipients.single.address, _me);

      final outgoing = history.first;
      expect(outgoing.direction, txDirectionOutgoing);
      expect(outgoing.amountBaseUnits, BigInt.parse('500000000000000000'));
      expect(outgoing.feeBaseUnits, BigInt.parse('31500000000000'));
      expect(outgoing.recipients.single.address, _theirs);
      expect(outgoing.confirmations, 1);
    });

    test('a churn from the explorer is a spend with a fee, not a free receipt', () async {
      // A restored wallet has no local record of a churn it made before the
      // restore, so this comes back from the explorer with `from` and `to` both
      // us. Classifying by the recipient would make it incoming, and
      // incoming means "somebody else paid the fee", so the record would show a
      // 1.999 ETH windfall that cost nothing. Both halves are asserted, because
      // the direction is what decides whether the fee is kept.
      explorer.transfers = [
        ExplorerTx(
          hash: '0xcc',
          from: _me,
          to: _me,
          valueWei: _twoEth - _defaultFee,
          feeWei: _defaultFee,
          blockNumber: 21000001,
          status: 1,
          timestamp: 1700000300,
        ),
      ];

      await restore();
      await connectAndRefresh();
      wallet.setExplorerConnection(address: 'eth.blockscout.example', proxyPort: '', useTor: false);
      await wallet.loadTxHistory(persistCount: false);

      final tx = wallet.txHistory.single;
      expect(tx.direction, txDirectionOutgoing);
      expect(tx.feeBaseUnits, _defaultFee);
      expect(tx.amountBaseUnits, _twoEth - _defaultFee);
    });

    test('a local record of a churn survives the explorer reporting it too', () async {
      // The explorer sees the same transaction the wallet just broadcast. Its
      // view is not wrong here, but it could arrive with a zero
      // fee, and `putIfAbsent` is what keeps the broadcast record authoritative.
      rpc.balanceValue = _twoEth;
      await restore();
      await connectAndRefresh();
      final tx = await wallet.createTx(_me, BigInt.zero, true);
      rpc.broadcastHash = (tx as EthereumPendingTx).txHash;
      await wallet.commitTx(tx, _me);

      explorer.transfers = [
        ExplorerTx(
          hash: tx.txHash,
          from: _me,
          to: _me,
          valueWei: _twoEth - _defaultFee,
          feeWei: BigInt.zero,
          blockNumber: 21000002,
          status: 1,
          timestamp: 1700000400,
        ),
      ];
      wallet.setExplorerConnection(address: 'eth.blockscout.example', proxyPort: '', useTor: false);
      await wallet.loadTxHistory(persistCount: false);

      expect(wallet.txHistory, hasLength(1), reason: 'one transaction, seen twice');
      expect(wallet.txHistory.single.feeBaseUnits, _defaultFee);
    });

    test('no explorer configured means no explorer request', () async {
      await restore();
      await connectAndRefresh();
      await wallet.loadTxHistory(persistCount: false);
      expect(explorer.calls, isEmpty);
    });

    test('an explorer failure leaves the local records intact', () async {
      explorer.error = StateError('explorer 502');
      await restore();
      await connectAndRefresh();
      wallet.setExplorerConnection(address: 'eth.blockscout.example', proxyPort: '', useTor: false);
      await wallet.loadTxHistory(persistCount: false);
      expect(wallet.txHistory, isEmpty);
    });

    test('explorerUseTor with no Tor proxy skips the request rather than going clear', () async {
      // Tor off globally, so getProxy() answers null immediately instead of
      // waiting on a circuit that will never come up.
      await TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);

      await restore();
      await connectAndRefresh();
      wallet.setExplorerConnection(address: 'eth.blockscout.example', proxyPort: '', useTor: true);
      await wallet.loadTxHistory(persistCount: false);

      // The explorer URL carries our own address in its path, so an unproxied
      // request would hand a third party the address and the IP behind it.
      expect(explorer.calls, isEmpty);
      expect(await logged(), contains('no Tor proxy'));
    });

    test('a custom explorer proxy port is used when Tor is not requested', () async {
      explorer.transfers = const [];
      await restore();
      await connectAndRefresh();
      wallet.setExplorerConnection(
        address: 'eth.blockscout.example',
        proxyPort: '9150',
        useTor: false,
      );
      await wallet.loadTxHistory(persistCount: false);
      expect(explorer.calls.single.socksPort, 9150);
    });

    test('a receipt resolves a pending transaction to its block and actual fee', () async {
      rpc.balanceValue = _twoEth;
      await restore();
      await connectAndRefresh();

      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      rpc.broadcastHash = (tx as EthereumPendingTx).txHash;
      await wallet.commitTx(tx, _theirs);

      // Pending: no block, and the fee is still the max it was signed for.
      expect(wallet.txHistory.single.height, -1);
      expect(wallet.txHistory.single.feeBaseUnits, _defaultFee);

      rpc.receipts[tx.txHash] = EthReceipt(
        blockNumber: 21000000,
        gasUsed: BigInt.from(21000),
        effectiveGasPrice: BigInt.from(30000000000),
        status: 1,
      );
      await wallet.refresh();
      await wallet.loadTxHistory(persistCount: false);

      final settled = wallet.txHistory.single;
      expect(settled.height, 21000000);
      // gasUsed × effectiveGasPrice, which is less than the max fee.
      expect(settled.feeBaseUnits, BigInt.parse('630000000000000'));
      expect(settled.feeBaseUnits, lessThan(_defaultFee));
    });
  });

  group('send', () {
    Future<void> funded() async {
      rpc.balanceValue = _twoEth;
      await restore();
      await connectAndRefresh();
    }

    test('the send value is exactly what was asked for', () async {
      await funded();
      final oneEth = BigInt.parse('1000000000000000000');
      final tx = await wallet.createTx(_theirs, oneEth, false);

      expect(tx.amountBaseUnits, oneEth);
      expect(tx.feeBaseUnits, _defaultFee);
      expect((tx as EthereumPendingTx).to, _theirs);
      expect(tx.rawHex, startsWith('0x'));
      expect(tx.txHash, startsWith('0x'));
    });

    test('a type-2 transaction carries its EIP-2718 type byte', () async {
      await funded();
      final tx =
          await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false)
              as EthereumPendingTx;
      // Without the byte a node decodes the payload as a legacy transaction,
      // which is a different transaction with a different hash.
      expect(tx.rawHex, startsWith('0x02'));
    });

    test('priority only scales the tip', () async {
      await funded();
      final amount = BigInt.parse('1000000000000000000');
      final low = await wallet.createTx(_theirs, amount, false, priority: 1);
      // Same destination inside the TTL, so the shared inputs are cached and
      // only the tip is recomputed.
      final high = await wallet.createTx(_theirs, amount, false, priority: 3);

      // 21000 × (40 gwei + 1 gwei) and 21000 × (40 gwei + 3 gwei).
      expect(low.feeBaseUnits, BigInt.parse('861000000000000'));
      expect(high.feeBaseUnits, BigInt.parse('903000000000000'));
      expect(rpc.countOf('baseFeePerGas'), 1, reason: 'fee inputs are cached across priorities');
    });

    test('a sweep leaves exactly the max fee behind', () async {
      await funded();
      final tx = await wallet.createTx(_theirs, BigInt.zero, true);
      expect(tx.amountBaseUnits, _twoEth - _defaultFee);
      expect(tx.feeBaseUnits, _defaultFee);
    });

    test('a broadcast sweep is recorded with the fee it reserved', () async {
      // The amount and the fee are one decision for a sweep; the amount *is*
      // the balance minus the fee; so a record that keeps one and not the other
      // cannot be reconciled against the balance afterwards.
      await funded();
      final tx = await wallet.createTx(_theirs, BigInt.zero, true);
      rpc.broadcastHash = (tx as EthereumPendingTx).txHash;
      await wallet.commitTx(tx, _theirs);

      final recorded = wallet.txHistory.single;
      expect(recorded.direction, txDirectionOutgoing);
      expect(recorded.amountBaseUnits, _twoEth - _defaultFee);
      expect(recorded.feeBaseUnits, _defaultFee);
      expect(recorded.recipients.single.address, _theirs);
      expect(
        recorded.amountBaseUnits + recorded.feeBaseUnits,
        _twoEth,
        reason: 'the balance it swept',
      );
    });

    test('a churned sweep reserves the fee like any other', () async {
      // Churning is not free. The fee has to come out of the amount; there is
      // nothing else for it to come out of, and a wallet that recognised its
      // own address and swept the whole balance would sign a transaction whose
      // value plus gas exceeds what it holds.
      await funded();
      final tx = await wallet.createTx(_me, BigInt.zero, true);

      expect(tx.amountBaseUnits, _twoEth - _defaultFee);
      expect(tx.feeBaseUnits, _defaultFee);
      expect(tx.amountBaseUnits + tx.feeBaseUnits, _twoEth, reason: 'the whole balance, exactly');
    });

    test('a churned sweep is recorded as a spend that cost the fee', () async {
      await funded();
      final tx = await wallet.createTx(_me, BigInt.zero, true);
      rpc.broadcastHash = (tx as EthereumPendingTx).txHash;
      await wallet.commitTx(tx, _me);

      // One entry, not one for the send and another for the receipt.
      final recorded = wallet.txHistory.single;
      expect(recorded.hash, tx.txHash);
      expect(recorded.direction, txDirectionOutgoing);
      // The point of the test: the fee is what this transaction actually cost,
      // so losing it here loses the only real number in the record.
      expect(recorded.feeBaseUnits, _defaultFee);
      expect(recorded.amountBaseUnits, _twoEth - _defaultFee);
      expect(recorded.recipients.single.address, _me);
    });

    test('a sweep of a balance below the fee is refused', () async {
      rpc.balanceValue = BigInt.from(1000);
      await restore();
      await connectAndRefresh();
      expect(wallet.createTx(_theirs, BigInt.zero, true), throwsA(isA<Exception>()));
    });

    test('value plus fee above the balance is refused', () async {
      await funded();
      expect(wallet.createTx(_theirs, _twoEth, false), throwsA(isA<Exception>()));
    });

    test('a negative amount is refused', () async {
      await funded();
      expect(wallet.createTx(_theirs, BigInt.from(-1), false), throwsA(isA<ArgumentError>()));
    });

    test('an unconfigured RPC is refused before any signing', () async {
      await restore();
      expect(wallet.createTx(_theirs, BigInt.from(1000), false), throwsA(isA<Exception>()));
    });

    test('a reverting estimateGas falls back rather than failing the send', () async {
      await funded();
      rpc.failing['estimateGas'] = StateError('execution reverted');
      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      // fallbackGasLimit is 21000 for a native transfer, so the fee is unchanged.
      expect(tx.feeBaseUnits, _defaultFee);
    });

    test('address validation follows EIP-55', () {
      expect(wallet.isAddressValid(_me), isTrue);
      expect(wallet.isAddressValid(_me.toLowerCase()), isTrue, reason: 'no checksum to verify');
      expect(wallet.isAddressValid('0X${_me.substring(2).toUpperCase()}'), isFalse);
      // A single flipped case bit breaks the checksum.
      expect(wallet.isAddressValid('0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266'), isFalse);
      expect(wallet.isAddressValid('0x1234'), isFalse);
      expect(wallet.isAddressValid(''), isFalse);
    });

    test('an invalid destination is refused', () async {
      await funded();
      expect(
        wallet.createTx('not-an-address', BigInt.from(1000), false),
        throwsA(isA<Exception>()),
      );
    });

    test('a broadcast records the transaction and invalidates the cached nonce', () async {
      await funded();
      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      rpc.broadcastHash = (tx as EthereumPendingTx).txHash;
      await wallet.commitTx(tx, _theirs);

      expect(rpc.broadcasts.single, tx.rawHex);
      expect(wallet.txHistory.single.hash, tx.txHash);
      expect(wallet.txHistory.single.direction, txDirectionOutgoing);

      // The nonce advanced, so the next send must re-fetch rather than reuse it.
      final before = rpc.countOf('getTransactionCount');
      await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      expect(rpc.countOf('getTransactionCount'), before + 1);
    });

    test('a rejected broadcast surfaces rather than looking sent', () async {
      await funded();
      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      rpc.failing['sendRawTransaction'] = StateError('nonce too low');

      await expectLater(wallet.commitTx(tx, _theirs), throwsA(isA<StateError>()));
      expect(wallet.txHistory, isEmpty);
    });

    test('committing something built by another coin is refused', () async {
      await funded();
      expect(wallet.commitTx(_NotAnEthTx(), _theirs), throwsA(isA<ArgumentError>()));
    });

    test('a node that reports a different hash is not believed', () async {
      // `txHash` is keccak256 over the exact bytes broadcast, so the node has no
      // say in what this transaction is called. A disagreement means it did not
      // relay what we handed it.
      await funded();
      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      rpc.broadcastHash = '0x${'cd' * 32}';

      await expectLater(
        wallet.commitTx(tx, _theirs),
        throwsA(
          isA<BroadcastFailure>().having((e) => e.outcome, 'outcome', BroadcastOutcome.unknown),
        ),
      );

      // Recorded under our hash, not theirs, and flagged, because the signed
      // bytes did go out and we cannot say what became of them.
      final entry = wallet.txHistory.single;
      expect(entry.hash, (tx as EthereumPendingTx).txHash);
      expect(entry.status, TxStatus.unknown);
    });
  });

  group('receipt status reaches the history', () {
    // The field with four writers and no readers. A reverted transaction (on
    // chain, gas spent, funds not moved) was recorded and displayed as
    // completed, because `TxDetails` had nowhere to put the answer.

    Future<TxDetails> sendAndSettle(int? receiptStatus) async {
      rpc.balanceValue = _twoEth;
      await restore();
      await connectAndRefresh();
      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      await wallet.commitTx(tx, _theirs);
      if (receiptStatus != null) {
        rpc.receipts[(tx as EthereumPendingTx).txHash] = EthReceipt(
          blockNumber: 21000000,
          gasUsed: BigInt.from(21000),
          effectiveGasPrice: BigInt.from(30000000000),
          status: receiptStatus,
        );
        await wallet.refresh();
        await wallet.loadTxHistory(persistCount: false);
      }
      return wallet.txHistory.single;
    }

    test('status 1 is a success', () async {
      expect((await sendAndSettle(1)).status, TxStatus.ok);
    });

    test('status 0 is a failure, not a completed send', () async {
      final entry = await sendAndSettle(0);
      expect(entry.status, TxStatus.failed);
      // Still on chain and still charged for: the block and the fee are real.
      expect(entry.height, 21000000);
      expect(entry.feeBaseUnits, BigInt.parse('630000000000000'));
    });

    test('pending is not a failure', () async {
      // No receipt yet is the ordinary state of a fresh send, and must not be
      // dressed up as a problem.
      expect((await sendAndSettle(null)).status, TxStatus.ok);
    });

    test('a failed status survives the snapshot round trip', () async {
      await sendAndSettle(0);
      await wallet.persistWalletSnapshot();
      await wallet.loadPersistedSnapshot();
      // Rebuilt from the reloaded records rather than read off the list already
      // in memory; otherwise this would pass on the pre-reload value and say
      // nothing about what was written.
      await wallet.loadTxHistory(persistCount: false);
      expect(wallet.txHistory.single.status, TxStatus.failed);
    });
  });

  group('ERC-20', () {
    late FakeEthereumRpc tokenRpc;
    late FakeEthereumExplorer tokenExplorer;
    late DaiWallet dai;

    /// 5 DAI, in the token's 18-decimal raw units.
    final fiveDai = BigInt.parse('5000000000000000000');

    setUp(() {
      tokenRpc = FakeEthereumRpc();
      tokenExplorer = FakeEthereumExplorer();
      dai = DaiWallet(rpc: tokenRpc, explorer: tokenExplorer);
    });

    tearDown(() => dai.dispose());

    Future<void> fundedDai({BigInt? nativeWei}) async {
      tokenRpc.balanceValue = nativeWei ?? _twoEth;
      tokenRpc.ethCallValue = _hex(fiveDai);
      await restore(dai);
      await connectAndRefresh(dai);
    }

    test('the display keeps enough decimals to see a real balance', () {
      // DAI was pinned to 2 display decimals, which rendered 12.345678 DAI as
      // 12.34 and made value look like it had vanished. Base units are exact
      // either way; this is only what the balance readout shows.
      expect(dai.decimals, greaterThanOrEqualTo(6));
      expect(dai.baseUnitDecimals, 18, reason: 'exactness is unaffected by display');
    });

    test('the amount is in token units and the fee is in wei', () {
      expect(dai.baseUnitDecimals, 18, reason: "DAI's own decimals");
      expect(dai.feeCoinSymbol, 'ETH');
      expect(dai.feeBaseUnitDecimals, 18, reason: 'gas is paid in wei, whatever the token');
      expect(dai.feeIsForeign, isTrue);
    });

    test('a token whose decimals are not 18 still reports its fee in wei', () {
      // DAI happens to be 18 decimals, so it cannot tell `feeBaseUnitDecimals`
      // apart from `baseUnitDecimals`. A 6-decimal token, USDC's shape, is the
      // case the getter exists for: rendering the fee with the amount's scale
      // would be wrong by twelve orders of magnitude.
      final usdc = Erc20ChainWallet(
        chainId: 1,
        coinSymbol: 'USDC',
        blockchainName: 'Ethereum',
        assetName: 'USD Coin',
        iconAsset: 'assets/icons/usdc.svg',
        isTestnet: false,
        tokenContractAddress: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        tokenDecimals: 6,
        parentCoinSymbol: 'ETH',
        rpc: FakeEthereumRpc(),
      );
      addTearDown(usdc.dispose);

      expect(usdc.baseUnitDecimals, 6);
      expect(usdc.feeBaseUnitDecimals, 18);
    });

    test('the balance comes from balanceOf, not eth_getBalance', () async {
      await fundedDai();
      await dai.loadTotalBalance();
      await dai.loadUnlockedBalance();
      expect(dai.totalBalanceBaseUnits, fiveDai);
      expect(dai.unlockedBalanceBaseUnits, fiveDai);
      expect(tokenRpc.countOf('ethCall'), 1);
    });

    test('the connection is shared with the parent chain coin', () async {
      // Set it once on ETH...
      setConnection();
      await wallet.persistCurrentConnection();

      // ...and the token finds it, because both namespace under `eth`.
      expect(dai.connectionPrefSymbol, 'ETH');
      await dai.loadPersistedConnection();
      expect(dai.connectionAddress, 'https://rpc.example.com');
    });

    test('a transfer is a contract call, not a value send', () async {
      await fundedDai();
      final tx = await dai.createTx(_theirs, BigInt.parse('1000000000000000000'), false);

      expect(tx.amountBaseUnits, BigInt.parse('1000000000000000000'));
      expect(tx.feeBaseUnits, _defaultFee, reason: 'wei, not DAI');
      // transfer(address,uint256) selector, and the destination in the calldata.
      expect((tx as EthereumPendingTx).rawHex, contains('a9059cbb'));
      expect(tx.rawHex, contains(_theirs.substring(2).toLowerCase()));
    });

    test('the fee is checked against the native balance, not the token balance', () async {
      // Plenty of DAI, no ETH for gas.
      await fundedDai(nativeWei: BigInt.zero);
      await expectLater(
        dai.createTx(_theirs, BigInt.parse('1000000000000000000'), false),
        throwsA(isA<Exception>()),
      );
      expect(await logged(), contains('insufficient gas'));
    });

    test('more than the token balance is refused', () async {
      await fundedDai();
      expect(
        dai.createTx(_theirs, BigInt.parse('6000000000000000000'), false),
        throwsA(isA<Exception>()),
      );
    });

    test('a sweep sends the whole token balance', () async {
      await fundedDai();
      final tx = await dai.createTx(_theirs, BigInt.zero, true);
      expect(tx.amountBaseUnits, fiveDai);
      // The fee is not deducted from the amount here, because it is not payable
      // in the amount's units at all: it is wei, out of the native balance.
      expect(tx.feeBaseUnits, _defaultFee, reason: 'wei, not DAI');
    });

    test('a churned token sweep moves every unit and pays gas in wei', () async {
      // The asymmetry with a native sweep, and the reason this is its own test:
      // gas is not paid in the token, so a token sweep must move the *whole*
      // token balance rather than balance-minus-fee. Deducting the wei fee from
      // a token amount is a category error that happens to typecheck; for an
      // 18-decimal token it would silently withhold a fifth of a cent, and for a
      // 6-decimal one it would try to send a negative amount.
      await fundedDai();
      final tx = await dai.createTx(_me, BigInt.zero, true);

      expect(tx.amountBaseUnits, fiveDai, reason: 'token units, undiminished');
      expect(tx.feeBaseUnits, _defaultFee, reason: 'wei, alongside — not subtracted');
    });

    test('a churned token sweep is refused when there is no gas to pay with', () async {
      // A sweep is the case where "just send a bit less" is not available: the
      // amount is already everything, so the fee has to come from the native
      // balance or the transaction cannot be made at all.
      await fundedDai(nativeWei: BigInt.zero);
      await expectLater(dai.createTx(_me, BigInt.zero, true), throwsA(isA<Exception>()));
      expect(await logged(), contains('insufficient gas'));
    });

    test('the explorer is asked for token transfers, filtered to this contract', () async {
      tokenExplorer.tokenTransfers = {
        _daiContract.toLowerCase(): [
          ExplorerTx(
            hash: '0xcc',
            from: _theirs,
            to: _me,
            valueWei: BigInt.parse('3000000000000000000'),
            feeWei: BigInt.zero,
            blockNumber: 20999999,
            status: 1,
            timestamp: 1700000300,
          ),
        ],
        // Another token the address has touched. Crediting this would report
        // somebody else's units as DAI.
        '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef': [
          ExplorerTx(
            hash: '0xdd',
            from: _theirs,
            to: _me,
            valueWei: BigInt.parse('999000000000000000'),
            feeWei: BigInt.zero,
            blockNumber: 20999998,
            status: 1,
            timestamp: 1700000250,
          ),
        ],
      };

      await fundedDai();
      dai.setExplorerConnection(address: 'eth.blockscout.example', proxyPort: '', useTor: false);
      await dai.loadTxHistory(persistCount: false);

      expect(dai.txHistory.map((t) => t.hash), ['0xcc']);
      expect(dai.txHistory.single.amountBaseUnits, BigInt.parse('3000000000000000000'));
    });

    test('delete clears the token balance too', () async {
      await fundedDai();
      await dai.loadTotalBalance();
      expect(dai.totalBalanceBaseUnits, fiveDai);

      await dai.delete();
      expect(dai.isLoaded, isFalse);
      expect(dai.totalBalanceBaseUnits, isNull);
      expect(await dai.getCurrentHeight(), 0);

      // And reconnecting alone cannot bring it back: the address went with the
      // file, so there is nothing to read a balance for until a restore.
      await connectAndRefresh(dai);
      await dai.loadTotalBalance();
      expect(dai.totalBalanceBaseUnits, isNull);
    });
  });

  group('the offline signing client refuses to egress', () {
    test('any request throws instead of bypassing Tor', () {
      final client = OfflineSigningClient();
      expect(client.get(Uri.parse('https://rpc.example.com')), throwsA(isA<StateError>()));
    });
  });

  group('logging is redacted', () {
    test('a full send names no amount, balance, address or hash in plaintext', () async {
      rpc.balanceValue = BigInt.parse('1234567890123456789');
      await restore();
      await connectAndRefresh();
      final tx = await wallet.createTx(_theirs, BigInt.parse('1000000000000000000'), false);
      rpc.broadcastHash = (tx as EthereumPendingTx).txHash;
      await wallet.commitTx(tx, _theirs);

      final written = await logged();
      expect(written, isNotEmpty, reason: 'the assertions below would be vacuous');
      for (final secret in [
        _theirs,
        _theirs.toLowerCase(),
        _me,
        tx.txHash,
        '1234567890123456789', // the balance
        '1000000000000000000', // the send amount
      ]) {
        expect(written, isNot(contains(secret)));
      }
    });

    test('an invalid destination is fingerprinted, not quoted', () async {
      rpc.balanceValue = _twoEth;
      await restore();
      await connectAndRefresh();
      // A well-formed hex address with a broken EIP-55 checksum: it reaches the
      // "invalid address" log line, unlike obvious junk.
      const badChecksum = '0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
      await expectLater(
        wallet.createTx(badChecksum, BigInt.from(1000), false),
        throwsA(isA<Exception>()),
      );

      final line = (await logged()).split('\n').firstWhere((l) => l.contains('invalid address'));
      expect(line, isNot(contains(badChecksum)));
      expect(line, contains(Redact.id(badChecksum)));
    });
  });
}

class _NotAnEthTx implements PendingTransaction {
  @override
  BigInt get amountBaseUnits => BigInt.one;

  @override
  BigInt get feeBaseUnits => BigInt.one;
}
