/// Ethereum and ERC-20 implementations of `CryptoWallet`.
///
/// Kept separate so an app without Ethereum support never resolves, fetches or
/// compiles `web3dart`.
library;

export 'src/erc20_abi.dart';
export 'src/ethereum_chain_wallet.dart';
export 'src/ethereum_explorer_client.dart';
export 'src/ethereum_keys.dart';
export 'src/ethereum_pending_tx.dart';
export 'src/ethereum_rpc_api.dart';
export 'src/ethereum_rpc_client.dart';
export 'src/ethereum_wallet.dart';
export 'src/fake_ethereum_rpc.dart';
export 'src/offline_signing_client.dart';
