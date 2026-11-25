/// What a wallet calls the receive addresses it hands out one after another.
///
/// Only a wallet that hands out more than one has a kind
/// (`CryptoWallet.rotatingAddressKind`); Ethereum and its tokens keep one
/// address and have none.
enum RotatingAddressKind {
  /// Monero: index 0 of account 0 is the primary address, and every other
  /// index is a subaddress.
  subaddress,

  /// Bitcoin's external chain: every index is just an address.
  address,
}

/// One of the wallet's own receive addresses that has received at least one
/// transaction, with what arrived at it.
class UsedReceiveAddress {
  const UsedReceiveAddress({
    required this.address,
    required this.index,
    required this.receivedBaseUnits,
    required this.txCount,
    required this.lastUsed,
  });

  final String address;

  /// Its place in the wallet's sequence: the subaddress index in account 0, or
  /// the index on Bitcoin's external chain.
  final int index;

  /// Everything received at it, in the coin's base units.
  ///
  /// Known limitation, Monero on a light-wallet server: lwsf reports a
  /// transaction that paid several of the wallet's subaddresses as one entry
  /// with the total, not the amount per subaddress. The whole of it is
  /// credited to the first subaddress (and only that one counts the
  /// transaction), the same address the transaction's own details name as
  /// where it was received. A node's wallet2 lists each subaddress's amount
  /// separately, so it is exact there.
  final BigInt receivedBaseUnits;

  /// How many transactions it received.
  final int txCount;

  /// When it last received one, in Unix seconds.
  final int lastUsed;
}

/// One transaction's credit to one of the wallet's own receive addresses.
typedef AddressReceipt = ({
  String address,
  int index,
  BigInt amountBaseUnits,
  String txHash,
  int timestamp,
});

/// [receipts] summed per address, most recently used first, the higher index
/// first between two last used at the same second.
///
/// A transaction is counted once per address even when the history lists it
/// more than once (wallet2 gives one entry per subaddress it paid). A receipt
/// with no timestamp yet (0: still in the mempool, on some chains) counts as
/// [now].
List<UsedReceiveAddress> summarizeReceipts(Iterable<AddressReceipt> receipts, {DateTime? now}) {
  final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final byAddress = <String, ({int index, BigInt total, Set<String> txs, int last})>{};
  for (final r in receipts) {
    final when = r.timestamp > 0 ? r.timestamp : nowSeconds;
    final seen = byAddress[r.address];
    if (seen == null) {
      byAddress[r.address] = (
        index: r.index,
        total: r.amountBaseUnits,
        txs: {r.txHash},
        last: when,
      );
      continue;
    }
    byAddress[r.address] = (
      index: seen.index,
      total: seen.total + r.amountBaseUnits,
      txs: seen.txs..add(r.txHash),
      last: when > seen.last ? when : seen.last,
    );
  }
  final out = [
    for (final e in byAddress.entries)
      UsedReceiveAddress(
        address: e.key,
        index: e.value.index,
        receivedBaseUnits: e.value.total,
        txCount: e.value.txs.length,
        lastUsed: e.value.last,
      ),
  ];
  out.sort((a, b) {
    final byTime = b.lastUsed.compareTo(a.lastUsed);
    return byTime != 0 ? byTime : b.index.compareTo(a.index);
  });
  return out;
}
