import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Payment details from an imported backup file, kept in the wallet file
/// (`keepPaymentDetails`): wallet2 has a payment's key and destinations only
/// when it built the payment itself.

const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _password = 'the-existing-password';

/// An outgoing transaction as a wallet that did not build it sees it: no
/// destinations and no key.
NativeTxInfo _sent(String hash) => NativeTxInfo(
  direction: txDirectionOutgoing,
  hash: hash,
  amount: BigInt.from(1000000000000),
  fee: BigInt.from(30000000),
  timestamp: 1700000000,
  blockHeight: 2900000,
  confirmations: 20,
  subaddrAccount: 0,
  subaddrIndex: '0',
  isPending: false,
  isFailed: false,
  paymentId: '',
  txKey: '',
);

final _paid = '4${'p' * 94}';

BackedUpPayment _imported({String key = 'imported-key', String? to}) => BackedUpPayment(
  recipients: [TxRecipient(to ?? _paid, BigInt.from(1000000000000))],
  txKey: key,
);

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kept_payments');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    useTestCaBundle();
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void connect(MoneroWallet w) => w.setConnection(
    address: 'lws.example.com:18090',
    proxyPort: '',
    useTor: false,
    connectionType: 'lws',
  );

  /// A synced wallet whose history has [transactions].
  Future<void> openWallet(List<NativeTxInfo> transactions) async {
    connect(wallet);
    await wallet.restoreFromSeed(
      seed: MoneroLegacySeed(_legacy25),
      from: RestorePoint.height(2800000),
      password: _password,
    );
    final path = await wallet.walletPathForType('lws');
    await File(path).writeAsString('wallet');
    backend.existingWalletPaths.add(path);
    backend.synchronizedValue = true;
    backend.walletHeight = 3000000;
    backend.chainHeight = 3000000;
    backend.balanceValue = BigInt.from(5000000000000);
    backend.unlockedBalanceValue = BigInt.from(5000000000000);
    backend.transactions = transactions;
    await wallet.load();
  }

  test('kept in the wallet file, and given to a payment once it is synced', () async {
    await openWallet([]);

    expect(await wallet.keepPaymentDetails({'sent-1': _imported()}), isTrue);
    expect(backend.cacheAttributes, contains(MoneroWallet.keptPaymentsAttribute));
    expect(backend.called('store'), isTrue, reason: 'saved with the wallet file');

    // Not in the history yet; it arrives with a later sync.
    backend.transactions = [_sent('sent-1')];
    await wallet.loadTxHistory();
    expect(wallet.txHistory.single.recipients.single.address, _paid);
    expect(wallet.txHistory.single.key, 'imported-key');
  });

  test('read back from the wallet file after it is reopened', () async {
    await openWallet([]);
    await wallet.keepPaymentDetails({'sent-1': _imported()});
    wallet.dispose();

    // A new wallet over the same file: nothing carried over in memory.
    wallet = MoneroWallet(backend: backend);
    await openWallet([_sent('sent-1')]);
    expect(wallet.txHistory.single.recipients.single.address, _paid);
    expect(wallet.txHistory.single.key, 'imported-key');
  });

  test('fills gaps only: what is kept stays', () async {
    await openWallet([]);
    await wallet.keepPaymentDetails({'sent-1': _imported(key: 'first')});
    await wallet.keepPaymentDetails({
      'sent-1': _imported(key: 'second', to: '4${'z' * 94}'),
      'sent-2': _imported(key: 'other'),
    });

    final stored = jsonDecode(backend.cacheAttributes[MoneroWallet.keptPaymentsAttribute]!);
    final payments = (stored as Map<String, dynamic>)['payments'] as Map<String, dynamic>;
    expect((payments['sent-1'] as Map<String, dynamic>)['key'], 'first');
    expect((payments['sent-2'] as Map<String, dynamic>)['key'], 'other');
  });

  test('an unreadable attribute is left as it is, and nothing is kept', () async {
    backend.cacheAttributes[MoneroWallet.keptPaymentsAttribute] = 'not json';
    await openWallet([_sent('sent-1')]);

    expect(await wallet.keepPaymentDetails({'sent-1': _imported()}), isFalse);
    expect(backend.cacheAttributes[MoneroWallet.keptPaymentsAttribute], 'not json');
    expect(wallet.txHistory.single.key, isEmpty);
  });
}
