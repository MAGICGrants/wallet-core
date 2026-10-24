import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_fhse/wallet_fhse.dart' show FhseVault;
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Open, behind a key whose check is still under way when the app comes back.
class _Manager extends WalletManager {
  _Manager(this.guarded) : super(coins: () => const []);

  final Future<bool> guarded;

  @override
  bool get hasPassword => true;

  @override
  Future<bool> isPasswordGuarded() => guarded;
}

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

  group('leaving with the checks still under way', () {
    late Directory tmp;
    late DateTime now;
    late int bootNs;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('full_lock');
      WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
      SharedPreferencesService.store = MemoryPreferenceStore();
      now = backgroundedAt;
      bootNs = 1000 * second;
      SecurityKeyFullLock.wallClock = () => now;
      SecurityKeyFullLock.bootClock = () => bootNs;
    });

    tearDown(() {
      SecurityKeyFullLock.wallClock = DateTime.now;
      SecurityKeyFullLock.bootClock = lockClockNanos;
      SecurityKeysUi.resetForTesting();
      SharedPreferencesService.resetForTesting();
      WalletAppConfig.resetForTesting();
      tmp.deleteSync(recursive: true);
    });

    /// Backgrounds [lock] with the guard check held open, comes back two hours
    /// later, and only then lets the check answer.
    Future<bool> returnBeforeTheChecks(WidgetTester tester, {required bool keysOn}) async {
      await tester.runAsync(() async {
        final blob = File('${(await getAppDir()).path}/wallet.fhse');
        if (keysOn) await blob.writeAsBytes([0]);
        await FhseVault.isEngaged();
      });
      final guarded = Completer<bool>();
      final manager = _Manager(guarded.future);
      SecurityKeysUi.install(
        SecurityKeysUiConfig(
          appName: 'Test Wallet',
          walletManagerOf: (_) => manager,
          homeRoute: '/home',
          logo: (_) => const SizedBox.shrink(),
        ),
      );
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      );

      final lock = SecurityKeyFullLock();
      final leaving = lock.onBackground(context);
      now = now.add(const Duration(hours: 2));
      bootNs += 2 * 3600 * second;
      final due = lock.takeDueOnResume();
      guarded.complete(keysOn);
      await leaving;
      lock.dispose();
      return due;
    }

    testWidgets('the time away still counts from leaving', (tester) async {
      expect(await returnBeforeTheChecks(tester, keysOn: true), isTrue);
    });

    testWidgets('with keys off, nothing is due', (tester) async {
      expect(await returnBeforeTheChecks(tester, keysOn: false), isFalse);
    });
  });
}
