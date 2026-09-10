import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// SHA-256 applied twice: Bitcoin's `HASH256`.
///
/// Lives here rather than in `wallet_bitcoin` because `wallet_infra` already
/// carries pointycastle, and a coin package should not take a crypto dependency
/// for one hash.
///
/// Not routed through `bitcoin_base`: the caller re-derives the txid of a
/// transaction `bitcoin_base` built, so sharing its implementation would make
/// the check circular.
///
/// Only the double form is exported. A bare `sha256` would collide at every use
/// site that also imports `blockchain_utils`, which most of `wallet_bitcoin`
/// does.
Uint8List sha256d(List<int> data) => _sha256(_sha256(data));

Uint8List _sha256(List<int> data) =>
    SHA256Digest().process(data is Uint8List ? data : Uint8List.fromList(data));
