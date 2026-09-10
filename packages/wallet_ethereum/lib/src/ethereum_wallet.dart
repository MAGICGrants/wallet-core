import 'ethereum_chain_wallet.dart';

/// Ethereum mainnet.
class EthereumWallet extends EthereumChainWallet {
  EthereumWallet({super.rpc, super.explorer})
    : super(
        chainId: 1,
        coinSymbol: 'ETH',
        blockchainName: 'Ethereum',
        iconAsset: 'assets/icons/ethereum.svg',
        connectionAddressExample: 'rpc.example.com',
        isTestnet: false,
      );

  /// The chain is Ethereum; the asset it settles in is Ether.
  @override
  String get assetName => 'Ether';
}

/// Ethereum Sepolia as a separate coin. Same derived address as mainnet; EVM
/// networks differ by chain id, not derivation path.
class EthereumSepoliaWallet extends EthereumChainWallet {
  EthereumSepoliaWallet({super.rpc, super.explorer})
    : super(
        chainId: 11155111,
        coinSymbol: 'SETH',
        blockchainName: 'Ethereum Sepolia',
        iconAsset: 'assets/icons/ethereum_sepolia.svg',
        connectionAddressExample: 'rpc.example.com',
        isTestnet: true,
      );

  @override
  String get assetName => 'Sepolia Ether';

  /// Testnet coins have no price of their own; the fiat column borrows mainnet's.
  @override
  String get fiatBaseSymbol => 'ETH';

  // No `aliasNetwork` override is needed: an alias publishes a mainnet address
  // and the base class would resolve one for network `eth`. This coin inherits
  // `eth` from EthereumChainWallet, which is wrong for the same reason it is
  // wrong for testnet Bitcoin.
  @override
  String get aliasNetwork => '';
}

/// DAI on Ethereum mainnet (canonical contract). Shares the `ETH` coin's address
/// and RPC + explorer connection.
class DaiWallet extends Erc20ChainWallet {
  DaiWallet({super.rpc, super.explorer})
    : super(
        chainId: 1,
        coinSymbol: 'DAI',
        blockchainName: 'Ethereum',
        assetName: 'Dai',
        iconAsset: 'assets/icons/dai.svg',
        isTestnet: false,
        tokenContractAddress: '0x6B175474E89094C44Da98b954EedeAC495271d0F',
        tokenDecimals: 18,
        parentCoinSymbol: 'ETH',
      );

  /// OpenAlias separates network from asset, which is what a token needs: paid on
  /// `eth`, denominated in `dai`.
  @override
  String get aliasAsset => 'dai';
}

/// DAI on Ethereum Sepolia (Aave faucet "DAI - Faucet Open" test token). Shares
/// the `SETH` coin's address and RPC + explorer connection.
class DaiSepoliaWallet extends Erc20ChainWallet {
  DaiSepoliaWallet({super.rpc, super.explorer})
    : super(
        chainId: 11155111,
        coinSymbol: 'SDAI',
        blockchainName: 'Ethereum Sepolia',
        assetName: 'Sepolia Dai',
        iconAsset: 'assets/icons/dai_sepolia.svg',
        isTestnet: true,
        tokenContractAddress: '0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357',
        tokenDecimals: 18,
        parentCoinSymbol: 'SETH',
      );

  @override
  String get fiatBaseSymbol => 'DAI';

  @override
  String get aliasNetwork => '';
}
