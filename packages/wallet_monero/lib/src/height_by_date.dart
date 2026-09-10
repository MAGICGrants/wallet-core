/// Maps a calendar date to an approximate Monero block height.
///
/// Table and interpolation from Cake Wallet
/// (cw_core/lib/get_height_by_date.dart). Lives in `wallet_monero`, not the
/// domain layer: these are *Monero* heights. Every coin answers this question
/// differently, so `CryptoWallet` asks its subclass rather than calling a
/// shared free function the way the apps do.
///
/// Only ever an estimate. A restore height that is slightly too low costs scan
/// time; one that is too high silently misses transactions, so the result is
/// biased low and never extrapolated above the table's last known height for
/// dates inside the table.
library;

const _monthlyHeights = <String, int>{
  "2014-4": 0,
  "2014-5": 18844,
  "2014-6": 65406,
  "2014-7": 108882,
  "2014-8": 153594,
  "2014-9": 198072,
  "2014-10": 241088,
  "2014-11": 285305,
  "2014-12": 328069,
  "2015-1": 372369,
  "2015-2": 416505,
  "2015-3": 456631,
  "2015-4": 501084,
  "2015-5": 543973,
  "2015-6": 588326,
  "2015-7": 631187,
  "2015-8": 675484,
  "2015-9": 719725,
  "2015-10": 762463,
  "2015-11": 806528,
  "2015-12": 849041,
  "2016-1": 892866,
  "2016-2": 936736,
  "2016-3": 977691,
  "2016-4": 1015848,
  "2016-5": 1037417,
  "2016-6": 1059651,
  "2016-7": 1081269,
  "2016-8": 1103630,
  "2016-9": 1125983,
  "2016-10": 1147617,
  "2016-11": 1169779,
  "2016-12": 1191402,
  "2017-1": 1213861,
  "2017-2": 1236197,
  "2017-3": 1256358,
  "2017-4": 1278622,
  "2017-5": 1300239,
  "2017-6": 1322564,
  "2017-7": 1344225,
  "2017-8": 1366664,
  "2017-9": 1389113,
  "2017-10": 1410738,
  "2017-11": 1433039,
  "2017-12": 1454639,
  "2018-1": 1477201,
  "2018-2": 1499599,
  "2018-3": 1519796,
  "2018-4": 1542067,
  "2018-5": 1562861,
  "2018-6": 1585135,
  "2018-7": 1606715,
  "2018-8": 1629017,
  "2018-9": 1651347,
  "2018-10": 1673031,
  "2018-11": 1695128,
  "2018-12": 1716687,
  "2019-1": 1738923,
  "2019-2": 1761435,
  "2019-3": 1781681,
  "2019-4": 1803081,
  "2019-5": 1824671,
  "2019-6": 1847005,
  "2019-7": 1868590,
  "2019-8": 1890552,
  "2019-9": 1912212,
  "2019-10": 1932200,
  "2019-11": 1957040,
  "2019-12": 1978090,
  "2020-1": 2001290,
  "2020-2": 2022688,
  "2020-3": 2043987,
  "2020-4": 2066536,
  "2020-5": 2090797,
  "2020-6": 2111633,
  "2020-7": 2131433,
  "2020-8": 2153983,
  "2020-9": 2176466,
  "2020-10": 2198453,
  "2020-11": 2220000,
  "2020-12": 2242240,
  "2021-1": 2264584,
  "2021-2": 2286892,
  "2021-3": 2307079,
  "2021-4": 2329385,
  "2021-5": 2351004,
  "2021-6": 2373306,
  "2021-7": 2394882,
  "2021-8": 2417162,
  "2021-9": 2439490,
  "2021-10": 2461020,
  "2021-11": 2483377,
  "2021-12": 2504932,
  "2022-1": 2527316,
  "2022-2": 2549605,
  "2022-3": 2569711,
  "2022-4": 2591995,
  "2022-5": 2613603,
  "2022-6": 2635840,
  "2022-7": 2657395,
  "2022-8": 2679705,
  "2022-9": 2701991,
  "2022-10": 2723607,
  "2022-11": 2745899,
  "2022-12": 2767427,
  "2023-1": 2789763,
  "2023-2": 2811996,
  "2023-3": 2832118,
  "2023-4": 2854365,
  "2023-5": 2875972,
  "2023-6": 2898234,
  "2023-7": 2919771,
  "2023-8": 2942045,
  "2023-9": 2964280,
  "2023-10": 2985937,
  "2023-11": 3008178,
  "2023-12": 3029759,
  "2024-1": 3051991,
  "2024-2": 3074316,
  "2024-3": 3095123,
  "2024-4": 3117427,
  "2024-5": 3139022,
  "2024-6": 3161279,
  "2024-7": 3182945,
  "2024-8": 3205207,
  "2024-9": 3227566,
  "2024-10": 3249124,
  "2024-11": 3271454,
  "2024-12": 3293087,
  "2025-1": 3315383,
  "2025-2": 3337734,
  "2025-3": 3357843,
  "2025-4": 3380178,
  "2025-5": 3401714,
  "2025-6": 3424052,
  "2025-7": 3445678,
  "2025-8": 3467960,
  "2025-9": 3490175,
  "2025-10": 3511714,
  "2025-11": 3533988,
  "2025-12": 3555615,
};

/// Monero's genesis month. The table starts here, at height 0.
final _genesis = DateTime(2014, 4);

/// Approximate block height at [date]. Never negative.
///
/// Two corrections over the inherited implementation, both in the same
/// direction; a restore height that is too *low* only costs scan time, while
/// one that is too *high* skips the blocks holding the user's funds and
/// reports an empty wallet with no error at all.
///
///  - **Pre-genesis dates returned an arbitrary positive height.** A date
///    before April 2014 misses the table, falls into the extrapolation branch,
///    and gets projected backwards from the last known month: 2013-01-01
///    produced 264823, roughly November 2014. Now 0.
///  - **Early April 2014 returned a negative height.** The first entry is
///    height 0 and interpolating back one day's worth of blocks lands below
///    zero. Now clamped to 0.
///
/// Both are present in Skylight and Spice.
int getHeightByDate({required DateTime date}) {
  if (date.isBefore(_genesis)) return 0;

  final key = '${date.year}-${date.month}';
  final heights = _monthlyHeights.values.toList(growable: false);
  final keys = _monthlyHeights.keys.toList(growable: false);
  final lastHeight = heights.last;

  final int height;

  if (_monthlyHeights[key] == null || _monthlyHeights[key] == lastHeight) {
    // Outside the table: extrapolate from the final month's rate.
    final startHeight = heights[heights.length - 2];
    final endHeight = lastHeight;
    final heightPerDay = (endHeight - startHeight) / 31;

    final endDateRaw = keys.last.split('-');
    final endDate = DateTime(int.parse(endDateRaw[0]), int.parse(endDateRaw[1]));

    final differenceInDays = date.difference(endDate).inDays;
    height = endHeight + (differenceInDays * heightPerDay).round();
  } else {
    final startHeight = _monthlyHeights[key]!;
    final index = heights.indexOf(startHeight);
    final endHeight = heights[index + 1];
    final heightPerDay = ((endHeight - startHeight) / 31).round();
    height = startHeight + (date.day - 1) * heightPerDay - heightPerDay;
  }

  return height < 0 ? 0 : height;
}
