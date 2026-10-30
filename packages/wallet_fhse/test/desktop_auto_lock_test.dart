import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart' show AppSession;
import 'package:wallet_fhse/src/ui/security_keys_app.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// "Lock after" on a desktop OS: the time without use, on two clocks, either
/// one deciding. Use is input while the app is unlocked.
void main() {
  late DateTime wall;
  late int boot;
  const second = 1000000000; // ns

  setUp(() {
    wall = DateTime(2026, 10, 11, 12);
    boot = 1000 * second;
    SecurityKeyFullLock.wallClock = () => wall;
    SecurityKeyFullLock.bootClock = () => boot;
    SharedPreferencesService.store = MemoryPreferenceStore();
    AppSession.markUnlocked();
  });

  tearDown(() {
    SecurityKeyFullLock.wallClock = DateTime.now;
    SecurityKeyFullLock.bootClock = lockClockNanos;
    SharedPreferencesService.resetForTesting();
    AppSession.resetForTesting();
  });

  void pass(Duration d) {
    wall = wall.add(d);
    boot += d.inMicroseconds * 1000;
  }

  test('not due while used within the time', () {
    final lock = DesktopAutoLock();
    pass(const Duration(minutes: 29));
    expect(lock.isDue, isFalse);
  });

  test('due once the default 30 minutes pass without use', () {
    final lock = DesktopAutoLock();
    pass(const Duration(minutes: 30));
    expect(lock.isDue, isTrue);
  });

  test('use restarts the time', () {
    final lock = DesktopAutoLock();
    pass(const Duration(minutes: 20));
    lock.recordUse();
    pass(const Duration(minutes: 20));
    expect(lock.isDue, isFalse);
  });

  test('setting the date back does not skip it', () {
    final lock = DesktopAutoLock();
    boot += 31 * 60 * second;
    wall = wall.subtract(const Duration(hours: 2));
    expect(lock.isDue, isTrue);
  });

  test('check reads the setting and runs the lock once, then starts again', () async {
    await SharedPreferencesService.set<int>(SecurityKeysPreferences.fullLockAfterMinutes, 10);
    var locks = 0;
    final lock = DesktopAutoLock()..start(() async => locks++);
    addTearDown(lock.dispose);

    pass(const Duration(minutes: 9));
    await lock.check();
    expect(locks, 0);

    pass(const Duration(minutes: 1));
    await lock.check();
    expect(locks, 1);

    await lock.check();
    expect(locks, 1);
  });

  test('input while locked is not use', () {
    final lock = DesktopAutoLock();
    AppSession.lock();
    pass(const Duration(minutes: 20));
    lock.recordUse();
    pass(const Duration(minutes: 10));
    expect(lock.isDue, isTrue);
  });

  test('password guesses at App Lock\'s cover do not postpone it', () async {
    var locks = 0;
    final lock = DesktopAutoLock()..start(() async => locks++);
    addTearDown(lock.dispose);

    // The owner's last use was at the start; the cover is up from here, and
    // someone types at it every five minutes.
    AppSession.lock();
    for (var i = 0; i < 6; i++) {
      lock.recordUse();
      pass(const Duration(minutes: 5));
      await lock.check();
    }
    expect(locks, 1, reason: 'closed at 30 minutes, as without the guesses');
  });

  test('the first input after the time ran out locks instead of starting it again', () async {
    var locks = 0;
    final lock = DesktopAutoLock()..start(() async => locks++);
    addTearDown(lock.dispose);

    // A computer asleep for a night: no timer ran, and a pointer move reaches
    // the app before the next check.
    pass(const Duration(hours: 8));
    lock.recordUse();
    await pumpEventQueue();
    expect(locks, 1);
    expect(lock.isDue, isFalse, reason: 'the time starts again after the lock');
  });

  test('the same for App Lock\'s time without use', () async {
    var covers = 0;
    final lock = DesktopAutoLock.appLock()..start(() async => covers++);
    addTearDown(lock.dispose);

    pass(const Duration(hours: 8));
    lock.recordUse();
    await pumpEventQueue();
    expect(covers, 1);
  });

  test('an unlock starts the time again', () async {
    var locks = 0;
    final lock = DesktopAutoLock()..start(() async => locks++);
    addTearDown(lock.dispose);

    AppSession.lock();
    pass(const Duration(minutes: 29));
    AppSession.markUnlocked();
    pass(const Duration(minutes: 29));
    await lock.check();
    expect(locks, 0);
  });
}
