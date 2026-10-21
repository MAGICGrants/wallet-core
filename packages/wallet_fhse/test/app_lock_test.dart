import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// App Lock is always on. Its one setting is how long the app may be away
/// first: in the background on a phone, without use on a computer. The time is
/// kept on two clocks, as for "Fully lock after", so setting the date back
/// does not skip it.

class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  bool wallet = true;
  int relocks = 0;

  /// When set, the wallet check waits for it: one still under way.
  Completer<void>? walletGate;

  /// When set, a relock waits for it: one still under way.
  Completer<void>? relockGate;

  @override
  Future<bool> hasAnyExistingWallet() async {
    await walletGate?.future;
    return wallet;
  }

  final locks = <String>[];

  @override
  Future<void> lockSpend() async => locks.add('lockSpend');

  @override
  Future<void> fullyLock() async => locks.add('fullyLock');

  @override
  Future<bool> armAppLockRelock() async {
    if (!wallet) return false;
    await relockGate?.future;
    relocks++;
    AppSession.lock();
    return true;
  }
}

void main() {
  late DateTime wall;
  late int boot;
  late _Manager manager;
  const second = 1000000000; // ns

  setUp(() {
    wall = DateTime(2026, 10, 16, 12);
    boot = 1000 * second;
    SecurityKeyFullLock.wallClock = () => wall;
    SecurityKeyFullLock.bootClock = () => boot;
    SharedPreferencesService.store = MemoryPreferenceStore();
    manager = _Manager();
    SecurityKeysUi.install(
      SecurityKeysUiConfig(
        appName: 'Test Wallet',
        walletManagerOf: (_) => manager,
        homeRoute: '/home',
        logo: (_) => const SizedBox.shrink(),
      ),
    );
    AppSession.resetForTesting();
  });

  tearDown(() {
    SecurityKeyFullLock.wallClock = DateTime.now;
    SecurityKeyFullLock.bootClock = lockClockNanos;
    SharedPreferencesService.resetForTesting();
    SecurityKeysUi.resetForTesting();
    AppSession.resetForTesting();
  });

  void pass(Duration d) {
    wall = wall.add(d);
    boot += d.inMicroseconds * 1000;
  }

  /// A context that outlives the timer, like the app root's.
  Future<BuildContext> rootContext(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox.shrink();
        },
      ),
    );
    return context;
  }

  group('AppLockPreferences', () {
    test('10 minutes unless set; only the listed choices count', () async {
      expect(await AppLockPreferences.minutes(), 10);
      await AppLockPreferences.setMinutes(0);
      expect(await AppLockPreferences.minutes(), 0);
      await SharedPreferencesService.set<int>(AppLockPreferences.lockAfterMinutes, 5000);
      expect(await AppLockPreferences.minutes(), 10, reason: 'a value no picker offers');
      expect(() => AppLockPreferences.setMinutes(5000), throwsArgumentError);
    });

    test('a computer locks after a minute without use for "Immediately"', () async {
      await AppLockPreferences.setMinutes(0);
      expect(await AppLockPreferences.desktopIdleLimit(), const Duration(minutes: 1));
      await AppLockPreferences.setMinutes(60);
      expect(await AppLockPreferences.desktopIdleLimit(), const Duration(hours: 1));
    });

    test('the old App Lock switch is ignored: off still means on', () async {
      await SharedPreferencesService.set<bool>(DomainPreferenceKeys.legacyAppLockEnabled, false);
      expect(await AppLockPreferences.minutes(), AppLockPreferences.defaultMinutes);
    });
  });

  group('AppLockTimer (a phone in the background)', () {
    testWidgets('back within the time: no lock, the password kept', (tester) async {
      final context = await rootContext(tester);
      AppSession.markUnlocked();
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      pass(const Duration(minutes: 9));
      await tester.pump(const Duration(minutes: 9));
      expect(lock.takeDueOnReturn(), isFalse);
      expect(manager.relocks, 0);
      expect(AppSession.isUnlocked, isTrue);
    });

    testWidgets('the timer drops the password on time, and the return shows App Lock', (
      tester,
    ) async {
      final context = await rootContext(tester);
      AppSession.markUnlocked();
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      pass(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      expect(manager.relocks, 1);
      expect(AppSession.isUnlocked, isFalse);
      expect(lock.takeDueOnReturn(), isTrue);
    });

    testWidgets('a timer that never ran (a suspended app): the return decides', (tester) async {
      final context = await rootContext(tester);
      AppSession.markUnlocked();
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      pass(const Duration(hours: 2)); // the clocks moved, the timer did not fire
      expect(lock.takeDueOnReturn(), isTrue);
      expect(AppSession.isUnlocked, isFalse, reason: 'locked before any link could land');
      expect(manager.relocks, 0, reason: 'the app locks next, after putting App Lock up');
      await tester.pump(const Duration(hours: 1));
      expect(manager.relocks, 0, reason: 'the cancelled timer does not fire later');

      await lock.lock(context);
      expect(manager.relocks, 1);
      await lock.lock(context);
      expect(manager.relocks, 1, reason: 'once per return');
    });

    testWidgets('the timer already locked: the return does not lock again', (tester) async {
      final context = await rootContext(tester);
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      pass(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      expect(manager.relocks, 1);

      // The user may already be unlocking: a second relock could undo it.
      expect(lock.takeDueOnReturn(), isTrue);
      await lock.lock(context);
      expect(manager.relocks, 1);
    });

    testWidgets('setting the date back does not skip it', (tester) async {
      final context = await rootContext(tester);
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      boot += 11 * 60 * second;
      wall = wall.subtract(const Duration(hours: 1));
      expect(lock.takeDueOnReturn(), isTrue);
    });

    testWidgets('"Immediately" locks as the app leaves', (tester) async {
      await AppLockPreferences.setMinutes(0);
      final context = await rootContext(tester);
      AppSession.markUnlocked();
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      expect(manager.relocks, 1);
      expect(lock.takeDueOnReturn(), isTrue);
    });

    testWidgets('no wallet yet: onboarding is never interrupted', (tester) async {
      manager.wallet = false;
      await AppLockPreferences.setMinutes(0);
      final context = await rootContext(tester);
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      pass(const Duration(hours: 2));
      expect(lock.takeDueOnReturn(), isFalse);
    });

    testWidgets('a return before the checks answer still counts the time away', (tester) async {
      final context = await rootContext(tester);
      AppSession.markUnlocked();
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      manager.walletGate = Completer<void>();
      final leaving = lock.onBackground(context);
      pass(const Duration(hours: 2)); // suspended before the check returned
      expect(lock.takeDueOnReturn(), isTrue);
      manager.walletGate!.complete();
      await leaving;
      await tester.pump(const Duration(hours: 1));
      expect(manager.relocks, 0, reason: 'the late check arms no timer');
    });

    testWidgets('each return starts afresh', (tester) async {
      final context = await rootContext(tester);
      final lock = AppLockTimer();
      addTearDown(lock.dispose);

      await lock.onBackground(context);
      pass(const Duration(minutes: 11));
      expect(lock.takeDueOnReturn(), isTrue);
      expect(lock.takeDueOnReturn(), isFalse);
    });
  });

  testWidgets('an unlock waits for a relock still under way, so it is not undone', (tester) async {
    final context = await rootContext(tester);
    manager.relockGate = Completer<void>();
    final relock = lockAppLock(context);

    var waited = false;
    unawaited(waitForFullLock().then((_) => waited = true));
    await tester.pump();
    expect(waited, isFalse);

    manager.relockGate!.complete();
    expect(await relock, isTrue);
    await tester.pump();
    expect(waited, isTrue);
  });

  // "Fully lock after" with security keys on: the spend wallet locks either
  // way; the wallets keep watching only while Continuous Sync keeps the app
  // running.
  group('the full lock', () {
    testWidgets('closes everything when nothing keeps the app running', (tester) async {
      final context = await rootContext(tester);
      await fullyLockWallet(context);
      expect(manager.locks, ['fullyLock']);
    });

    testWidgets('with Continuous Sync on, the wallets keep watching view-only', (tester) async {
      syncFrequencyPlatform = 'android';
      addTearDown(() => syncFrequencyPlatform = Platform.operatingSystem);
      await saveSyncFrequency(SyncFrequency.continuous);
      final context = await rootContext(tester);
      await fullyLockWallet(context);
      expect(manager.locks, ['lockSpend']);
    });
  });

  group('DesktopAutoLock.appLock (a computer without use)', () {
    test('covers the app after App Lock\'s time, not "Lock after"\'s', () async {
      await SharedPreferencesService.set<int>(SecurityKeysPreferences.fullLockAfterMinutes, 60);
      var covers = 0;
      final lock = DesktopAutoLock.appLock()..start(() async => covers++);
      addTearDown(lock.dispose);

      pass(const Duration(minutes: 9));
      await lock.check();
      expect(covers, 0);
      pass(const Duration(minutes: 1));
      await lock.check();
      expect(covers, 1);
    });

    test('"Immediately" is a minute without use', () async {
      await AppLockPreferences.setMinutes(0);
      var covers = 0;
      final lock = DesktopAutoLock.appLock()..start(() async => covers++);
      addTearDown(lock.dispose);

      pass(const Duration(seconds: 30));
      await lock.check();
      expect(covers, 0);
      pass(const Duration(seconds: 30));
      await lock.check();
      expect(covers, 1);
    });
  });

  group('AppLockTile', () {
    Future<List<String>> openTile(
      WidgetTester tester, {
      bool deviceHasLock = true,
      bool confirms = true,
    }) async {
      final asked = <String>[];
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: FhseLocalizations.localizationsDelegates,
          supportedLocales: FhseLocalizations.supportedLocales,
          home: Scaffold(
            body: AppLockTile(
              deviceHasLock: () async => deviceHasLock,
              confirmLater: (_) async {
                asked.add('confirm');
                return confirms;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return asked;
    }

    Future<void> pick(WidgetTester tester, String option) async {
      await tester.tap(find.text('App Lock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    testWidgets('shows 10 minutes by default; a shorter time needs nothing', (tester) async {
      final asked = await openTile(tester);
      expect(find.text('10 minutes'), findsOneWidget);

      await pick(tester, 'Immediately');
      expect(asked, isEmpty);
      expect(await AppLockPreferences.minutes(), 0);
      expect(find.text('Immediately'), findsOneWidget);
    });

    testWidgets('a longer time asks the owner first', (tester) async {
      final asked = await openTile(tester);
      await pick(tester, '1 hour');
      expect(asked, ['confirm']);
      expect(await AppLockPreferences.minutes(), 60);
    });

    testWidgets('a longer time the owner does not confirm is not saved', (tester) async {
      final asked = await openTile(tester, confirms: false);
      await pick(tester, '1 hour');
      expect(asked, ['confirm']);
      expect(await AppLockPreferences.minutes(), 10);
      expect(find.text('10 minutes'), findsOneWidget);
    });

    testWidgets('a device with no screen lock is told so', (tester) async {
      await openTile(tester, deviceHasLock: false);
      expect(find.textContaining('This device has no screen lock'), findsOneWidget);
    });

    testWidgets('a device with a lock shows no warning', (tester) async {
      await openTile(tester);
      expect(find.textContaining('no screen lock'), findsNothing);
    });
  });
}
