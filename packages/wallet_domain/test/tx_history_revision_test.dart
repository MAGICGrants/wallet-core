import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

TxDetails _tx(String hash, int timestamp) => TxDetails(
  index: 0,
  direction: txDirectionIncoming,
  hash: hash,
  amountBaseUnits: BigInt.one,
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: timestamp,
  height: 100,
  confirmations: 1,
  key: '',
);

/// What lets a screen cache what it derives from the history: a revision that
/// moves whenever the history is replaced, and the newest entry without a copy.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tx_history_revision');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  });

  tearDown(() {
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the revision moves with every history read and on unload', () async {
    final wallet = FakeWallet('XMR');
    addTearDown(wallet.dispose);
    final start = wallet.txHistoryRevision;
    expect(wallet.newestTx, isNull);

    wallet.history = [_tx('b', 200), _tx('a', 100)];
    await wallet.loadTxHistory(persistCount: false);
    final afterFirst = wallet.txHistoryRevision;
    expect(afterFirst, isNot(start));
    expect(wallet.newestTx?.hash, 'b');

    await wallet.loadTxHistory(persistCount: false);
    expect(wallet.txHistoryRevision, isNot(afterFirst));

    wallet.setIsLoadedForTesting(false);
    expect(wallet.newestTx, isNull);
  });

  test('an empty read that keeps the cached history keeps the revision', () async {
    final wallet = FakeWallet('XMR');
    addTearDown(wallet.dispose);
    wallet.history = [_tx('a', 100)];
    await wallet.loadTxHistory(persistCount: false);
    final revision = wallet.txHistoryRevision;

    wallet.history = const [];
    await wallet.loadTxHistory(persistCount: false);
    expect(wallet.txHistoryRevision, revision);
    expect(wallet.newestTx?.hash, 'a');
  });
}
