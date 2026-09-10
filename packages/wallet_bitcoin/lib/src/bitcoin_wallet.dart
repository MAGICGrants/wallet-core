import 'package:bitcoin_base/bitcoin_base.dart';

import 'bitcoin_chain_wallet.dart';

/// Bitcoin mainnet: BIP84 `m/84'/0'/0'`, [BitcoinNetwork.mainnet].
class BitcoinWallet extends BitcoinChainWallet {
  BitcoinWallet({super.client})
    : super(
        network: BitcoinNetwork.mainnet,
        bip84AccountPath: "m/84'/0'/0'",
        coinSymbol: 'BTC',
        blockchainName: 'Bitcoin',
        iconAsset: 'assets/icons/bitcoin.svg',
        connectionAddressExample: 'electrum.example.com:50002',
        isTestnet: false,
      );

  /// OpenAlias network and asset. Both are `btc`, since Bitcoin's network and
  /// its native asset are the same thing. They diverge for a token on a chain.
  @override
  String get aliasNetwork => 'btc';
}

/// Bitcoin testnet as a separate coin: BIP84 `m/84'/1'/0'`,
/// [BitcoinNetwork.testnet]. Use a **testnet** Electrum server.
class BitcoinTestnetWallet extends BitcoinChainWallet {
  BitcoinTestnetWallet({super.client})
    : super(
        network: BitcoinNetwork.testnet,
        bip84AccountPath: "m/84'/1'/0'",
        coinSymbol: 'TBTC',
        blockchainName: 'Bitcoin Testnet',
        iconAsset: 'assets/icons/bitcoin_testnet.svg',
        connectionAddressExample: 'electrum.example.com:50002',
        isTestnet: true,
      );

  /// Testnet coins have no price of their own; the fiat column borrows mainnet's.
  @override
  String get fiatBaseSymbol => 'BTC';

  // No `aliasNetwork` override, so alias resolution stays off. An OpenAlias
  // record publishes a mainnet address, and resolving one here would offer to
  // pay it from a testnet wallet.
}
