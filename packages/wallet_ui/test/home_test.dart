import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fiat/wallet_fiat.dart' show FiatApiMode;
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The getters the home reads; a real wallet would leave timers running.
class _Coin implements CryptoWallet {
  _Coin(
    this.coinSymbol, {
    this.assetName = 'Monero',
    this.baseUnitDecimals = 12,
    this.decimals = 12,
    this.requiredConfirmations = 10,
    this.averageBlockTime = const Duration(minutes: 2),
    this.canSpendPendingBalance = false,
    this._feeCoinSymbol,
    this.isTestnet = false,
  });

  @override
  final String coinSymbol;
  @override
  final String assetName;
  @override
  final int baseUnitDecimals;
  @override
  final int decimals;
  @override
  final int requiredConfirmations;
  @override
  final Duration? averageBlockTime;
  @override
  final bool canSpendPendingBalance;
  @override
  final bool isTestnet;
  final String? _feeCoinSymbol;

  @override
  String get feeCoinSymbol => _feeCoinSymbol ?? coinSymbol;
  @override
  bool get feeIsForeign => feeCoinSymbol != coinSymbol;
  @override
  String get iconAsset => '';

  BigInt? total;
  BigInt? unlocked;
  @override
  BigInt? get totalBalanceBaseUnits => total;
  @override
  BigInt? get unlockedBalanceBaseUnits => unlocked;
  @override
  double? get unlockedBalance => unlocked == null
      ? null
      : unlocked!.toDouble() / BigInt.from(10).pow(baseUnitDecimals).toDouble();

  List<TxDetails> _history = const [];
  int reads = 0;
  int revision = 0;
  set history(List<TxDetails> value) {
    _history = value;
    revision++;
  }

  @override
  List<TxDetails> get txHistory {
    reads++;
    return List.unmodifiable(_history);
  }

  @override
  int get txHistoryRevision => revision;
  @override
  TxDetails? get newestTx => _history.isEmpty ? null : _history.first;

  @override
  bool isTxConfirmed(TxDetails tx) => tx.height != -1 && tx.confirmations >= requiredConfirmations;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _day = Duration.secondsPerDay;
final _now = DateTime.utc(2026, 10, 19, 12);
int get _nowSec => _now.millisecondsSinceEpoch ~/ 1000;

TxDetails _tx({
  required int daysAgo,
  required int amount,
  int fee = 0,
  int direction = txDirectionIncoming,
  int confirmations = 100,
  int height = 3000000,
  TxStatus status = TxStatus.ok,
  String hash = 'h',
}) => TxDetails(
  index: 0,
  direction: direction,
  hash: hash,
  amountBaseUnits: BigInt.from(amount),
  feeBaseUnits: BigInt.from(fee),
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: _nowSec - daysAgo * _day,
  height: height,
  confirmations: confirmations,
  key: '',
  status: status,
);

const _labels = HomeLabels(
  incomingTitle: 'Incoming',
  incomingMore: _incomingMore,
  unlocksIn: _unlocksIn,
  confirmations: _confirmations,
  chartTitle: 'Balance · 90 days',
  chartToday: 'Today',
  chartEachCoin: "Each coin's balance",
  chartNew: 'New',
  chartEmpty: 'Nothing yet',
);
String _incomingMore(int others) => 'Incoming (+$others)';
String _unlocksIn(int minutes, int done, int needed) => 'unlocks $minutes min $done/$needed';
String _confirmations(int done, int needed) => '$done/$needed confirmations';

void main() {
  group('HomeActivity.compute', () {
    test('walks the balance back from now through each transaction', () {
      final coin = _Coin('XMR');
      final history = [
        _tx(daysAgo: 5, amount: 500),
        _tx(daysAgo: 50, amount: 200, fee: 10, direction: txDirectionOutgoing),
        _tx(daysAgo: 80, amount: 1000),
      ];
      final a = HomeActivity.compute(coin, history, BigInt.from(1290), _now);

      // Ninety days ago, before all three; then one step at each, at its own
      // time; the last is the balance now.
      expect(a.balanceSteps.map((s) => s.balance), [
        BigInt.zero,
        BigInt.from(1000),
        BigInt.from(790),
        BigInt.from(1290),
      ]);
      final at = a.balanceSteps.map((s) => s.at).toList();
      expect(at.first, 0);
      expect(at[1], closeTo(10 / 90, 1e-9));
      expect(at[2], closeTo(40 / 90, 1e-9));
      expect(at[3], closeTo(85 / 90, 1e-9));
      expect(a.hasHistory, isTrue);
    });

    test('what happened in the same second is one step', () {
      final coin = _Coin('XMR');
      final history = [
        _tx(daysAgo: 5, amount: 300, hash: 'a'),
        _tx(daysAgo: 5, amount: 200, hash: 'b'),
        _tx(daysAgo: 8, amount: 50, hash: 'c'),
        _tx(daysAgo: 8, amount: 50, direction: txDirectionOutgoing, hash: 'd'),
      ];
      final a = HomeActivity.compute(coin, history, BigInt.from(500), _now);
      expect(a.balanceSteps.map((s) => s.balance), [BigInt.zero, BigInt.from(500)]);
    });

    test('with nothing in the window the balance is one flat step', () {
      final coin = _Coin('XMR');
      final a = HomeActivity.compute(coin, [_tx(daysAgo: 200, amount: 70)], BigInt.from(70), _now);
      expect(a.balanceSteps, [(at: 0.0, balance: BigInt.from(70))]);
    });

    test('a send with change moves the balance once, by what left and the fee', () {
      // 100 BTC received; later 10 BTC sent from that 100 BTC input, 90 back as
      // change. The wallet records the send once: 10 out, plus the fee, with
      // the change as a recipient of our own rather than a receipt.
      final btc = _Coin('BTC', baseUnitDecimals: 8, decimals: 8, requiredConfirmations: 1);
      final coin = BigInt.from(100000000);
      const fee = 10000;
      final sent = TxDetails(
        index: 0,
        direction: txDirectionOutgoing,
        hash: 'out',
        amountBaseUnits: coin * BigInt.from(10),
        feeBaseUnits: BigInt.from(fee),
        recipients: [
          TxRecipient('them', coin * BigInt.from(10)),
          TxRecipient('our-change', coin * BigInt.from(90), isChange: true),
        ],
        accountIndex: 0,
        subaddrIndexList: const [],
        timestamp: _nowSec - 30 * _day,
        height: 3000000,
        confirmations: 100,
        key: '',
      );
      final receipt = _tx(daysAgo: 60, amount: 100 * 100000000, hash: 'in');
      final now = coin * BigInt.from(90) - BigInt.from(fee);
      final a = HomeActivity.compute(btc, [sent, receipt], now, _now);

      final b = a.balanceSteps.map((s) => s.balance).toList();
      final moves = [for (var i = 1; i < b.length; i++) b[i] - b[i - 1]];
      expect(moves, [coin * BigInt.from(100), -(coin * BigInt.from(10) + BigInt.from(fee))]);
      expect(b.reduce((x, y) => x > y ? x : y), coin * BigInt.from(100));
    });

    test('a reverted send costs only its fee, a failed receipt nothing', () {
      final coin = _Coin('ETH', baseUnitDecimals: 18, requiredConfirmations: 12);
      final history = [
        _tx(
          daysAgo: 10,
          amount: 300,
          fee: 7,
          direction: txDirectionOutgoing,
          status: TxStatus.failed,
        ),
        _tx(daysAgo: 20, amount: 999, status: TxStatus.failed),
      ];
      final a = HomeActivity.compute(coin, history, BigInt.from(100), _now);
      expect(a.balanceSteps.first.balance, BigInt.from(107));
    });

    test("a token's gas is counted on its chain coin, not on the token", () {
      final eth = _Coin('ETH', baseUnitDecimals: 18, requiredConfirmations: 12);
      final dai = _Coin('DAI', baseUnitDecimals: 18, feeCoinSymbol: 'ETH');
      final daiSend = _tx(daysAgo: 10, amount: 50, fee: 3, direction: txDirectionOutgoing);

      final ethView = HomeActivity.compute(
        eth,
        const [],
        BigInt.from(100),
        _now,
        feesPaidFor: [daiSend],
      );
      expect(ethView.balanceSteps.first.balance, BigInt.from(103));

      final daiView = HomeActivity.compute(dai, [daiSend], BigInt.from(10), _now);
      expect(daiView.balanceSteps.first.balance, BigInt.from(60), reason: 'the fee is not in Dai');
    });

    test('gas the chain coin already lists for a token transfer counts once', () {
      final eth = _Coin('ETH', baseUnitDecimals: 18, requiredConfirmations: 12);
      final daiSend = _tx(
        daysAgo: 10,
        amount: 50,
        fee: 3,
        direction: txDirectionOutgoing,
        hash: 'call',
      );
      // An explorer reports the contract call on the Ether side too: value 0,
      // the same gas.
      final ethCall = _tx(
        daysAgo: 10,
        amount: 0,
        fee: 3,
        direction: txDirectionOutgoing,
        hash: 'call',
      );
      final a = HomeActivity.compute(
        eth,
        [ethCall],
        BigInt.from(100),
        _now,
        feesPaidFor: [daiSend],
      );
      expect(a.balanceSteps.first.balance, BigInt.from(103));
    });

    test('the last point is the balance now, even for a block time ahead of the clock', () {
      final coin = _Coin('XMR');
      final ahead = TxDetails(
        index: 0,
        direction: txDirectionIncoming,
        hash: 'ahead',
        amountBaseUnits: BigInt.from(40),
        feeBaseUnits: BigInt.zero,
        recipients: const [],
        accountIndex: 0,
        subaddrIndexList: const [0],
        timestamp: _nowSec + 90,
        height: 3000000,
        confirmations: 1,
        key: '',
      );
      final a = HomeActivity.compute(coin, [ahead], BigInt.from(100), _now);
      expect(a.balanceSteps, [
        (at: 0.0, balance: BigInt.from(60)),
        (at: 1.0, balance: BigInt.from(100)),
      ]);
    });

    test('never draws a balance below zero', () {
      final coin = _Coin('XMR');
      final history = [_tx(daysAgo: 10, amount: 500)];
      final a = HomeActivity.compute(coin, history, BigInt.from(100), _now);
      expect(a.balanceSteps.first.balance, BigInt.zero);
    });

    test('lists incoming payments still locked, newest first', () {
      final coin = _Coin('XMR');
      final history = [
        _tx(daysAgo: 0, amount: 1, confirmations: 2, hash: 'new'),
        _tx(daysAgo: 1, amount: 1, confirmations: 6, hash: 'older'),
        _tx(daysAgo: 0, amount: 1, confirmations: 1, direction: txDirectionOutgoing, hash: 'out'),
        _tx(daysAgo: 0, amount: 1, confirmations: 0, status: TxStatus.failed, hash: 'failed'),
        _tx(daysAgo: 3, amount: 1, confirmations: 40, hash: 'done'),
      ];
      final a = HomeActivity.compute(coin, history, BigInt.zero, _now);
      expect([for (final t in a.pendingIncoming) t.hash], ['new', 'older']);
    });
  });

  group('HomeActivity.of', () {
    test('reads the history once until it, the balance or the day changes', () {
      final activity = HomeActivity();
      final coin = _Coin('XMR')
        ..total = BigInt.from(10)
        ..history = [_tx(daysAgo: 1, amount: 10)];

      final first = activity.of(coin, now: _now);
      for (var i = 0; i < 20; i++) {
        expect(identical(activity.of(coin, now: _now), first), isTrue);
      }
      expect(coin.reads, 1, reason: 'every rebuild would otherwise copy the whole history');

      coin.history = [_tx(daysAgo: 0, amount: 5), _tx(daysAgo: 1, amount: 10)];
      expect(identical(activity.of(coin, now: _now), first), isFalse);

      final second = activity.of(coin, now: _now);
      coin.total = BigInt.from(15);
      expect(identical(activity.of(coin, now: _now), second), isFalse);

      final third = activity.of(coin, now: _now);
      expect(identical(activity.of(coin, now: _now.add(const Duration(days: 1))), third), isFalse);
    });

    test('mostRecent is the coin with the newest transaction', () {
      final xmr = _Coin('XMR')..history = [_tx(daysAgo: 4, amount: 1)];
      final btc = _Coin('BTC', baseUnitDecimals: 8)..history = [_tx(daysAgo: 2, amount: 1)];
      final eth = _Coin('ETH', baseUnitDecimals: 18);
      expect(HomeActivity.mostRecent([xmr, btc, eth]), btc);
      expect(HomeActivity.mostRecent([eth]), isNull);
      expect(xmr.reads, 0, reason: 'the newest entry is read without a copy');
    });
  });

  group('HomeSections', () {
    test('a locked Monero receipt shows when it unlocks; elsewhere, confirmations', () {
      final sections = HomeSections(activity: HomeActivity(), labels: _labels);
      final xmr = _Coin('XMR')
        ..total = BigInt.from(2000000000000)
        ..unlocked = BigInt.from(1000000000000)
        ..history = [_tx(daysAgo: 0, amount: 661800000000, confirmations: 6)];
      final eth =
          _Coin(
              'ETH',
              assetName: 'Ether',
              baseUnitDecimals: 18,
              decimals: 6,
              requiredConfirmations: 12,
              averageBlockTime: const Duration(seconds: 12),
            )
            ..total = BigInt.one
            ..unlocked = BigInt.one
            ..history = [_tx(daysAgo: 0, amount: 1, confirmations: 3, height: -1)];

      final btc =
          _Coin(
              'BTC',
              assetName: 'Bitcoin',
              baseUnitDecimals: 8,
              decimals: 8,
              requiredConfirmations: 1,
              averageBlockTime: const Duration(minutes: 10),
              canSpendPendingBalance: true,
            )
            ..total = BigInt.from(2100)
            ..unlocked = BigInt.from(2100)
            ..history = [_tx(daysAgo: 0, amount: 2100, confirmations: 0, height: 0)];

      final card = sections.incoming([
        (wallet: xmr, tokens: const <CryptoWallet>[]),
        (wallet: btc, tokens: const <CryptoWallet>[]),
      ], now: _now)!;
      final ethCard = sections.incoming([
        (wallet: eth, tokens: const <CryptoWallet>[]),
      ], now: _now)!;
      final details = {
        for (final i in [...card.items, ...ethCard.items]) i.title: i.detail,
      };
      expect(details['Monero'], 'unlocks 8 min 6/10');
      expect(details['Ether'], '0/12 confirmations', reason: 'a mempool tx has no confirmations');
      expect(details['Bitcoin'], '0/1 confirmations', reason: 'a spendable receipt only confirms');
      final monero = card.items.firstWhere((i) => i.title == 'Monero');
      expect(monero.amount, '+0.66180 XMR');
      expect(monero.progress, closeTo(0.6, 1e-9));
    });

    test('lists the two newest and counts the rest in the title', () {
      final sections = HomeSections(activity: HomeActivity(), labels: _labels);
      final xmr = _Coin('XMR')
        ..history = [
          for (var i = 0; i < 4; i++) _tx(daysAgo: i, amount: 1, confirmations: 2, hash: 'tx$i'),
        ];
      final card = sections.incoming([(wallet: xmr, tokens: const <CryptoWallet>[])], now: _now)!;
      expect(card.items, hasLength(2));
      expect(card.title, 'Incoming (+2)');

      final two = _Coin('XMR')
        ..history = [
          for (var i = 0; i < 2; i++) _tx(daysAgo: i, amount: 1, confirmations: 2, hash: 'tx$i'),
        ];
      final plain = sections.incoming([(wallet: two, tokens: const <CryptoWallet>[])], now: _now)!;
      expect(plain.items, hasLength(2));
      expect(plain.title, 'Incoming');
    });

    test('no incoming card without pending receipts', () {
      final sections = HomeSections(activity: HomeActivity(), labels: _labels);
      final xmr = _Coin('XMR')..history = [_tx(daysAgo: 3, amount: 1)];
      expect(sections.incoming([(wallet: xmr, tokens: const <CryptoWallet>[])], now: _now), isNull);
    });

    test('one coin: its change in coins; several: a percentage or "New"', () {
      final sections = HomeSections(activity: HomeActivity(), labels: _labels);
      final xmr = _Coin('XMR')
        ..total = BigInt.from(8100000000000)
        ..history = [_tx(daysAgo: 30, amount: 5100000000000)];
      final single = sections.chart([(wallet: xmr, tokens: const <CryptoWallet>[])], now: _now);
      expect(single.note, '+5.1 XMR');
      expect(single.emptyText, isNull);

      final btc = _Coin('BTC', baseUnitDecimals: 8, decimals: 8)
        ..total = BigInt.from(1000)
        ..history = [_tx(daysAgo: 30, amount: 1000)];
      final several = sections.chart([
        (wallet: xmr, tokens: const <CryptoWallet>[]),
        (wallet: btc, tokens: const <CryptoWallet>[]),
      ], now: _now);
      expect(several.note, "Each coin's balance");
      expect(several.series.map((s) => s.change), ['+170%', 'New']);
    });

    test('before any transaction the chart says so instead of drawing', () {
      final sections = HomeSections(activity: HomeActivity(), labels: _labels);
      final xmr = _Coin('XMR')..total = BigInt.zero;
      final card = sections.chart([(wallet: xmr, tokens: const <CryptoWallet>[])], now: _now);
      expect(card.emptyText, 'Nothing yet');
    });

    test("allocation sums each chain's tokens and leaves testnet coins out", () {
      final eth = _Coin('ETH', baseUnitDecimals: 18)..unlocked = BigInt.from(10).pow(18);
      final dai = _Coin('DAI', baseUnitDecimals: 18)
        ..unlocked = BigInt.from(10).pow(18) * BigInt.from(2);
      final seth = _Coin('SETH', baseUnitDecimals: 18, isTestnet: true)
        ..unlocked = BigInt.from(10).pow(18);
      final slices = HomeSections.allocation([
        (wallet: eth, tokens: <CryptoWallet>[dai]),
        (wallet: seth, tokens: const <CryptoWallet>[]),
      ], (symbol) => {'ETH': 3000.0, 'DAI': 1.0, 'SETH': 3000.0}[symbol]);
      expect(slices.map((s) => s.label), ['ETH']);
      expect(slices.single.value, 3002);
    });
  });

  group('home widgets', () {
    Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('a section left null takes no space', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WalletHomeView(
            header: const Text('header'),
            actions: const Text('actions'),
            bottomNavigationBar: const SizedBox(height: 10),
            chart: const Text('chart'),
          ),
        ),
      );
      expect(find.text('chart'), findsOneWidget);
      expect(
        find.byType(SizedBox).evaluate().where((e) {
          final w = e.widget as SizedBox;
          return w.height == 20 && w.width == null;
        }).length,
        1,
        reason: 'one gap, between actions and chart',
      );
    });

    testWidgets('allocation percentages add up to 100', (tester) async {
      await tester.pumpWidget(
        app(
          const AllocationBar(
            slices: [
              AllocationSlice(label: 'XMR', color: Colors.orange, value: 1),
              AllocationSlice(label: 'BTC', color: Colors.amber, value: 1),
              AllocationSlice(label: 'ETH', color: Colors.blue, value: 1),
            ],
          ),
        ),
      );
      final percents = [
        for (final t in tester.widgetList<Text>(find.textContaining('%')))
          int.parse(t.data!.replaceAll('%', '')),
      ];
      expect(percents.fold<int>(0, (a, b) => a + b), 100);
    });

    testWidgets('a tiny share shows as 1% and the total stays 100', (tester) async {
      await tester.pumpWidget(
        app(
          const AllocationBar(
            slices: [
              AllocationSlice(label: 'BTC', color: Colors.amber, value: 996),
              AllocationSlice(label: 'DAI', color: Colors.yellow, value: 4),
            ],
          ),
        ),
      );
      expect(find.text('99%'), findsOneWidget);
      expect(find.text('1%'), findsOneWidget);
    });

    testWidgets('only open checklist steps are tappable', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        app(
          SecurityChecklistCard(
            title: 'Secure your wallet',
            progressLabel: (d, t) => '$d of $t',
            items: [
              ChecklistItem(label: 'Done', done: true, onTap: () => tapped.add('done')),
              ChecklistItem(label: 'Open', done: false, onTap: () => tapped.add('open')),
            ],
          ),
        ),
      );
      expect(find.text('1 of 2'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.tap(find.text('Open'));
      expect(tapped, ['open']);
    });
  });

  group('SecurityChecklist', () {
    late MemoryPreferenceStore prefs;

    setUp(() {
      prefs = MemoryPreferenceStore();
      SharedPreferencesService.store = prefs;
      WalletSecrets.store = MemorySecretStore();
    });

    tearDown(() {
      SharedPreferencesService.resetForTesting();
      WalletSecrets.resetForTesting();
    });

    const labels = SecurityChecklistLabels(
      title: 'Secure your wallet',
      progress: _progress,
      verifySeed: 'seed',
      autoBackup: 'backup',
      tor: 'tor',
      privateLookups: 'lookups',
      securityKeys: 'keys',
    );

    test('reads each step, and leaves out the ones that do not apply', () async {
      final checklist = SecurityChecklist(
        autoBackupOn: () async => null,
        securityKeysOn: () async => false,
        clock: () => _now,
      );
      addTearDown(checklist.dispose);
      await checklist.refresh();

      expect(checklist.steps, {
        SecurityStep.verifySeed: false,
        SecurityStep.tor: true,
        SecurityStep.privateLookups: true,
        SecurityStep.securityKeys: false,
      });
      expect(checklist.allDone, isFalse);
    });

    test('a lookup over clearnet, or an expired seed check, opens a step again', () async {
      final checklist = SecurityChecklist(
        autoBackupOn: () async => true,
        securityKeysOn: () async => true,
        clock: () => _now,
      );
      addTearDown(checklist.dispose);
      await SeedCheckStore.markVerified(_now);
      await checklist.refresh();
      expect(checklist.allDone, isTrue);
      expect(
        securityChecklistCard(checklist: checklist, labels: labels, onStep: (_) async {}),
        isNull,
        reason: 'the card hides once everything is done',
      );

      await SharedPreferencesService.set<String>(
        SettingsKeys.fiatApiMode,
        FiatApiMode.clearnet.name,
      );
      await checklist.refresh();
      expect(checklist.steps![SecurityStep.privateLookups], isFalse);

      await SharedPreferencesService.set<String>(
        SettingsKeys.fiatApiMode,
        FiatApiMode.disabled.name,
      );
      await SharedPreferencesService.set<String>(SettingsKeys.openAliasMode, 'clearnet');
      await checklist.refresh();
      expect(checklist.steps![SecurityStep.privateLookups], isFalse);

      final later = SecurityChecklist(
        autoBackupOn: () async => true,
        securityKeysOn: () async => true,
        clock: () => _now.add(const Duration(days: 200)),
      );
      addTearDown(later.dispose);
      await later.refresh();
      expect(later.steps![SecurityStep.verifySeed], isFalse);
    });

    test('a step that cannot be read is left out, not shown undone', () async {
      final checklist = SecurityChecklist(
        autoBackupOn: () async => throw StateError('no service'),
        securityKeysOn: () async => false,
        clock: () => _now,
      );
      addTearDown(checklist.dispose);
      await checklist.refresh();
      expect(checklist.steps!.containsKey(SecurityStep.autoBackup), isFalse);
    });

    test('a wallet with no words to ask for has no seed step', () async {
      final checklist = SecurityChecklist(
        autoBackupOn: () async => true,
        securityKeysOn: () async => true,
        canVerifySeed: () async => false,
        clock: () => _now,
      );
      addTearDown(checklist.dispose);
      await checklist.refresh();
      expect(checklist.steps!.containsKey(SecurityStep.verifySeed), isFalse);
      expect(checklist.allDone, isTrue);
    });

    test('settings that cannot be read leave the card as it was', () async {
      SharedPreferencesService.store = _BrokenPreferences();
      final checklist = SecurityChecklist(
        autoBackupOn: () async => true,
        securityKeysOn: () async => true,
        clock: () => _now,
      );
      addTearDown(checklist.dispose);
      await checklist.refresh();
      expect(checklist.steps, isNull);
    });

    test('notifies only when something changed', () async {
      final checklist = SecurityChecklist(
        autoBackupOn: () async => false,
        securityKeysOn: () async => false,
        clock: () => _now,
      );
      addTearDown(checklist.dispose);
      var notified = 0;
      checklist.addListener(() => notified++);
      await checklist.refresh();
      await checklist.refresh();
      expect(notified, 1);
    });
  });
}

String _progress(int done, int total) => '$done of $total';

class _BrokenPreferences extends PreferenceStore {
  @override
  Future<Object?> read(String key) async => throw StateError('unreadable');
  @override
  Future<void> write(String key, Object value) async => throw StateError('unwritable');
  @override
  Future<void> remove(String key) async {}
}
