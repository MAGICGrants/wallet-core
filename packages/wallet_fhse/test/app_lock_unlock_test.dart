import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/wallet_infra.dart' show BoundToAnotherPcException;

/// App Lock's unlock screen in both apps: what passing the device's prompt,
/// or typing the password, leads to. Decided once here; each app only shows
/// the outcome, so the two cannot drift apart again.

/// A wallet manager whose password, keystore and wallet files are scripted.
class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  /// Whether the password is in memory (the wallet open).
  bool open = false;

  /// Security keys hold the password.
  bool guarded = false;

  /// The keystore has a copy to put back.
  bool keystoreCopy = true;

  /// What the typed unlock throws, if anything.
  Object? unlockThrows;

  int typedUnlocks = 0;
  int reopens = 0;
  int cacheLoads = 0;

  @override
  bool get hasPassword => open;

  @override
  Future<bool> isPasswordGuarded() async => guarded;

  @override
  Future<bool> loadStoredPassword() async {
    if (guarded || !keystoreCopy) return false;
    open = true;
    return true;
  }

  @override
  bool get isSpendLocked => true;

  @override
  Future<void> unlockSpend() async => reopens++;

  @override
  Future<void> loadCachedDisplayState() async => cacheLoads++;

  @override
  Future<bool> checkTypedPassword(String password) async => password == 'right';

  @override
  Future<bool> unlockWithTypedPassword(String password) async {
    typedUnlocks++;
    final failure = unlockThrows;
    if (failure != null) throw failure;
    if (password != 'right') return false;
    // With security keys on, the password is right but a key holds the wallet's.
    if (!guarded) open = true;
    return true;
  }
}

const _localAuth = MethodChannel('plugins.flutter.io/local_auth');

void main() {
  late _Manager manager;

  setUp(() {
    manager = _Manager();
    AppSession.lock();
    SecurityKeysUi.install(
      SecurityKeysUiConfig(
        appName: 'Test Wallet',
        walletManagerOf: (_) => manager,
        homeRoute: '/home',
        logo: (_) => const SizedBox.shrink(),
      ),
    );
  });

  tearDown(() {
    SecurityKeysUi.resetForTesting();
    AppSession.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _localAuth,
      null,
    );
  });

  /// The device's prompt answers [authenticate] (an [Exception] is thrown).
  void device(Object? authenticate) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _localAuth,
      (call) async => switch (call.method) {
        'authenticate' => authenticate is Exception ? throw authenticate : authenticate,
        'isDeviceSupported' => true,
        _ => null,
      },
    );
  }

  Future<BuildContext> screen(WidgetTester tester) async {
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

  group('the device prompt (Android, iOS, macOS)', () {
    testWidgets('passed: the keystore password comes back and the wallet reopens', (tester) async {
      device(true);
      final outcome = await unlockAppLockWithDevice(await screen(tester), reason: 'Unlock');
      expect(outcome, AppLockUnlock.unlocked);
      expect(AppSession.isUnlocked, isTrue);
      expect(manager.reopens, 1);
    });

    testWidgets('declined: nothing happens, the button asks again', (tester) async {
      device(false);
      final outcome = await unlockAppLockWithDevice(await screen(tester), reason: 'Unlock');
      expect(outcome, AppLockUnlock.declined);
      expect(AppSession.isUnlocked, isFalse);
      expect(manager.open, isFalse);
    });

    testWidgets('a lockout fails, so the recovery phrase is offered', (tester) async {
      device(PlatformException(code: 'LockedOut'));
      final outcome = await unlockAppLockWithDevice(await screen(tester), reason: 'Unlock');
      expect(outcome, AppLockUnlock.failed);
      expect(AppSession.isUnlocked, isFalse);
    });

    testWidgets('passed, but no password in the keystore: fails, not stuck', (tester) async {
      device(true);
      manager.keystoreCopy = false;
      final outcome = await unlockAppLockWithDevice(await screen(tester), reason: 'Unlock');
      expect(outcome, AppLockUnlock.failed);
      expect(AppSession.isUnlocked, isFalse);
      expect(manager.reopens, 0);
    });

    testWidgets('with security keys on and the wallet closed, a key comes next', (tester) async {
      device(true);
      manager.guarded = true;
      final outcome = await unlockAppLockWithDevice(await screen(tester), reason: 'Unlock');
      expect(outcome, AppLockUnlock.needsKey);
      expect(AppSession.isUnlocked, isFalse);
    });
  });

  group('the typed password (Linux, Windows)', () {
    testWidgets('the wallet stayed open: only checked again, nothing reopens', (tester) async {
      manager.open = true;
      final context = await screen(tester);
      expect(await unlockAppLockWithPassword(context, 'wrong'), AppLockUnlock.wrongPassword);
      expect(AppSession.isUnlocked, isFalse);
      expect(await unlockAppLockWithPassword(context, 'right'), AppLockUnlock.unlocked);
      expect(AppSession.isUnlocked, isTrue);
      expect(manager.typedUnlocks, 0);
      expect(manager.reopens, 0);
    });

    testWidgets('a closed wallet opens: cached balances first, the rest behind', (tester) async {
      final context = await screen(tester);
      expect(await unlockAppLockWithPassword(context, 'wrong'), AppLockUnlock.wrongPassword);
      expect(manager.open, isFalse);
      expect(await unlockAppLockWithPassword(context, 'right'), AppLockUnlock.unlocked);
      expect(AppSession.isUnlocked, isTrue);
      expect(manager.cacheLoads, 1);
      expect(manager.reopens, 1);
    });

    testWidgets('with security keys on, a key comes next', (tester) async {
      manager.guarded = true;
      final outcome = await unlockAppLockWithPassword(await screen(tester), 'right');
      expect(outcome, AppLockUnlock.needsKey);
      expect(AppSession.isUnlocked, isFalse);
      expect(manager.reopens, 0);
    });

    testWidgets("files bound to another PC say so", (tester) async {
      manager.unlockThrows = const BoundToAnotherPcException();
      final outcome = await unlockAppLockWithPassword(await screen(tester), 'right');
      expect(outcome, AppLockUnlock.boundToAnotherPc);
    });

    testWidgets('any other failure is an outcome, never a throw', (tester) async {
      manager.unlockThrows = Exception('the wallet file could not be read');
      final outcome = await unlockAppLockWithPassword(await screen(tester), 'right');
      expect(outcome, AppLockUnlock.failed);
      expect(AppSession.isUnlocked, isFalse);
    });
  });
}
