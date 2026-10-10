import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:wallet_ui/wallet_ui.dart';

void main() {
  setUpAll(() => Intl.defaultLocale = 'en_US');

  int at(int y, int m, int d, int h) => DateTime(y, m, d, h).millisecondsSinceEpoch ~/ 1000;

  group('withDayHeaders', () {
    test('inserts one uppercase header before each day, entries kept in order', () {
      final items = [at(2024, 11, 10, 15), at(2024, 11, 10, 9), at(2024, 11, 9, 20)];
      expect(withDayHeaders(items, (t) => t), [
        '10 NOVEMBER',
        items[0],
        items[1],
        '9 NOVEMBER',
        items[2],
      ]);
    });

    test('a single day yields exactly one header', () {
      final items = [at(2024, 1, 2, 23), at(2024, 1, 2, 1)];
      final rows = withDayHeaders(items, (t) => t);
      expect(rows.whereType<String>().toList(), ['2 JANUARY']);
      expect(rows.length, 3);
    });

    test('empty input yields no rows', () {
      expect(withDayHeaders(<int>[], (t) => t), isEmpty);
    });
  });
}
