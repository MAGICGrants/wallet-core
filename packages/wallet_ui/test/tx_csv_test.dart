import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart' show exportFileName;
import 'package:wallet_ui/wallet_ui.dart';

/// Only the getters the CSV reads; a real wallet would leave timers running.
class _FakeWallet implements CryptoWallet {
  _FakeWallet({
    this.coinSymbol = 'XMR',
    this.blockchainName = 'Monero',
    this.baseUnitDecimals = 12,
    this.feeCoinSymbol = 'XMR',
    this.feeBaseUnitDecimals = 12,
  });

  @override
  final String coinSymbol;
  @override
  final String blockchainName;
  @override
  final int baseUnitDecimals;
  @override
  final String feeCoinSymbol;
  @override
  final int feeBaseUnitDecimals;

  @override
  bool isTxConfirmed(TxDetails tx) => tx.confirmations >= 10;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TxDetails _tx({
  int direction = txDirectionIncoming,
  BigInt? amount,
  BigInt? fee,
  List<TxRecipient> recipients = const [],
  int confirmations = 10,
  int height = 3000000,
  TxStatus status = TxStatus.ok,
  String hash = 'abc123',
}) => TxDetails(
  index: 0,
  direction: direction,
  hash: hash,
  amountBaseUnits: amount ?? BigInt.from(1500000000000),
  feeBaseUnits: fee ?? BigInt.from(30000000),
  recipients: recipients,
  accountIndex: 0,
  subaddrIndexList: const [],
  timestamp: 1760709785, // 2025-10-17T14:03:05Z
  height: height,
  confirmations: confirmations,
  key: 'secret-tx-key',
  status: status,
);

List<List<String>> _rows(String csv) {
  expect(csv, endsWith('\r\n'));
  return [for (final line in csv.split('\r\n')..removeLast()) line.split(',')];
}

void main() {
  final xmr = _FakeWallet();

  test('a header, then one row per transaction, in the order given', () {
    final csv = txHistoryCsv([
      (tx: _tx(hash: 'newer'), asset: xmr),
      (tx: _tx(hash: 'older'), asset: xmr),
    ]);
    final rows = _rows(csv);
    expect(rows.first, txCsvHeader);
    expect(rows.skip(1).map((r) => r.last), ['newer', 'older']);
  });

  test('a received transaction: exact amount, no fee, where it was received', () {
    final row = _rows(
      txHistoryCsv([
        (tx: _tx(recipients: [TxRecipient('8Sub', BigInt.one)]), asset: xmr),
      ]),
    )[1];
    expect(row, [
      '2025-10-17T14:03:05Z',
      'XMR',
      'Monero',
      'Received',
      '1.5',
      '',
      '',
      'Confirmed',
      '10',
      '3000000',
      '8Sub',
      'abc123',
    ]);
  });

  test('a sent transaction: its fee in the fee asset, and change left out', () {
    final eth = _FakeWallet(
      coinSymbol: 'USDC',
      blockchainName: 'Ethereum',
      baseUnitDecimals: 6,
      feeCoinSymbol: 'ETH',
      feeBaseUnitDecimals: 18,
    );
    final row = _rows(
      txHistoryCsv([
        (
          tx: _tx(
            direction: txDirectionOutgoing,
            amount: BigInt.from(25000000),
            fee: BigInt.parse('210000000000000'),
            recipients: [
              TxRecipient('0xPaid', BigInt.one),
              TxRecipient('0xChange', BigInt.one, isChange: true),
            ],
          ),
          asset: eth,
        ),
      ]),
    )[1];
    expect(row.sublist(1, 7), ['USDC', 'Ethereum', 'Sent', '25', '0.00021', 'ETH']);
    expect(row[10], '0xPaid');
  });

  test('pending, failed and unknown read as such; no height while pending', () {
    String status(TxDetails tx) => _rows(txHistoryCsv([(tx: tx, asset: xmr)]))[1][7];
    expect(status(_tx(confirmations: 0, height: 0)), 'Pending');
    expect(_rows(txHistoryCsv([(tx: _tx(height: 0), asset: xmr)]))[1][9], '');
    expect(status(_tx(status: TxStatus.failed)), 'Failed');
    expect(status(_tx(status: TxStatus.unknown)), 'Unknown');
  });

  test('several addresses are joined, and the field quoted only when it must be', () {
    final csv = txHistoryCsv([
      (
        tx: _tx(
          direction: txDirectionOutgoing,
          recipients: [TxRecipient('4A', BigInt.one), TxRecipient('4B', BigInt.one)],
        ),
        asset: xmr,
      ),
    ]);
    expect(csv, contains(',4A; 4B,'));
  });

  test('a comma, a quote or a formula is made harmless', () {
    final csv = txHistoryCsv([
      (tx: _tx(hash: '=HYPERLINK("x")'), asset: _FakeWallet(blockchainName: 'Chain, one')),
    ]);
    expect(csv, contains('"Chain, one"'));
    expect(csv, contains('"\'=HYPERLINK(""x"")"'));
  });

  test('no transaction key is ever written', () {
    expect(txHistoryCsv([(tx: _tx(), asset: xmr)]), isNot(contains('secret-tx-key')));
  });

  test('exact decimals at any scale', () {
    expect(decimalAmount(BigInt.from(1500000000000), 12), '1.5');
    expect(decimalAmount(BigInt.one, 12), '0.000000000001');
    expect(decimalAmount(BigInt.zero, 12), '0');
    expect(decimalAmount(BigInt.parse('123456789012345678901'), 18), '123.456789012345678901');
    expect(decimalAmount(BigInt.from(42), 0), '42');
  });

  test('an export is named after the app and the day', () {
    expect(
      exportFileName('skylight-history', 'csv', DateTime(2026, 3, 7)),
      'skylight-history-20260307.csv',
    );
  });
}
