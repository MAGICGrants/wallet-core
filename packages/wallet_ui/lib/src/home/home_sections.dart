import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart';

import '../design/brand.dart';
import '../wallet/coin_mark.dart';
import '../wallet/format.dart';
import 'balance_chart_card.dart';
import 'balance_hero.dart';
import 'home_activity.dart';
import 'incoming_card.dart';

/// Translated strings for the home's incoming and chart cards.
class HomeLabels {
  final String incomingTitle;

  /// The title when more payments are on their way than the card lists:
  /// "Incoming (+2 Others)".
  final String Function(int others) incomingMore;

  /// "Unlocks in about {minutes} minutes · {done} of {needed}".
  final String Function(int minutes, int done, int needed) unlocksIn;

  /// "{done} of {needed} confirmations".
  final String Function(int done, int needed) confirmations;

  /// "Balance · 90 days".
  final String chartTitle;

  /// "Today", under the right end of the chart.
  final String chartToday;

  /// The several-coin chart's note: "Each coin's balance".
  final String chartEachCoin;

  /// A coin's change when it held nothing at the start: "New".
  final String chartNew;

  /// In place of the chart before the first transaction.
  final String chartEmpty;

  const HomeLabels({
    required this.incomingTitle,
    required this.incomingMore,
    required this.unlocksIn,
    required this.confirmations,
    required this.chartTitle,
    required this.chartToday,
    required this.chartEachCoin,
    required this.chartNew,
    required this.chartEmpty,
  });
}

/// One coin as the home sees it: its wallet, and the tokens on its chain whose
/// fees it pays (Dai on Ethereum). A token is a [HomeCoin] of its own too.
typedef HomeCoin = ({CryptoWallet wallet, List<CryptoWallet> tokens});

/// Builds the home's cards from the wallets, through a [HomeActivity] so a
/// rebuild costs nothing until a history or balance changes.
class HomeSections {
  /// The most incoming payments the card lists; the rest are counted in its
  /// title.
  static const incomingShown = 2;

  final HomeActivity activity;
  final HomeLabels labels;

  const HomeSections({required this.activity, required this.labels});

  /// Incoming payments not spendable yet across [coins], newest first, at
  /// most [incomingShown] of them; null when there are none, so the home
  /// leaves the card out.
  IncomingCard? incoming(List<HomeCoin> coins, {DateTime? now}) {
    final rows = <({int when, IncomingItem item})>[];
    for (final coin in coins) {
      final w = coin.wallet;
      for (final tx in activity.of(w, tokens: coin.tokens, now: now).pendingIncoming) {
        rows.add((when: tx.broadcastAt ?? tx.timestamp, item: _incomingItem(w, tx)));
      }
    }
    if (rows.isEmpty) return null;
    rows.sort((a, b) => b.when.compareTo(a.when));
    final others = rows.length - incomingShown;
    return IncomingCard(
      title: others > 0 ? labels.incomingMore(others) : labels.incomingTitle,
      items: [for (final r in rows.take(incomingShown)) r.item],
    );
  }

  IncomingItem _incomingItem(CryptoWallet w, TxDetails tx) {
    final needed = w.requiredConfirmations;
    final done = math.min(math.max(tx.height == -1 ? 0 : tx.confirmations, 0), needed);
    final blockTime = w.averageBlockTime;
    // "Unlocks" only where the funds are actually held back (Monero's ten
    // blocks); elsewhere a receipt counts toward the balance and only confirms.
    final locked =
        !w.canSpendPendingBalance &&
        (w.unlockedBalanceBaseUnits ?? BigInt.zero) < (w.totalBalanceBaseUnits ?? BigInt.zero);
    final String detail;
    if (locked && blockTime != null) {
      final seconds = (needed - done) * blockTime.inSeconds;
      detail = labels.unlocksIn(math.max(1, (seconds / 60).ceil()), done, needed);
    } else {
      detail = labels.confirmations(done, needed);
    }
    final amount = displayAmount(tx.amountBaseUnits, w.baseUnitDecimals);
    return IncomingItem(
      icon: CoinMark(coinSymbol: w.coinSymbol, iconAsset: w.iconAsset, size: 32),
      title: w.assetName,
      detail: detail,
      amount: '+${formatAmount(amount, math.min(w.decimals, 5))} ${w.coinSymbol}',
      progress: needed == 0 ? 1 : done / needed,
    );
  }

  /// The balance chart across [coins]: one line with its change in the title
  /// row for a single coin, a line and legend row per coin otherwise. Coins
  /// that held nothing across the whole window are left out.
  BalanceChartCard chart(List<HomeCoin> coins, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final series = <BalanceSeries>[];
    var anyHistory = false;
    for (final coin in coins) {
      final w = coin.wallet;
      final a = activity.of(w, tokens: coin.tokens, now: at);
      anyHistory |= a.hasHistory;
      final points = [
        for (final s in a.balanceSteps)
          (at: s.at, value: displayAmount(s.balance, w.baseUnitDecimals)),
      ];
      if (points.every((p) => p.value == 0)) continue;
      series.add(_series(w, points, single: coins.length == 1));
    }
    final start = at.subtract(Duration(days: activity.days));
    return BalanceChartCard(
      title: labels.chartTitle,
      note: series.length == 1
          ? series.first.change
          : (series.isEmpty ? null : labels.chartEachCoin),
      series: series,
      startLabel: DateFormat.MMMd().format(start),
      endLabel: labels.chartToday,
      emptyText: (!anyHistory || series.isEmpty) ? labels.chartEmpty : null,
    );
  }

  BalanceSeries _series(CryptoWallet w, List<ChartStep> points, {required bool single}) {
    final first = points.first.value;
    final last = points.last.value;
    final digits = math.min(w.decimals, 4);
    final String change;
    if (single) {
      // One coin: the change in coins, which needs no price.
      final diff = last - first;
      final sign = diff > 0 ? '+' : (diff < 0 ? '−' : '');
      change = '$sign${_trim(formatAmount(diff.abs(), digits))} ${w.coinSymbol}';
    } else if (first == 0) {
      change = labels.chartNew;
    } else {
      final pct = ((last - first) / first * 100).round();
      change = pct > 0 ? '+$pct%' : (pct < 0 ? '−${-pct}%' : '0%');
    }
    return BalanceSeries(
      label: '${formatAmount(last, digits)} ${w.coinSymbol}',
      color: CoinMark.colorOf(w.coinSymbol) ?? BrandColors.primary,
      points: points,
      change: change,
      up: last > first,
    );
  }

  /// Each chain's share of the fiat total (its tokens included), for Spice's
  /// allocation bar. Testnet coins are left out, as from the total.
  static List<AllocationSlice> allocation(
    List<HomeCoin> chains,
    double? Function(String coinSymbol) rateFor,
  ) {
    return [
      for (final c in chains)
        if (!c.wallet.isTestnet)
          AllocationSlice(
            label: c.wallet.coinSymbol,
            color: CoinMark.colorOf(c.wallet.coinSymbol) ?? BrandColors.primary,
            value: [c.wallet, ...c.tokens].fold<double>(
              0,
              (sum, w) => sum + (w.unlockedBalance ?? 0) * (rateFor(w.coinSymbol) ?? 0),
            ),
          ),
    ];
  }

  /// "5.1000" → "5.1", "2.0000" → "2".
  static String _trim(String s) =>
      s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}
