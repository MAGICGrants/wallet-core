// monero.dart marks almost its whole surface `@Deprecated("TODO")`, the
// generator's marker for "not yet exercised"; there is no replacement API.
// ignore_for_file: deprecated_member_use

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:polyseed/polyseed.dart';
import 'package:wallet_monero/wallet_monero.dart';

import 'support/fake_lws.dart';
import 'support/monero_test_crypto.dart';
import 'support/monero_tx.dart';

/// LWSF building, signing and submitting real transactions through the
/// wallet's own backend, against a light-wallet server that reports outputs
/// the wallet really owns.
///
/// Monero's transaction construction refuses a change output it cannot place
/// in the sender's own account, and refuses to spend an output whose key it
/// cannot derive. So each case fails if LWSF hands it the wrong account keys,
/// or leaves the change address out of the subaddresses it may use: a send
/// with change from the first account, the same from a second account whose
/// funds sit at one of its later subaddresses, and a sweep of each account
/// back to itself, where the destination is the change address.
///
/// The submitted transaction is then read back. Its id must be the one the
/// wallet reported, every ring must hold one of the wallet's outputs, and
/// every output must open, under the recipient's or the wallet's view key, to
/// the amount it should carry, with the change in the first address of the
/// account it was spent from.
///
/// Runs in `native.yml`, which builds the library and sets MONERO_LIB_PATH
/// and the loader path (the backend loads the library by name in each isolate
/// it spawns). Skips without the library, or fails under REQUIRE_MONERO_FFI=1.
void main() {
  final libPath = Platform.environment['MONERO_LIB_PATH'];
  final required = Platform.environment['REQUIRE_MONERO_FFI'] == '1';

  bool libraryLoads() {
    if (libPath != null && libPath.isNotEmpty) monero.libPath = libPath;
    try {
      monero.WalletManagerFactory_getLWSFWalletManager();
      return true;
    } catch (_) {
      return false;
    }
  }

  final available = libraryLoads();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('lwsf_send'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const cases = [
    (name: 'account 0: a send with change', account: 0, receivedAt: 0, sweep: false),
    (
      name:
          'account 1: a send with change, from funds at a subaddress other than the change address',
      account: 1,
      receivedAt: 1,
      sweep: false,
    ),
    (name: 'account 0: a sweep back to its own address', account: 0, receivedAt: 0, sweep: true),
    (name: 'account 1: a sweep back to its own address', account: 1, receivedAt: 1, sweep: true),
  ];

  for (final c in cases) {
    test(c.name, () async {
      if (!available) {
        if (required) {
          fail(
            'REQUIRE_MONERO_FFI=1 but monero_c did not load (libPath="${monero.libPath}"). '
            'Build it with scripts/build-moneroc-ci.sh and set MONERO_LIB_PATH.',
          );
        }
        return markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
      }
      await _send(
        tmp,
        libPath: libPath,
        account: c.account,
        receivedAt: c.receivedAt,
        sweep: c.sweep,
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}

/// What the wallet holds before each send: two outputs, so a send of
/// [_sendAmount] spends both and has change.
final _funds = [BigInt.from(700000000000), BigInt.from(500000000000)];
final _sendAmount = BigInt.from(1000000000000);

/// Creates a wallet, has [FakeLws] report [_funds] at subaddress
/// ([account], [receivedAt]), and sends from [account]: [_sendAmount] to
/// another wallet, or with [sweep], everything back to the account's own
/// first address.
Future<void> _send(
  Directory dir, {
  required String? libPath,
  required int account,
  required int receivedAt,
  required bool sweep,
}) async {
  const backend = FfiMoneroBackend();
  final manager = await backend.getWalletManager(MoneroManagerKind.lws);
  final wallet = await backend.createWalletFromPolyseed(
    manager,
    mnemonic: Polyseed.create().encode(
      PolyseedLang.getByEnglishName('English'),
      PolyseedCoin.POLYSEED_MONERO,
    ),
    seedOffset: '',
    restoreHeight: 0,
    path: '${dir.path}/wallet',
    password: 'send-test',
    newWallet: true,
    kdfRounds: 1,
  );
  FakeLws? server;
  addTearDown(() async {
    await backend.closeWallet(manager, wallet, store: false);
    await server?.close();
  });
  expect(await backend.walletErrorString(wallet), isEmpty, reason: 'creating the wallet');

  // The wallet's keys, derived from its spend key alone by a second Monero
  // implementation, and checked against the addresses LWSF reports.
  final keys = Monero.fromPrivateSpendKey(
    BytesUtils.fromHexString(await backend.secretSpendKey(wallet)),
  );
  expect(await backend.address(wallet), keys.primaryAddress);
  expect(
    await backend.address(wallet, accountIndex: account, addressIndex: receivedAt),
    keys.subaddress(receivedAt, majorIndex: account),
  );
  final viewSecret = MoneroTestCrypto.scalar(keys.privateViewKey.raw);
  List<int> spendKey(int major, int minor) =>
      keys.scubaddr.computeKeys(minor, major).item1.compressed;

  server = await FakeLws.start(
    outputs: [
      for (final (i, amount) in _funds.indexed)
        FakeLwsOutput.paying(
          amount: amount,
          viewSecret: viewSecret,
          spendPublicKey: spendKey(account, receivedAt),
          major: account,
          minor: receivedAt,
          globalIndex: 1000000 + i,
        ),
    ],
  );
  String seen() => 'server saw ${server!.requests.map((r) => r.path).join(' ')}';

  await backend.init(
    wallet,
    daemonAddress: server.url,
    proxyAddress: '',
    useSsl: false,
    lightWallet: true,
  );
  expect(
    await backend.connectToDaemon(wallet),
    isTrue,
    reason: '${await backend.walletErrorString(wallet)}; ${seen()}',
  );
  final login = server.requests.firstWhere((r) => r.path == '/login').body! as Map<String, Object?>;
  expect(login['address'], keys.primaryAddress);
  expect(login['view_key'], BytesUtils.toHexString(keys.privateViewKey.raw));

  await backend.refresh(wallet);
  final total = _funds.reduce((a, b) => a + b);
  expect(
    await backend.unlockedBalance(wallet, accountIndex: account),
    total,
    reason:
        'the wallet must take the outputs as its own; '
        '${await backend.walletErrorString(wallet)}; ${seen()}',
  );

  final recipient = Monero.fromPrivateSpendKey(
    MoneroTestCrypto.scalarBytes(MoneroTestCrypto.randomScalar()),
  );
  final pending = await backend.createTransaction(
    wallet,
    destinations: [sweep ? keys.subaddress(0, majorIndex: account) : recipient.primaryAddress],
    amounts: [sweep ? BigInt.zero : _sendAmount],
    isSweepAll: sweep,
    mixinCount: MoneroConsts.mixinCount,
    subaddrAccount: account,
  );
  expect(await backend.pendingTxErrorString(pending), isEmpty, reason: seen());
  expect(await backend.pendingTxStatus(pending), 0);
  final fee = await backend.pendingTxFee(pending);
  final reportedAmount = await backend.pendingTxAmount(pending);
  final txid = await Isolate.run(() {
    if (libPath != null && libPath.isNotEmpty) monero.libPath = libPath;
    return monero.PendingTransaction_txid(ffi.Pointer.fromAddress(pending.id), '');
  });

  expect(
    await backend.commitPendingTx(pending),
    isTrue,
    reason: '${await backend.pendingTxErrorString(pending)}; ${seen()}',
  );
  expect(await backend.pendingTxErrorString(pending), isEmpty);
  expect(server.submitted, hasLength(1), reason: seen());

  final tx = MoneroTx.parse(server.submitted.single);
  expect(
    BytesUtils.toHexString(tx.hash),
    txid,
    reason: 'the server must receive the transaction the wallet reported',
  );
  expect(tx.rctType, MoneroTx.rctTypeBulletproofPlus);
  expect(tx.unlockTime, BigInt.zero);
  expect(tx.fee, fee, reason: 'the fee the wallet reports is the one in the transaction');
  expect(fee, greaterThan(BigInt.zero));

  // Each ring is full and holds exactly one of the wallet's outputs; no output
  // is spent twice.
  final ours = {for (final o in server.outputs) o.globalIndex: o.amount};
  final spent = <int>[];
  for (final input in tx.inputs) {
    expect(input.ring, hasLength(MoneroConsts.mixinCount + 1));
    final real = input.ring.where(ours.containsKey).toList();
    expect(real, hasLength(1), reason: 'ring ${input.ring}');
    spent.add(real.single);
  }
  expect(spent.toSet(), hasLength(spent.length));
  final spentTotal = spent.fold(BigInt.zero, (sum, i) => sum + ours[i]!);

  // Every output pays either the recipient or the first address of the
  // account spent from, the change address, and opens to its amount.
  final recipientView = MoneroTestCrypto.scalar(recipient.privateViewKey.raw);
  final recipientSpend = recipient.publicSpendKey.compressed;
  final changeSpend = spendKey(account, 0);
  final paid = <BigInt>[];
  final kept = <BigInt>[];
  for (var i = 0; i < tx.outputs.length; i++) {
    final toRecipient = tx.amountPaidTo(
      i,
      viewSecret: recipientView,
      spendPublicKey: recipientSpend,
    );
    final toChange = tx.amountPaidTo(i, viewSecret: viewSecret, spendPublicKey: changeSpend);
    expect(
      [?toRecipient, ?toChange],
      hasLength(1),
      reason: 'output $i must pay the recipient or the change address, and only one',
    );
    if (toRecipient != null) paid.add(toRecipient);
    if (toChange != null) kept.add(toChange);
  }
  final keptTotal = kept.fold(BigInt.zero, (a, b) => a + b);
  final paidTotal = paid.fold(BigInt.zero, (a, b) => a + b);
  expect(spentTotal, paidTotal + keptTotal + fee, reason: 'inputs = outputs + fee');

  if (sweep) {
    // The reported amount is not compared: for a sweep, LWSF computes it from
    // its fee estimate before building the transaction, and then settles the
    // difference from the actual fee in the output. The outputs are checked.
    expect(spentTotal, total, reason: 'a sweep spends everything in the account');
    expect(paid, isEmpty);
    expect(keptTotal, total - fee);
  } else {
    expect(paid, [_sendAmount]);
    expect(reportedAmount, _sendAmount);
    expect(keptTotal, greaterThan(BigInt.zero), reason: 'this send has change');
  }
}
