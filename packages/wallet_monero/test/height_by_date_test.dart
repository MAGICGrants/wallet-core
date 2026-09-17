import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_monero/wallet_monero.dart';

void main() {
  group('bounds', () {
    test('never returns a negative height', () {
      // The first table entry is height 0; interpolating back one day's worth
      // of blocks from it used to land below zero.
      for (var day = 1; day <= 30; day++) {
        final h = getHeightByDate(date: DateTime(2014, 4, day));
        expect(h, greaterThanOrEqualTo(0), reason: '2014-04-$day');
      }
    });

    test('pre-genesis dates are 0, not an arbitrary positive height', () {
      // Regression: 2013-01-01 returned 264823, roughly November 2014. A
      // restore height that is too high silently skips the user's funds.
      for (final date in [
        DateTime(2013),
        DateTime(2013, 1, 1),
        DateTime(2010, 6, 15),
        // The pre-genesis months the restore sheet actually offers: it lists
        // every year back to 2014 and picks the first of the month, so these
        // three are selectable and the guard has to cover them. They used to
        // return heights from mid-2015, skipping a year of the user's history.
        DateTime(2014, 1),
        DateTime(2014, 2),
        DateTime(2014, 3),
        DateTime(2014, 3, 31),
        DateTime(1970),
      ]) {
        expect(getHeightByDate(date: date), 0, reason: '$date');
      }
    });

    test('the genesis month itself starts at 0', () {
      expect(getHeightByDate(date: DateTime(2014, 4)), 0);
      expect(getHeightByDate(date: DateTime(2014, 4, 1)), 0);
    });
  });

  group('monotonicity', () {
    test('height never decreases as the date advances', () {
      // The single property that matters: an earlier date must never map to a
      // later block, or a restore silently starts past the user's funds.
      var previous = -1;
      for (var year = 2014; year <= 2032; year++) {
        for (var month = 1; month <= 12; month++) {
          final h = getHeightByDate(date: DateTime(year, month, 1));
          expect(h, greaterThanOrEqualTo(previous), reason: '$year-$month');
          previous = h;
        }
      }
    });

    test('holds across days within a month too', () {
      var previous = -1;
      for (var day = 1; day <= 28; day++) {
        final h = getHeightByDate(date: DateTime(2020, 6, day));
        expect(h, greaterThanOrEqualTo(previous), reason: 'day $day');
        previous = h;
      }
    });
  });

  group('known points', () {
    test('table months land near their tabulated height', () {
      // Interpolation biases a mid-month date low by design; the first of the
      // month should be within one month's worth of blocks of the entry.
      expect(getHeightByDate(date: DateTime(2020, 6, 1)), closeTo(2117000, 25000));
      expect(getHeightByDate(date: DateTime(2025, 12, 1)), 3555615);
    });

    test('extrapolates forward past the end of the table', () {
      final end = getHeightByDate(date: DateTime(2025, 12, 1));
      final future = getHeightByDate(date: DateTime(2030));
      expect(future, greaterThan(end));
      // ~4 years at roughly 720 blocks/day.
      expect(future - end, closeTo(4 * 365 * 720, 400000));
    });
  });
}
