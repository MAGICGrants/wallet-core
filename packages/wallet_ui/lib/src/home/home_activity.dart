import 'package:wallet_domain/wallet_domain.dart';

/// The balance from [at] on, until the next step: [at] is the position across
/// the chart's window, 0 at its start and 1 now.
typedef BalanceStep = ({double at, BigInt balance});

/// What the home screen shows about one coin, worked out from its history.
class CoinActivity {
  /// Incoming payments not spendable yet, newest first.
  final List<TxDetails> pendingIncoming;

  /// The balance in base units across the window, oldest first: what it was
  /// when the window opens, then what it became at each transaction since.
  /// The last step is the balance now.
  final List<BalanceStep> balanceSteps;

  /// Whether the coin has any transactions at all.
  final bool hasHistory;

  const CoinActivity({
    required this.pendingIncoming,
    required this.balanceSteps,
    required this.hasHistory,
  });
}

/// Works out each coin's [CoinActivity] and remembers it.
///
/// Reading a wallet's history copies the whole list, and the home rebuilds on
/// every wallet notification (each sync tick). So the result is kept per
/// wallet and recomputed only when the history, the balance or the day
/// changes. Nothing is persisted or logged: the history stays in memory, where
/// the wallet already holds it.
class HomeActivity {
  /// How far back the balance chart reaches.
  final int days;

  HomeActivity({this.days = 90});

  /// The one the app's screens share, so the home and a chain's page read each
  /// history once between them.
  static final shared = HomeActivity();

  final _cache = Expando<_Cached>('HomeActivity');

  /// [tokens] are the wallets whose fees [wallet] pays (an ERC-20 transfer's
  /// gas comes out of the chain's Ether), so the walk back can count them.
  CoinActivity of(CryptoWallet wallet, {List<CryptoWallet> tokens = const [], DateTime? now}) {
    final at = now ?? DateTime.now();
    final day = at.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
    final revision = [wallet.txHistoryRevision, for (final t in tokens) t.txHistoryRevision];
    final balance = wallet.totalBalanceBaseUnits ?? BigInt.zero;
    final hit = _cache[wallet];
    if (hit != null && hit.matches(revision, balance, day)) return hit.activity;
    final activity = compute(
      wallet,
      wallet.txHistory,
      balance,
      at,
      feesPaidFor: [
        for (final t in tokens)
          if (t.feeIsForeign && t.feeCoinSymbol == wallet.coinSymbol)
            for (final tx in t.txHistory)
              if (tx.direction == txDirectionOutgoing) tx,
      ],
      days: days,
    );
    _cache[wallet] = _Cached(revision, balance, day, activity);
    return activity;
  }

  /// The coin, among [wallets], that last sent or received anything; null
  /// when none has history.
  static CryptoWallet? mostRecent(Iterable<CryptoWallet> wallets) {
    CryptoWallet? best;
    var bestTime = -1;
    for (final w in wallets) {
      final t = lastActivity(w);
      if (t != null && t > bestTime) {
        best = w;
        bestTime = t;
      }
    }
    return best;
  }

  /// Unix seconds of [wallet]'s newest transaction, or null with none.
  static int? lastActivity(CryptoWallet wallet) {
    final tx = wallet.newestTx;
    return tx == null ? null : _when(tx);
  }

  /// The pure computation behind [of], exposed for tests.
  static CoinActivity compute(
    CryptoWallet wallet,
    List<TxDetails> history,
    BigInt balanceNow,
    DateTime now, {
    List<TxDetails> feesPaidFor = const [],
    int days = 90,
  }) {
    final pending = <TxDetails>[];
    for (final tx in history) {
      if (tx.direction == txDirectionIncoming &&
          tx.status != TxStatus.failed &&
          !wallet.isTxConfirmed(tx)) {
        pending.add(tx);
      }
    }
    pending.sort((a, b) => _when(b).compareTo(_when(a)));

    // Walk back from the balance now: before a transaction, the balance was
    // what it is after it minus what it changed.
    // A token transfer the chain coin's own history already lists (an
    // explorer reports the contract call, gas included) is counted there only.
    final own = {for (final tx in history) tx.hash};
    final changes = [
      for (final tx in history) (when: _when(tx), delta: _delta(wallet, tx)),
      for (final tx in feesPaidFor)
        if (!own.contains(tx.hash)) (when: _when(tx), delta: -tx.feeBaseUnits),
    ]..sort((a, b) => b.when.compareTo(a.when));
    final span = days * Duration.secondsPerDay;
    final start = now.millisecondsSinceEpoch ~/ 1000 - span;
    // Fees the history does not carry (a token transfer's gas, say) can make
    // the walk overshoot; a balance below zero is never real.
    BigInt floor(BigInt b) => b < BigInt.zero ? BigInt.zero : b;
    // Built newest first. A step sits at its transaction's own time, so the
    // line moves only where the balance did.
    final steps = <BalanceStep>[];
    var balance = balanceNow;
    var i = 0;
    while (i < changes.length && changes[i].when > start) {
      // What happened in the same second is one step.
      final when = changes[i].when;
      var net = BigInt.zero;
      while (i < changes.length && changes[i].when == when) {
        net += changes[i].delta;
        i++;
      }
      if (net == BigInt.zero) continue;
      // A block time a little ahead of this device's clock still lands at
      // now, never past it.
      final at = ((when - start) / span).clamp(0.0, 1.0);
      steps.add((at: at, balance: floor(balance)));
      balance -= net;
    }
    steps.add((at: 0.0, balance: floor(balance)));

    return CoinActivity(
      pendingIncoming: pending,
      balanceSteps: steps.reversed.toList(growable: false),
      hasHistory: history.isNotEmpty,
    );
  }

  static int _when(TxDetails tx) {
    final b = tx.broadcastAt;
    return b != null && b > tx.timestamp ? b : tx.timestamp;
  }

  /// What [tx] did to this coin's balance.
  static BigInt _delta(CryptoWallet wallet, TxDetails tx) {
    if (tx.direction == txDirectionIncoming) {
      return tx.status == TxStatus.failed ? BigInt.zero : tx.amountBaseUnits;
    }
    // A token transfer's fee is paid in the chain coin, not in the token.
    final fee = wallet.feeIsForeign ? BigInt.zero : tx.feeBaseUnits;
    // A reverted send moved nothing but still paid its fee.
    if (tx.status == TxStatus.failed) return -fee;
    return -(tx.amountBaseUnits + fee);
  }
}

class _Cached {
  final List<int> revision;
  final BigInt balance;
  final int day;
  final CoinActivity activity;

  _Cached(this.revision, this.balance, this.day, this.activity);

  bool matches(List<int> rev, BigInt bal, int d) {
    if (bal != balance || d != day || rev.length != revision.length) return false;
    for (var i = 0; i < rev.length; i++) {
      if (rev[i] != revision[i]) return false;
    }
    return true;
  }
}
