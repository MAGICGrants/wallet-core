part of 'ethereum_chain_wallet.dart';

/// An ERC-20 token on an EVM chain.
///
/// Shares the parent chain coin's address (same derivation) and connection (its
/// RPC + explorer), so it has no setup of its own. Balance comes from
/// `balanceOf`, sends are a `transfer(to,amount)` call to the token contract,
/// and the **fee is paid in the chain's native coin, not the token**, which is
/// why `feeCoinSymbol`, `feeDecimals`, `feeIconAsset` and `feeBaseUnitDecimals`
/// all diverge from the amount's here.
class Erc20ChainWallet extends EthereumChainWallet {
  Erc20ChainWallet({
    required super.chainId,
    required super.coinSymbol,
    required super.blockchainName,
    required String assetName,
    required super.iconAsset,
    required super.isTestnet,
    required this.tokenContractAddress,
    required this.tokenDecimals,
    required this.parentCoinSymbol,
    int displayDecimals = 6,
    int displaySmallerDigits = 2,
    super.rpc,
    super.explorer,
  }) : _assetName = assetName,
       _displayDecimals = displayDecimals,
       _displaySmallerDigits = displaySmallerDigits,
       super(connectionAddressExample: '');

  final String tokenContractAddress;
  final int tokenDecimals;
  final String parentCoinSymbol;
  final String _assetName;
  final int _displayDecimals;
  final int _displaySmallerDigits;

  BigInt _tokenBalanceRaw = BigInt.zero;

  // ----- Metadata / connection reuse -----

  /// A token's asset name always differs from its chain's: Dai on Ethereum.
  @override
  String get assetName => _assetName;

  @override
  int get decimals => _displayDecimals;
  @override
  int get smallerDigits => _displaySmallerDigits;

  @override
  String get feeCoinSymbol => parentCoinSymbol;
  @override
  int get feeDecimals => 10; // native ETH display precision
  @override
  String get feeIconAsset =>
      isTestnet ? 'assets/icons/ethereum_sepolia.svg' : 'assets/icons/ethereum.svg';

  /// The amount is in token units; the fee is in wei. This is the case the
  /// getter exists for; see `CryptoWallet.feeBaseUnitDecimals`.
  @override
  int get feeBaseUnitDecimals => EthereumChainWallet.weiDecimals;

  // The token has its own RPC/explorer setup screens (like any coin), but the
  // config is shared with the parent chain coin's namespace, so setting it from
  // either the token or the parent works and never needs entering twice.
  @override
  String get connectionPrefSymbol => parentCoinSymbol;

  @override
  BigInt get fallbackGasLimit => BigInt.from(100000);

  // ----- Balance -----

  @override
  Future<void> refresh() async {
    // Native balance (for gas) + receipt polling.
    await super.refresh();
    if (!_connected || _address == null) return;
    try {
      final hex = await _rpc.ethCall(tokenContractAddress, erc20BalanceOfData(_address!));
      _tokenBalanceRaw = _parseHexBig(hex);
    } catch (e) {
      walletLog(LogLevel.warn, 'token balanceOf failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> loadTotalBalance() async {
    if (!_connected) return;
    setTotalBalanceBaseUnits(_tokenBalanceRaw);
  }

  @override
  Future<void> loadUnlockedBalance() async {
    if (!_connected) return;
    setUnlockedBalanceBaseUnits(_tokenBalanceRaw);
  }

  @override
  int get baseUnitDecimals => tokenDecimals;

  // ----- History -----

  @override
  Future<List<ExplorerTx>> fetchExplorerTransfers(int? socksPort) => _explorer.fetchTokenTransfers(
    explorerAddress,
    _address!,
    tokenContractAddress,
    socksPort: socksPort,
  );

  // ----- Send -----

  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) async {
    if (_mnemonic == null || _address == null) throw Exception('Wallet is not loaded.');
    if (!_rpc.isConfigured) throw Exception('Not connected to an RPC endpoint.');
    if (!isAddressValid(destinationAddress)) throw Exception('Invalid Ethereum address.');
    final from = _address!;

    // Exact token units.
    final rawAmount = isSweepAll ? _tokenBalanceRaw : amountBaseUnits;
    if (rawAmount <= BigInt.zero || rawAmount > _tokenBalanceRaw) {
      throw Exception('Unlocked funds too low');
    }

    // EIP-1559 (type-2) call to the token contract: value 0, transfer in data.
    final dataHex = erc20TransferData(destinationAddress, rawAmount);
    final inputs = await _resolveFeeInputs(from, tokenContractAddress, data: dataHex);
    final tip = _scaleTip(inputs.tipBase, priority);
    final maxFeePerGas = inputs.baseFee * BigInt.two + tip;
    final maxFeeTotal = inputs.gasLimit * maxFeePerGas;
    // Gas is paid in the native coin, separate from the token balance; a wallet
    // full of tokens and empty of ETH cannot send.
    if (maxFeeTotal > _balanceWei) {
      walletLog(
        LogLevel.info,
        'insufficient gas: fee ${Redact.amount(maxFeeTotal)} > '
        'native ${Redact.amount(_balanceWei)}',
      );
      throw Exception('Insufficient gas funds');
    }

    final Uint8List signed;
    try {
      final credentials = await _credentials();
      final tx = Transaction(
        from: credentials.address,
        to: EthereumAddress.fromHex(tokenContractAddress),
        value: EtherAmount.zero(),
        maxGas: inputs.gasLimit.toInt(),
        maxPriorityFeePerGas: EtherAmount.inWei(tip),
        maxFeePerGas: EtherAmount.inWei(maxFeePerGas),
        nonce: inputs.nonce,
        data: hexToBytes(dataHex),
      );
      signed = await Web3Client(
        _rpc.url!,
        OfflineSigningClient(),
      ).signTransaction(credentials, tx, chainId: chainId);
    } catch (e) {
      walletLog(LogLevel.warn, 'erc20 build/sign failed: ${e.runtimeType}');
      rethrow;
    }

    final raw = EthereumChainWallet._asType2(signed);

    return EthereumPendingTx(
      // Token units; the fee stays in wei. readTxHistory carries both through
      // unscaled and the app renders each with its own decimals.
      amountBaseUnits: rawAmount,
      feeBaseUnits: maxFeeTotal,
      rawHex: '0x${bytesToHex(raw)}',
      txHash: '0x${bytesToHex(keccak256(raw))}',
      to: destinationAddress,
    );
  }

  @override
  Future<void> deleteFiles() async {
    await super.deleteFiles();
    _tokenBalanceRaw = BigInt.zero;
  }

  static BigInt _parseHexBig(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.isEmpty) return BigInt.zero;
    return BigInt.parse(clean, radix: 16);
  }
}
