import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/src/ui/security_keys_app.dart' show fullLockDue;

/// "Fully lock after" must not be skippable by setting the phone's date back,
/// and must not depend on a timer that does not run while the phone sleeps.
void main() {
  final backgroundedAt = DateTime(2026, 10, 11, 12);
  const limit = Duration(minutes: 30);
  const second = 1000000000; // ns

  bool due({required Duration wall, int? bootThen = 0, int? bootNow}) => fullLockDue(
    limit: limit,
    backgroundedAt: backgroundedAt,
    now: backgroundedAt.add(wall),
    backgroundedBootNs: bootThen,
    nowBootNs: bootNow,
  );

  test('not due while both clocks are under the limit', () {
    expect(due(wall: const Duration(minutes: 29), bootNow: 29 * 60 * second), isFalse);
  });

  test('due once the wall clock passes the limit', () {
    expect(due(wall: limit, bootNow: second), isTrue);
  });

  test('due once the boot clock passes it, even with the date set back to just after leaving', () {
    expect(due(wall: const Duration(seconds: 5), bootNow: 31 * 60 * second), isTrue);
  });

  test('due when the wall clock went backwards', () {
    expect(due(wall: const Duration(hours: -1), bootNow: second), isTrue);
  });

  test('due when the boot clock cannot be read, now or then', () {
    expect(due(wall: const Duration(minutes: 1), bootNow: null), isTrue);
    expect(due(wall: const Duration(minutes: 1), bootThen: null, bootNow: 60 * second), isTrue);
  });

  test('due when the boot clock went backwards', () {
    expect(
      due(wall: const Duration(minutes: 1), bootThen: 100 * second, bootNow: 50 * second),
      isTrue,
    );
  });
}
