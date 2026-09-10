import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// Not re-exported from the package root, so it is imported by path.
import 'package:blockchain_utils/bip/address/eth_addr.dart' show EthAddrUtils;
import 'package:flutter/foundation.dart' show protected;
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';

import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'erc20_abi.dart';
import 'ethereum_explorer_client.dart';
import 'ethereum_keys.dart';
import 'ethereum_pending_tx.dart';
import 'ethereum_rpc_api.dart';
import 'ethereum_rpc_client.dart';
import 'offline_signing_client.dart';

part 'erc20_chain_wallet.dart';

/// Account-model EVM wallet backed by a user-supplied JSON-RPC endpoint.
///
/// Mainnet `EthereumWallet` and `EthereumSepoliaWallet` differ only by chain id
/// and metadata; the derived address is identical, because EVM networks differ
/// by chain id and not by derivation path.
///
/// Things to know when working on this class:
///
///  - the RPC and explorer clients are injected, so everything above them is
///    testable without a node;
///  - amounts are exact `BigInt` wei throughout;
///  - the wallet file is decrypted in an isolate, not on the UI thread;
///  - balances, send amounts and addresses must not be logged in the clear. See
///    `Redact`.
class EthereumChainWallet extends CryptoWallet {
  EthereumChainWallet({
    required int chainId,
    required String coinSymbol,
    required String blockchainName,
    required String iconAsset,
    required String connectionAddressExample,
    required bool isTestnet,
    EthereumRpcApi? rpc,
    EthereumExplorerApi? explorer,
  }) : _chainId = chainId,
       _coinSymbol = coinSymbol,
       _blockchainName = blockchainName,
       _iconAsset = iconAsset,
       _connectionAddressExample = connectionAddressExample,
       _isTestnet = isTestnet,
       _rpc = rpc ?? EthereumRpcClient(coinSymbol: coinSymbol),
       _explorer = explorer ?? EthereumExplorerClient();

  static final RegExp _hexAddress = RegExp(r'^0x[0-9a-fA-F]{40}$');
  static const int _feeInputsTtlMs = 8000;

  /// Decimals of the native unit on every EVM chain.
  static const int weiDecimals = 18;

  final int _chainId;
  final String _coinSymbol;
  final String _blockchainName;
  final String _iconAsset;
  final String _connectionAddressExample;
  final bool _isTestnet;
  final EthereumRpcApi _rpc;
  final EthereumExplorerApi _explorer;

  // In-memory wallet state.
  String? _mnemonic;
  String? _address;
  String? _privateKeyHex; // cached after first derive; cleared on delete
  DateTime? _restoreDate;
  String? _lastPassword;

  // Cached chain state.
  BigInt _balanceWei = BigInt.zero;
  int _bestHeight = 0;
  bool _connected = false;

  /// Shared fee inputs (same across priorities), cached per destination with a
  /// short TTL so the 3-priority preview hits the RPC once, not 3×. Invalidated
  /// after a broadcast (nonce changes).
  ({BigInt baseFee, BigInt tipBase, int nonce, BigInt gasLimit, String to, int atMs})? _feeInputs;

  /// Locally-tracked transactions keyed by hash. Outgoing txs are recorded at
  /// broadcast (no indexer needed); an optional explorer adds incoming ones
  /// later. Confirmations come from polling receipts in [refresh].
  final Map<String, _EthTxRecord> _txRecords = {};

  int get chainId => _chainId;

  // ----- Metadata -----

  @override
  String get coinSymbol => _coinSymbol;
  @override
  String get blockchainName => _blockchainName;
  @override
  String get iconAsset => _iconAsset;

  /// Display precision, not the base unit; see [baseUnitDecimals]. Showing 18
  /// decimals of a balance is unreadable.
  @override
  int get decimals => 10;
  @override
  int get smallerDigits => 6;
  @override
  int get baseUnitDecimals => weiDecimals;
  @override
  int get requiredConfirmations => _isTestnet ? 6 : 12;
  @override
  bool get isTestnet => _isTestnet;
  @override
  bool get canSpendPendingBalance => false;
  @override
  bool get canConnectBeforeOpen => true;

  /// Ethereum's RPC cannot serve an address's transaction history, so it needs a
  /// second endpoint with its own Tor and SSL settings.
  @override
  bool get supportsExplorerUrl => true;

  /// OpenAlias network and asset. They differ for a token: DAI is asset `dai` on
  /// network `eth`.
  @override
  String get aliasNetwork => 'eth';

  @override
  String get connectionTypeName => 'RPC endpoint';
  @override
  String get connectionAddressExample => _connectionAddressExample;
  @override
  String get explorerAddressExample => 'explorer.example.com';

  // ----- Persistence -----

  /// e.g. `${appDir}/mywallet_eth`. The namer is injected rather than hardcoded
  /// so an app never has to migrate on-disk state.
  Future<File> _walletFile() async {
    final dir = await getAppDir();
    return File('${dir.path}/${WalletAppConfig.instance.walletFileNamer(coinSymbol)}');
  }

  @override
  Future<bool> hasExistingWallet() async {
    final file = await _walletFile();
    if (!await file.exists()) return false;
    final blob = (await file.readAsString()).trim();
    return WalletFileCrypto.isValidEncryptedBlobBase64(blob);
  }

  @override
  Future<void> openExisting({required String password}) async {
    final file = await _walletFile();
    final blob = (await file.readAsString()).trim();

    // Off the UI thread: decrypting on the main isolate is 600k
    // PBKDF2 rounds on desktop; a visible stall on open. Bitcoin's port already
    // did this; the two must not drift again.
    // The KDF is captured outside because static state does not cross an isolate
    // boundary, so an injected backend would revert to the default inside.
    final kdf = WalletFileCrypto.kdf;
    final plaintext = await Isolate.run(
      () => WalletFileCrypto.decryptFromBase64(blob, password, kdf: kdf),
    );
    final json = jsonDecode(plaintext) as Map<String, dynamic>;

    _mnemonic = json['mnemonic'] as String;
    _address = json['address'] as String?;
    final iso = json['restore_date_iso'] as String?;
    _restoreDate = iso != null ? DateTime.tryParse(iso) : null;
    // Re-derive the address if an older file didn't store it.
    if (_address == null) {
      final mnemonic = _mnemonic!;
      _address = (await Isolate.run(() => deriveEthereumKeys(mnemonic))).address;
      // The only thing after a restore that changes what `store()` would write.
      // Without this the file is never brought up to date, because the refresh
      // cycle's store is gated on there being something new to persist.
      markStoreDirty();
    }
    _lastPassword = password;
    setIsLoaded(true);
  }

  @override
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {
    if (password.isEmpty) throw Exception('Password should not be empty.');
    // Every EVM coin is BIP39-only. The app's seed policy is the other half of
    // this check.
    checkSeedSupported(seed);

    if (seed.passphrase.isNotEmpty) {
      // Same reasoning as Bitcoin: honouring it would move the derived address,
      // and the wallet file has nowhere to persist it, so the next open would
      // derive a different, empty, account.
      throw UnsupportedSeedFormatException(
        seed.format,
        'a seed passphrase is not supported for $_coinSymbol',
      );
    }

    _restoreDate = await _resolveRestoreDate(from);

    final mnemonic = seed.mnemonic;
    final keys = await Isolate.run(() => deriveEthereumKeys(mnemonic));
    _mnemonic = mnemonic;
    _address = keys.address;
    await _persistTo(password);
    setIsLoaded(true);
  }

  /// Maps a [RestorePoint] onto the only thing an account-model wallet can
  /// record.
  ///
  /// There is nothing to scan *from*: the balance is a single `eth_getBalance`
  /// and the history comes from an explorer that returns its most recent page
  /// regardless. The date is metadata; a height is kept where
  /// [getRestoreHeight] can read it rather than dropped.
  Future<DateTime?> _resolveRestoreDate(RestorePoint from) async {
    switch (from) {
      case RestoreFromDate(:final date):
        return date;
      case RestoreNewWallet():
        return DateTime.now();
      case RestoreFromHeight(:final height):
        await SharedPreferencesService.set<int>(prefKey('walletRestoreHeight'), height);
        return null;
      case RestoreFromSeedBirthday():
        // BIP39 carries no birthday, and checkSeedSupported has already
        // rejected the one encoding that does.
        return null;
    }
  }

  Future<void> _persistTo(String password) async {
    _lastPassword = password;
    final file = await _walletFile();
    final json = jsonEncode({
      'mnemonic': _mnemonic,
      'address': _address,
      'restore_date_iso': _restoreDate?.toIso8601String(),
    });
    await file.writeAsString(await WalletFileCrypto.encryptToBase64(json, password));
  }

  /// This wallet's file holds a mnemonic, an address and a restore date, and
  /// none of the three changes because a block arrived. Inheriting the base's
  /// chain-progress signal would re-encrypt and rewrite the file; a PBKDF2
  /// derivation and a truncate-then-rewrite; once per Ethereum block, forever,
  /// to persist bytes identical to the ones already there.
  @override
  bool get storeTracksChainProgress => false;

  @override
  Future<bool> store() async {
    if (_mnemonic == null || _lastPassword == null) return false;
    try {
      await _persistTo(_lastPassword!);
      return true;
    } catch (e) {
      walletLog(LogLevel.warn, 'store failed: ${e.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> deleteFiles() async {
    final file = await _walletFile();
    if (await file.exists()) await file.delete();
    _mnemonic = null;
    _address = null;
    _privateKeyHex = null;
    _lastPassword = null;
    _balanceWei = BigInt.zero;
    _bestHeight = 0;
    _connected = false;
    _feeInputs = null;
    _txRecords.clear();
  }

  // ----- Connection / refresh -----

  static int? _socksPortFrom(String? proxyPort) =>
      (proxyPort != null && proxyPort.isNotEmpty) ? int.tryParse(proxyPort) : null;

  @override
  Future<void> connectToDaemonImpl({required String address, String? proxyPort}) async {
    _rpc.configure(url: address, socksPort: _socksPortFrom(proxyPort));
    final cid = await _rpc.chainId();
    if (cid != _chainId) {
      // A chain id is public network configuration, and getting this wrong is
      // the single most common RPC misconfiguration, so it is named in full.
      throw Exception('RPC is chain id $cid, expected $_chainId ($blockchainName).');
    }
    _bestHeight = await _rpc.blockNumber();
    _connected = true;
  }

  @override
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  }) async {
    // A separate client, because a probe must not mutate live connection state;
    // configuring `_rpc` here would repoint the open wallet at whatever the user
    // happened to be typing.
    final probe = EthereumRpcClient(coinSymbol: coinSymbol)
      ..configure(url: address, socksPort: _socksPortFrom(proxyPort));
    final cid = await probe.chainId();
    if (cid != _chainId) {
      throw Exception('This RPC is chain id $cid, not $_chainId ($blockchainName).');
    }
  }

  @override
  Future<void> testExplorerConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
  }) async {
    await _explorer.probe(address, socksPort: _socksPortFrom(proxyPort));
  }

  /// Resolves the explorer's own SOCKS port (its Tor proxy, or a custom one).
  ///
  /// Returns null when [explorerUseTor] is set but no Tor proxy is available;
  /// callers must fail closed and skip the request rather than go clearnet. The
  /// explorer URL carries the user's own address in its path, so an unproxied
  /// request here would hand a third party the address *and* the IP behind it.
  Future<int?> _explorerSocksPort() async {
    if (explorerUseTor) {
      final proxy = await TorSettingsService.sharedInstance.getProxy();
      return proxy?.port;
    }
    return _socksPortFrom(explorerProxyPort);
  }

  @override
  Future<bool> getIsConnected() async => _rpc.isConfigured && _connected;

  @override
  Future<void> refresh() async {
    if (!_rpc.isConfigured || _address == null) return;
    try {
      _bestHeight = await _rpc.blockNumber();
      _balanceWei = await _rpc.getBalance(_address!);
      _connected = true;
    } catch (e) {
      _connected = false;
      // Type only. An EthereumRpcException carries the node's own message, and
      // a node quotes the parameters it was sent; here, the address whose
      // balance we asked for.
      walletLog(LogLevel.warn, 'refresh failed: ${e.runtimeType}');
      return;
    }

    // Resolve pending txs via their receipts (block + actual fee + status).
    for (final r in _txRecords.values.where((r) => r.blockNumber == 0)) {
      try {
        final receipt = await _rpc.getTransactionReceipt(r.hash);
        if (receipt != null && receipt.blockNumber > 0) {
          r.blockNumber = receipt.blockNumber;
          r.status = receipt.status;
          if (receipt.effectiveGasPrice > BigInt.zero) {
            r.feeWei = receipt.gasUsed * receipt.effectiveGasPrice;
          }
        }
      } catch (e) {
        walletLog(LogLevel.warn, 'receipt ${Redact.id(r.hash)} failed: ${e.runtimeType}');
      }
    }
  }

  // ----- Stats -----

  /// Gas limit used when estimation is unavailable or reverts. A native transfer
  /// is 21000; ERC-20 transfers override to a safe higher value.
  @protected
  BigInt get fallbackGasLimit => BigInt.from(21000);

  @override
  Future<void> loadIsSynced() async => setIsSynced(_connected && _bestHeight > 0);

  @override
  Future<void> loadSyncedHeight() async => setSyncedHeight(_bestHeight > 0 ? _bestHeight : null);

  @override
  Future<void> loadTotalBalance() async {
    if (!_connected) return;
    setTotalBalanceBaseUnits(_balanceWei);
  }

  @override
  Future<void> loadUnlockedBalance() async {
    if (!_connected) return;
    setUnlockedBalanceBaseUnits(_balanceWei);
  }

  @override
  Future<int> getCurrentHeight() async => _bestHeight;

  @override
  Future<int> getRestoreHeight() async =>
      await SharedPreferencesService.get<int>(prefKey('walletRestoreHeight')) ?? 0;

  // ----- Tx history -----

  @override
  List<TxDetails> readTxHistory() {
    final tip = _bestHeight;
    final entries = _txRecords.values.map((r) {
      final confirmations = r.blockNumber > 0 && tip >= r.blockNumber ? tip - r.blockNumber + 1 : 0;
      return TxDetails(
        index: null,
        direction: r.direction,
        hash: r.hash,
        amountBaseUnits: r.valueWei,
        feeBaseUnits: r.feeWei,
        // The recipient is the destination of the transfer: for outgoing it's
        // the address we sent to; for incoming it's us. (The record's `to` field
        // holds the sender for incoming, which is 0x0 for mints, so resolve
        // incoming to our own address at display time.)
        recipients: [
          TxRecipient(r.direction == txDirectionOutgoing ? r.to : (_address ?? r.to), r.valueWei),
        ],
        accountIndex: 0,
        subaddrIndexList: const [],
        timestamp: r.timestamp,
        height: r.blockNumber > 0 ? r.blockNumber : -1,
        confirmations: confirmations,
        key: '',
        broadcastAt: r.direction == txDirectionOutgoing ? r.timestamp : null,
        status: _txStatusOf(r),
      );
    }).toList();
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries;
  }

  /// Maps a receipt's `status` onto the display vocabulary.
  ///
  /// This is the reader the field never had. Four places wrote it; the receipt
  /// poll, the explorer, the JSON reload and the broadcast default, and nothing
  /// read it, so a reverted transaction (gas spent, funds not moved) was
  /// persisted and displayed as completed.
  static TxStatus _txStatusOf(_EthTxRecord r) {
    // The chain has the last word: once a receipt has resolved, how the
    // transaction reached the mempool stops mattering.
    if (r.status == 0) return TxStatus.failed;
    if (r.status == 1) return TxStatus.ok;
    // No receipt seen. Mined without one means we asked and did not get an
    // answer, which is not the same as success.
    if (r.blockNumber > 0) return TxStatus.unknown;
    // Not mined yet: ordinary for a pending send, but not for one whose
    // broadcast we never saw accepted.
    return r.broadcastUnresolved ? TxStatus.unknown : TxStatus.ok;
  }

  @override
  Future<void> loadTxHistory({bool persistCount = true}) async {
    // Optional explorer fills in incoming + historical txs (RPC can't list an
    // address's history). Local records (current outgoing) take precedence.
    if (explorerAddress.isNotEmpty && _address != null) {
      try {
        final socks = await _explorerSocksPort();
        if (explorerUseTor && socks == null) {
          walletLog(
            LogLevel.warn,
            'explorerUseTor set but no Tor proxy; skipping explorer history',
          );
          await super.loadTxHistory(persistCount: persistCount);
          return;
        }
        final txs = await fetchExplorerTransfers(socks);
        final me = _address!.toLowerCase();
        for (final t in txs) {
          final isOut = t.from.toLowerCase() == me;
          _txRecords.putIfAbsent(
            t.hash,
            () => _EthTxRecord(
              hash: t.hash,
              direction: isOut ? txDirectionOutgoing : txDirectionIncoming,
              to: isOut ? t.to : t.from,
              valueWei: t.valueWei,
              feeWei: isOut ? t.feeWei : BigInt.zero,
              blockNumber: t.blockNumber,
              status: t.status,
              timestamp: t.timestamp,
            ),
          );
        }
      } catch (e) {
        walletLog(LogLevel.warn, 'explorer history fetch failed: ${e.runtimeType}');
      }
    }
    await super.loadTxHistory(persistCount: persistCount);
  }

  /// Address history from the explorer. Native transfers by default; ERC-20
  /// tokens override to fetch token transfers for their contract.
  @protected
  Future<List<ExplorerTx>> fetchExplorerTransfers(int? socksPort) =>
      _explorer.fetchTxList(explorerAddress, _address!, socksPort: socksPort);

  // ----- Send / receive -----

  @override
  String getPrimaryAddress() => _address ?? '';

  @override
  String? getReceiveAddress() => _address;

  @override
  bool isAddressValid(String address) {
    if (!_hexAddress.hasMatch(address)) return false;
    final body = address.substring(2);
    final mixedCase = body.contains(RegExp(r'[a-f]')) && body.contains(RegExp(r'[A-F]'));
    if (!mixedCase) return true; // all-lower or all-upper: no checksum to verify
    try {
      return EthAddrUtils.toChecksumAddress(address) == address;
    } catch (_) {
      return false;
    }
  }

  /// Gas for the send. A native transfer is 21000; estimate (to also cover
  /// contract recipients) with a 1-wei probe so it never reverts on
  /// insufficient funds, falling back to [fallbackGasLimit] if the node refuses.
  ///
  /// The node's answer is used as given; nothing caps it. See [_scaleTip].
  Future<BigInt> _resolveGasLimit(String from, String to, {String? data}) async {
    try {
      final est = await _rpc.estimateGas(
        from: from,
        to: to,
        value: data == null ? BigInt.one : BigInt.zero,
        data: data,
      );
      return est > BigInt.zero ? est : fallbackGasLimit;
    } catch (e) {
      // A revert reason is attacker-supplied text from a contract. The gas
      // number and the error type are the diagnostic part.
      walletLog(
        LogLevel.warn,
        'estimateGas failed (${e.runtimeType}); falling back to $fallbackGasLimit',
      );
      return fallbackGasLimit;
    }
  }

  /// Signing credentials, deriving (and caching) the private key once.
  ///
  /// The PBKDF2 runs in an isolate; capture a LOCAL mnemonic so the closure
  /// doesn't capture `this` (whose base-class Timers are unsendable).
  Future<EthPrivateKey> _credentials() async {
    if (_privateKeyHex == null) {
      final mnemonic = _mnemonic!;
      _privateKeyHex = (await Isolate.run(() => deriveEthereumKeys(mnemonic))).privateKeyHex;
    }
    return EthPrivateKey.fromHex(_privateKeyHex!);
  }

  /// Fetches the priority-independent fee inputs (base fee, tip suggestion,
  /// nonce, gas limit), reusing a cached set within [_feeInputsTtlMs] for the
  /// same destination so each priority doesn't re-hit the RPC.
  Future<({BigInt baseFee, BigInt tipBase, int nonce, BigInt gasLimit})> _resolveFeeInputs(
    String from,
    String to, {
    String? data,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _feeInputs;
    if (cached != null && cached.to == to && now - cached.atMs < _feeInputsTtlMs) {
      return (
        baseFee: cached.baseFee,
        tipBase: cached.tipBase,
        nonce: cached.nonce,
        gasLimit: cached.gasLimit,
      );
    }
    final baseFee = await _rpc.baseFeePerGas();
    final tipBase = await _rpc.maxPriorityFeePerGas();
    final nonce = await _rpc.getTransactionCount(from);
    final gasLimit = await _resolveGasLimit(from, to, data: data);
    _feeInputs = (
      baseFee: baseFee,
      tipBase: tipBase,
      nonce: nonce,
      gasLimit: gasLimit,
      to: to,
      atMs: now,
    );
    return (baseFee: baseFee, tipBase: tipBase, nonce: nonce, gasLimit: gasLimit);
  }

  /// Scales the node's suggested priority fee for the chosen priority.
  ///
  /// Deliberately unbounded. `suggested` comes from `eth_maxPriorityFeePerGas`,
  /// `baseFee` and `gasLimit` from the node; all three reach the signed
  /// transaction as given, and `feeBaseUnits` on the returned
  /// [EthereumPendingTx] is the exact total.
  ///
  /// This library never caps a fee. Judging whether the number is sane for
  /// current gas conditions belongs to the app's confirmation screen. Do not add
  /// a ceiling here.
  BigInt _scaleTip(BigInt suggested, int priority) {
    final tipFloor = suggested > BigInt.zero ? suggested : BigInt.from(1000000000); // 1 gwei floor
    final mult = switch (priority) {
      1 => 1, // low
      3 => 3, // high
      _ => 2, // normal / default
    };
    return tipFloor * BigInt.from(mult);
  }

  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) async {
    // Order of magnitude only. It still distinguishes dust from a sweep, which
    // is what send bugs turn on.
    walletLog(
      LogLevel.info,
      'createTx: ${Redact.amount(amountBaseUnits)} sweep=$isSweepAll prio=$priority '
      'loaded=${_address != null} configured=${_rpc.isConfigured} '
      'connected=$_connected balance=${Redact.amount(_balanceWei)}',
    );
    if (_mnemonic == null || _address == null) throw Exception('Wallet is not loaded.');
    if (!_rpc.isConfigured) throw Exception('Not connected to an RPC endpoint.');
    if (!isAddressValid(destinationAddress)) {
      walletLog(LogLevel.warn, 'createTx: invalid address ${Redact.id(destinationAddress)}');
      throw Exception('Invalid Ethereum address.');
    }
    if (amountBaseUnits < BigInt.zero) {
      throw ArgumentError('Amount must not be negative.');
    }

    final from = _address!;

    // EIP-1559 (type-2) fees. Base fee, tip suggestion, nonce, and gas limit
    // are the same across priorities → fetched once and cached; only the tip
    // is re-scaled here.
    final ({BigInt baseFee, BigInt tipBase, int nonce, BigInt gasLimit}) inputs;
    try {
      inputs = await _resolveFeeInputs(from, destinationAddress);
    } catch (e) {
      walletLog(LogLevel.warn, 'createTx fee RPC failed: ${e.runtimeType}');
      rethrow;
    }
    final tip = _scaleTip(inputs.tipBase, priority);
    final maxFeePerGas = inputs.baseFee * BigInt.two + tip;
    final gasLimit = inputs.gasLimit;
    final maxFeeTotal = gasLimit * maxFeePerGas;

    final BigInt valueWei;
    if (isSweepAll) {
      valueWei = _balanceWei - maxFeeTotal;
      if (valueWei <= BigInt.zero) {
        walletLog(
          LogLevel.info,
          'sweep too low: balance ${Redact.amount(_balanceWei)} '
          '< fee ${Redact.amount(maxFeeTotal)}',
        );
        throw Exception('Unlocked funds too low');
      }
    } else {
      // The caller hands over exact base units.
      valueWei = amountBaseUnits;
      if (valueWei + maxFeeTotal > _balanceWei) {
        walletLog(
          LogLevel.info,
          'insufficient: value ${Redact.amount(valueWei)} + '
          'fee ${Redact.amount(maxFeeTotal)} > balance ${Redact.amount(_balanceWei)}',
        );
        throw Exception('Unlocked funds too low');
      }
    }

    // Offline build + sign (no network: nonce/gas/fees/chainId all supplied).
    final Uint8List signed;
    try {
      final credentials = await _credentials();
      final tx = Transaction(
        from: credentials.address,
        to: EthereumAddress.fromHex(destinationAddress),
        value: EtherAmount.inWei(valueWei),
        maxGas: gasLimit.toInt(),
        maxPriorityFeePerGas: EtherAmount.inWei(tip),
        maxFeePerGas: EtherAmount.inWei(maxFeePerGas),
        nonce: inputs.nonce,
      );
      signed = await Web3Client(
        _rpc.url!,
        OfflineSigningClient(),
      ).signTransaction(credentials, tx, chainId: _chainId);
      // Length only, never the payload or the destination.
      walletLog(LogLevel.info, 'createTx signed ok (${signed.length} bytes)');
    } catch (e) {
      walletLog(LogLevel.warn, 'eth build/sign failed: ${e.runtimeType}');
      rethrow;
    }

    // One conversion, used for both: the hash must be of the exact bytes that
    // get broadcast.
    final raw = _asType2(signed);

    return EthereumPendingTx(
      amountBaseUnits: valueWei,
      feeBaseUnits: maxFeeTotal,
      rawHex: '0x${bytesToHex(raw)}',
      txHash: '0x${bytesToHex(keccak256(raw))}',
      to: destinationAddress,
    );
  }

  /// Prepends the EIP-2718 type byte when `web3dart` left it off.
  ///
  /// web3dart returns the EIP-1559 body as a bare RLP list; a valid type-2
  /// transaction is `0x02 || rlp(...)`. Without the byte the node decodes it as
  /// a legacy transaction, which is a different payload and a different hash.
  static Uint8List _asType2(Uint8List signed) =>
      (signed.isNotEmpty && signed[0] >= 0xc0) ? Uint8List.fromList([0x02, ...signed]) : signed;

  @override
  Future<void> commitTx(PendingTransaction tx, String destinationAddress) async {
    if (tx is! EthereumPendingTx) {
      throw ArgumentError('EthereumChainWallet.commitTx requires an EthereumPendingTx');
    }
    final hash = await _rpc.sendRawTransaction(tx.rawHex);
    // `tx.txHash` is keccak256 over the exact bytes being broadcast, so the node
    // has no say in what this transaction is called. A disagreement means it did
    // not relay what we handed it; different nonce, different fee, different
    // payload, and the tx we are about to record is not the tx that is now in
    // the mempool. Recorded as unresolved rather than trusted or discarded: the
    // signed bytes are out, and pretending otherwise in either direction is
    // worse than saying we do not know.
    final agreed = hash.toLowerCase() == tx.txHash.toLowerCase();
    if (!agreed) {
      walletLog(
        LogLevel.warn,
        'broadcast returned a different tx hash than the one we signed '
        '(ours ${Redact.id(tx.txHash)}, theirs ${Redact.id(hash)})',
      );
    } else {
      walletLog(LogLevel.info, 'broadcast ok: ${Redact.id(hash)}');
    }
    _feeInputs = null; // nonce advanced; force a fresh fetch next time

    _txRecords[tx.txHash] = _EthTxRecord(
      hash: tx.txHash,
      direction: txDirectionOutgoing,
      to: tx.to,
      valueWei: tx.amountBaseUnits,
      feeWei: tx.feeBaseUnits,
      blockNumber: 0,
      status: -1,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      broadcastUnresolved: !agreed,
    );

    try {
      await refresh();
      await loadTxHistory();
    } catch (e) {
      walletLog(LogLevel.warn, 'post-broadcast refresh failed: ${e.runtimeType}');
    }

    // Last, so the record above and the refresh have both happened: the caller
    // needs to know the outcome is unresolved, and the wallet still needs the
    // transaction in its history while that is true.
    if (!agreed) {
      throw const BroadcastFailure(
        BroadcastOutcome.unknown,
        detail: 'the node reported a different transaction hash than the one signed',
      );
    }
  }

  // ----- Snapshot persistence -----

  @override
  Future<void> persistWalletSnapshot() async {
    await super.persistWalletSnapshot();
    if (_txRecords.isEmpty) return;
    try {
      final json = jsonEncode({
        'txs': [for (final r in _txRecords.values) r.toJson()],
      });
      cachePut('cachedEthTxs', json);
    } catch (e) {
      // Type only: a jsonEncode failure quotes the offending value, and the
      // value here is a transaction record.
      walletLog(LogLevel.warn, 'persist eth txs failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> loadPersistedSnapshot() async {
    await super.loadPersistedSnapshot();
    try {
      final raw = cacheGetString('cachedEthTxs');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      final txs = decoded is Map<dynamic, dynamic> ? decoded['txs'] : null;
      if (txs is! List<dynamic>) return;
      for (final t in txs) {
        if (t is! Map<dynamic, dynamic>) continue;
        final r = _EthTxRecord.fromJson(t.cast<String, dynamic>());
        if (r != null) _txRecords[r.hash] = r;
      }
    } catch (e) {
      // A FormatException from jsonDecode carries a snippet of its source.
      walletLog(LogLevel.warn, 'load eth txs failed: ${e.runtimeType}');
    }
  }
}

/// Locally-tracked EVM transaction (outgoing recorded at broadcast; incoming
/// added by the optional explorer). Mutable fields are updated when the receipt
/// resolves.
class _EthTxRecord {
  _EthTxRecord({
    required this.hash,
    required this.direction,
    required this.to,
    required this.valueWei,
    required this.feeWei,
    required this.blockNumber,
    required this.status,
    required this.timestamp,
    this.broadcastUnresolved = false,
  });

  final String hash;
  final int direction;
  final String to;

  /// Base units: wei for a native transfer, raw token units for an ERC-20 one.
  final BigInt valueWei;

  /// Always wei; gas is paid in the native coin.
  BigInt feeWei;

  int blockNumber; // 0 = pending
  int status; // 1 success, 0 failed, -1 no receipt seen

  /// True when this wallet broadcast the transaction and never saw it accepted.
  ///
  /// Distinct from `status == -1`, which is the ordinary state of a send that
  /// simply has not been mined yet. Conflating the two reports "we do not know
  /// whether this went out" as an unremarkable pending transaction, which is
  /// the same false receipt the broadcast checks exist to prevent.
  bool broadcastUnresolved;

  /// Unix seconds; broadcast time, or block time from the explorer.
  final int timestamp;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'direction': direction,
    'to': to,
    'value_wei': valueWei.toString(),
    'fee_wei': feeWei.toString(),
    'block': blockNumber,
    'status': status,
    'ts': timestamp,
    // Omitted in the common case, so an older reader sees the same bytes.
    if (broadcastUnresolved) 'unresolved': true,
  };

  static _EthTxRecord? fromJson(Map<String, dynamic> j) {
    final hash = j['hash'] as String?;
    if (hash == null) return null;
    return _EthTxRecord(
      hash: hash,
      direction: (j['direction'] as num?)?.toInt() ?? txDirectionOutgoing,
      to: j['to'] as String? ?? '',
      valueWei: BigInt.tryParse(j['value_wei'] as String? ?? '0') ?? BigInt.zero,
      feeWei: BigInt.tryParse(j['fee_wei'] as String? ?? '0') ?? BigInt.zero,
      blockNumber: (j['block'] as num?)?.toInt() ?? 0,
      status: (j['status'] as num?)?.toInt() ?? -1,
      timestamp: (j['ts'] as num?)?.toInt() ?? 0,
      broadcastUnresolved: j['unresolved'] == true,
    );
  }
}
