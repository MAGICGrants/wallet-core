import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

TxDetails _tx({
  BigInt? amount,
  BigInt? fee,
  List<TxRecipient>? recipients,
  TxStatus status = TxStatus.ok,
}) => TxDetails(
  index: 3,
  direction: 1,
  hash: 'abc123',
  amountBaseUnits: amount ?? BigInt.from(1000),
  feeBaseUnits: fee ?? BigInt.from(10),
  recipients: recipients ?? const [],
  accountIndex: 0,
  subaddrIndexList: const [1, 2],
  timestamp: 1700000000,
  height: 3000000,
  confirmations: 12,
  key: 'txkey',
  status: status,
);

void main() {
  group('JSON round trip', () {
    test('preserves every field', () {
      final tx = _tx(recipients: [TxRecipient('4Addr', BigInt.zero, isChange: true)]);
      final back = TxDetails.fromJson(jsonDecode(jsonEncode(tx.toJson())) as Map<String, dynamic>);

      expect(back.index, tx.index);
      expect(back.direction, tx.direction);
      expect(back.hash, tx.hash);
      expect(back.amountBaseUnits, tx.amountBaseUnits);
      expect(back.feeBaseUnits, tx.feeBaseUnits);
      expect(back.accountIndex, tx.accountIndex);
      expect(back.subaddrIndexList, tx.subaddrIndexList);
      expect(back.timestamp, tx.timestamp);
      expect(back.height, tx.height);
      expect(back.confirmations, tx.confirmations);
      expect(back.key, tx.key);
      expect(back.status, tx.status);
      expect(back.recipients.single.isChange, isTrue);
    });

    test('broadcastAt is omitted when null and kept when set', () {
      expect(_tx().toJson().containsKey('broadcastAt'), isFalse);

      final withBroadcast = TxDetails(
        index: null,
        direction: 0,
        hash: 'h',
        amountBaseUnits: BigInt.one,
        feeBaseUnits: BigInt.zero,
        recipients: const [],
        accountIndex: null,
        subaddrIndexList: const [],
        timestamp: 1,
        height: 1,
        confirmations: 0,
        key: '',
        broadcastAt: 1700000123,
      );
      expect(TxDetails.fromJson(withBroadcast.toJson()).broadcastAt, 1700000123);
    });
  });

  group('amounts survive JSON', () {
    test('are serialised as strings, not numbers', () {
      // JSON numbers are IEEE doubles. Writing a base-unit amount as a number
      // would reintroduce exactly the precision loss BigInt exists to prevent.
      final json = _tx(amount: BigInt.parse('9007199254740993')).toJson();
      expect(json['amount'], isA<String>());
      expect(json['fee'], isA<String>());
    });

    test('a value above 2^53 round-trips exactly through encode/decode', () {
      final big = BigInt.parse('18446744073709551615'); // 2^64 - 1
      final tx = _tx(amount: big, fee: BigInt.parse('9007199254740993'));
      final back = TxDetails.fromJson(jsonDecode(jsonEncode(tx.toJson())) as Map<String, dynamic>);

      expect(back.amountBaseUnits, big);
      expect(back.feeBaseUnits, BigInt.parse('9007199254740993'));
      // The same value through a double would not survive.
      expect(BigInt.from(big.toDouble()), isNot(big));
    });

    test('recipient amounts get the same treatment', () {
      final big = BigInt.parse('12345678901234567890');
      final tx = _tx(recipients: [TxRecipient('4Addr', big)]);
      final back = TxDetails.fromJson(jsonDecode(jsonEncode(tx.toJson())) as Map<String, dynamic>);
      expect(back.recipients.single.amountBaseUnits, big);
    });

    test('a legacy numeric amount is still readable', () {
      // Spice's unreleased builds wrote numbers. Accepted so an existing dev
      // cache loads; rewritten as a string on the next save.
      final back = TxDetails.fromJson({..._tx().toJson(), 'amount': 1500, 'fee': 25});
      expect(back.amountBaseUnits, BigInt.from(1500));
      expect(back.feeBaseUnits, BigInt.from(25));
    });
  });

  group('parseCachedTxHistory never throws', () {
    test('parses a good list', () {
      final json = jsonEncode([_tx().toJson(), _tx().toJson()]);
      expect(parseCachedTxHistory(json), hasLength(2));
    });

    test('returns empty for garbage, truncation and wrong shapes', () {
      // A cache is derived data that a crash mid-write can truncate. Failing
      // to parse must mean "re-sync", not "take down the caller".
      final badInputs = [
        '',
        '   ',
        'not json',
        '{',
        '[{"direction":1},',
        '{"not":"a list"}',
        'null',
        '42',
      ];
      for (final input in badInputs) {
        expect(parseCachedTxHistory(input), isEmpty, reason: 'input: $input');
      }
    });

    test('drops only the malformed entries, keeping the good ones', () {
      final json = jsonEncode([
        _tx().toJson(),
        {'direction': 1}, // missing required fields
        'not even a map',
        _tx().toJson(),
      ]);
      expect(parseCachedTxHistory(json), hasLength(2));
    });

    test('an empty list is empty, not an error', () {
      expect(parseCachedTxHistory('[]'), isEmpty);
    });
  });

  group('status', () {
    // The field Ethereum's receipt `status` had nowhere to go, so a reverted
    // transaction (gas spent, funds not moved) was displayed as completed.

    test('defaults to ok, so a coin that cannot say claims nothing', () {
      expect(_tx().status, TxStatus.ok);
    });

    test('survives a JSON round trip', () {
      for (final status in TxStatus.values) {
        final restored = TxDetails.fromJson(
          jsonDecode(jsonEncode(_tx(status: status).toJson())) as Map<String, dynamic>,
        );
        expect(restored.status, status, reason: status.name);
      }
    });

    test('ok is omitted from the JSON entirely', () {
      // So the common case costs nothing on disk and an older reader sees the
      // same bytes it always saw.
      expect(_tx().toJson().containsKey('status'), isFalse);
      expect(_tx(status: TxStatus.failed).toJson()['status'], 'failed');
    });

    test('a cache written before this field existed reads back as ok', () {
      // Strip the key from an entry that *would* have carried one, so this
      // asserts the absent-key path rather than restating the omission above.
      final legacy = _tx(status: TxStatus.failed).toJson()..remove('status');
      expect(legacy.containsKey('status'), isFalse);
      expect(TxDetails.fromJson(legacy).status, TxStatus.ok);
    });

    test('an unrecognised status reads as ok rather than throwing', () {
      // The cache is derived data; a value from a future build must degrade, not
      // discard the record.
      final future = _tx().toJson()..['status'] = 'quantum-superposition';
      expect(TxDetails.fromJson(future).status, TxStatus.ok);
      expect(TxStatus.fromName(null), TxStatus.ok);
    });

    test('a failed transaction still parses out of a cached list', () {
      final json = jsonEncode([_tx(status: TxStatus.failed).toJson()]);
      expect(parseCachedTxHistory(json).single.status, TxStatus.failed);
    });
  });

  group('toString is safe to log', () {
    test('TxDetails names neither the hash nor the amount', () {
      final s = _tx(amount: BigInt.parse('123456789012')).toString();
      expect(s, isNot(contains('abc123')));
      expect(s, isNot(contains('123456789012')));
      expect(s, contains('h=3000000'));
      expect(s, contains('conf=12'));
      expect(s, contains('status=ok'));
    });

    test('TxRecipient names neither the address nor the amount', () {
      const address = '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98';
      final s = TxRecipient(address, BigInt.parse('987654321')).toString();
      expect(s, isNot(contains(address)));
      expect(s, isNot(contains('987654321')));
    });
  });
}
