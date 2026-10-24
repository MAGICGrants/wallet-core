import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The app root's App Lock and full locks ([AppLockLifecycle]): lifecycle
/// events and input in, App Lock's cover or a lock screen replacing the stack
/// out. The timing itself is AppLockTimer's, SecurityKeyFullLock's and
/// DesktopAutoLock's, tested on their own.

class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  /// The password is in memory.
  bool open = true;

  /// Security keys guard the password.
  bool keysOn = false;

  int relocks = 0;

  /// The route on top as each full lock began.
  final closes = <String?>[];
  String? Function() topRoute = () => null;

  @override
  bool get hasPassword => open;

  @override
  Future<bool> hasAnyExistingWallet() async => true;

  @override
  Future<bool> isPasswordGuarded() async => keysOn;

  @override
  Future<bool> armAppLockRelock() async {
    relocks++;
    AppSession.lock();
    return true;
  }

  @override
  Future<void> fullyLock() async {
    AppSession.lock();
    closes.add(topRoute());
    open = false;
  }
}

class _TopRoute extends NavigatorObserver {
  Route<dynamic>? top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => top = route;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => top = previousRoute;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => top = newRoute;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, top)) top = previousRoute;
  }
}

/// An app root as the apps have it: the binding observer, then a
/// MaterialApp whose builder returns [AppLockLifecycle.buildAppLock].
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver, AppLockLifecycle<_Root> {
  final navigatorKey = GlobalKey<NavigatorState>();
  final observer = _TopRoute();
  var pauses = 0;

  NavigatorState get navigator => navigatorKey.currentState!;

  @override
  NavigatorState? get appLockNavigator => navigatorKey.currentState;

  @override
  String? get appLockTopRouteName => observer.top?.settings.name;

  @override
  Route<dynamic>? get appLockTopRoute => observer.top;

  @override
  void onMobilePaused() => pauses++;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Route<void> _route(RouteSettings settings) => MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => Scaffold(body: Text('screen ${settings.name}')),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [observer],
    initialRoute: '/home',
    onGenerateInitialRoutes: (name) => [_route(RouteSettings(name: name))],
    onGenerateRoute: _route,
    builder: (context, child) => buildAppLock(
      cover: (_) => Material(
        child: Column(
          children: [
            const Text('App Lock cover'),
            TextButton(onPressed: hideAppLockCover, child: const Text('Unlocked')),
            TextButton(onPressed: appLockCoverNeedsKey, child: const Text('Key next')),
          ],
        ),
      ),
      child: child!,
    ),
  );
}

void main() {
  late DateTime wall;
  late int boot;
  late _Manager manager;
  const second = 1000000000; // ns

  setUp(() {
    wall = DateTime(2026, 10, 20, 12);
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
    AppSession.markUnlocked();
  });

  tearDown(() {
    AppLockLifecycle.resetPlatformForTesting();
    SecurityKeyFullLock.wallClock = DateTime.now;
    SecurityKeyFullLock.bootClock = lockClockNanos;
    SharedPreferencesService.resetForTesting();
    SecurityKeysUi.resetForTesting();
    WalletSecrets.resetForTesting();
    AppSession.resetForTesting();
  });

  void pass(Duration d) {
    wall = wall.add(d);
    boot += d.inMicroseconds * 1000;
  }

  /// The platform reports [state], as the engine does: the framework steps
  /// through every state in between.
  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.lifecycle.name,
      const StringCodec().encodeMessage(state.toString()),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  /// The app in front, on /home with /send pushed over it.
  Future<_RootState> mount(WidgetTester tester) async {
    await lifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpWidget(const _Root());
    final root = tester.state<_RootState>(find.byType(_Root));
    manager.topRoute = () => root.appLockTopRouteName;
    unawaited(root.navigator.pushNamed('/send'));
    await tester.pumpAndSettle();
    return root;
  }

  final cover = find.text('App Lock cover');

  group('on a phone', () {
    setUp(() {
      AppLockLifecycle.desktopOS = false;
      AppLockLifecycle.mobile = true;
    });

    /// Away for [away], with the clocks moved and no timer run (a suspended
    /// app), then back.
    Future<void> awayFor(WidgetTester tester, Duration away) async {
      await lifecycle(tester, AppLifecycleState.paused);
      pass(away);
      await lifecycle(tester, AppLifecycleState.resumed);
    }

    testWidgets('back within App Lock\'s time: nothing covers the app', (tester) async {
      final root = await mount(tester);
      await awayFor(tester, const Duration(minutes: 9));
      expect(cover, findsNothing);
      expect(root.appLockTopRouteName, '/send');
      expect(AppSession.isUnlocked, isTrue);
      expect(root.pauses, 1, reason: "the app's own work on the way out");
    });

    testWidgets('App Lock\'s time up: the cover goes over the screen left, which stays', (
      tester,
    ) async {
      final root = await mount(tester);
      await awayFor(tester, const Duration(minutes: 11));
      expect(cover, findsOneWidget);
      expect(AppSession.isUnlocked, isFalse);
      expect(manager.relocks, 1);
      expect(manager.closes, isEmpty);

      await tester.tap(find.text('Unlocked'));
      await tester.pump();
      expect(cover, findsNothing);
      expect(root.appLockTopRouteName, '/send');
      expect(find.text('screen /send'), findsOneWidget);
    });

    testWidgets('"Immediately" locks as the app leaves', (tester) async {
      await AppLockPreferences.setMinutes(0);
      await mount(tester);
      await lifecycle(tester, AppLifecycleState.paused);
      expect(manager.relocks, 1);
      await lifecycle(tester, AppLifecycleState.resumed);
      expect(cover, findsOneWidget);
    });

    testWidgets('leaving from App Lock\'s own screen does not lock it again', (tester) async {
      // The device's own prompt can send the app to the background.
      await AppLockPreferences.setMinutes(0);
      final root = await mount(tester);
      unawaited(root.navigator.pushNamedAndRemoveUntil('/unlock', (_) => false));
      await tester.pumpAndSettle();

      await awayFor(tester, const Duration(hours: 1));
      expect(manager.relocks, 0);
      expect(cover, findsNothing, reason: 'not again over a lock screen');
    });

    testWidgets('leaving while the cover is up does not start App Lock again', (tester) async {
      await mount(tester);
      await awayFor(tester, const Duration(minutes: 11));
      expect(manager.relocks, 1);

      await AppLockPreferences.setMinutes(0);
      await awayFor(tester, const Duration(minutes: 11));
      expect(manager.relocks, 1);
      expect(cover, findsOneWidget);
    });

    testWidgets('the back button is swallowed while the cover is up', (tester) async {
      final root = await mount(tester);
      await awayFor(tester, const Duration(minutes: 11));
      await systemBack(tester);
      expect(root.appLockTopRouteName, '/send', reason: 'nothing popped out of sight');

      await tester.tap(find.text('Unlocked'));
      await tester.pump();
      await systemBack(tester);
      expect(root.appLockTopRouteName, '/home');
    });

    testWidgets('a key next, from the cover: the key\'s screen replaces the stack', (tester) async {
      final root = await mount(tester);
      await awayFor(tester, const Duration(minutes: 11));
      await tester.tap(find.text('Key next'));
      await tester.pump();
      expect(root.appLockTopRouteName, '/security_key_unlock');

      await tester.pumpAndSettle();
      expect(cover, findsNothing);
      expect(root.navigator.canPop(), isFalse, reason: 'the stack was replaced');
      expect(find.text('screen /send'), findsNothing);
    });

    testWidgets('the cover stays until the lock screen is fully in', (tester) async {
      await mount(tester);
      await awayFor(tester, const Duration(minutes: 11));
      await tester.tap(find.text('Key next'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(cover, findsOneWidget, reason: 'the screens it covered must not show on the way');
      }
      await tester.pumpAndSettle();
      expect(cover, findsNothing);
    });

    group('"Fully lock after", with keys on', () {
      setUp(() async {
        manager.keysOn = true;
        await SharedPreferencesService.set<int>(SecurityKeysPreferences.fullLockAfterMinutes, 10);
      });

      testWidgets('the key\'s screen replaces the stack before the wallets close', (tester) async {
        await AppLockPreferences.setMinutes(60);
        final root = await mount(tester);
        await awayFor(tester, const Duration(minutes: 20));
        await tester.pumpAndSettle();
        expect(manager.closes, ['/security_key_unlock']);
        expect(root.navigator.canPop(), isFalse);
        expect(cover, findsNothing);
        expect(manager.relocks, 0);
      });

      testWidgets('App Lock\'s time up too: App Lock\'s screen comes first', (tester) async {
        await mount(tester);
        await awayFor(tester, const Duration(minutes: 20));
        await tester.pumpAndSettle();
        expect(manager.closes, ['/unlock']);
        expect(cover, findsNothing);
      });

      testWidgets('App Lock showing (its cover): App Lock\'s screen comes first', (tester) async {
        await SharedPreferencesService.set<int>(SecurityKeysPreferences.fullLockAfterMinutes, 30);
        final root = await mount(tester);
        await awayFor(tester, const Duration(minutes: 11));
        expect(cover, findsOneWidget);

        // Away again with the cover still up, past "Fully lock after".
        await awayFor(tester, const Duration(minutes: 31));
        expect(root.appLockTopRouteName, '/unlock');
        await tester.pumpAndSettle();
        expect(manager.closes, ['/unlock']);
        expect(cover, findsNothing);
      });
    });
  });

  group('on a desktop OS', () {
    setUp(() {
      AppLockLifecycle.desktopOS = true;
      AppLockLifecycle.mobile = false;
      // Linux and Windows: App Lock is the typed password, nothing to ask the
      // device first.
      WalletSecrets.holdsWalletPassword = false;
    });

    /// The window hidden, and shown again: the "without use" clocks are
    /// checked on the way back.
    Future<void> hideAndShow(WidgetTester tester) async {
      await lifecycle(tester, AppLifecycleState.hidden);
      await lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
    }

    testWidgets('"Immediately": hiding the window covers the app; the wallets stay open', (
      tester,
    ) async {
      await AppLockPreferences.setMinutes(0);
      final root = await mount(tester);
      await lifecycle(tester, AppLifecycleState.hidden);
      expect(AppSession.isUnlocked, isFalse);
      expect(manager.relocks, 1);
      expect(manager.closes, isEmpty);

      await lifecycle(tester, AppLifecycleState.paused);
      expect(root.pauses, 0, reason: "a phone's work on the way out");

      // No frames while hidden: the cover is drawn as the window comes back.
      await lifecycle(tester, AppLifecycleState.resumed);
      expect(cover, findsOneWidget);
      expect(root.appLockTopRouteName, '/send');
      expect(manager.relocks, 1);
    });

    testWidgets('otherwise hiding the window covers nothing', (tester) async {
      await mount(tester);
      await lifecycle(tester, AppLifecycleState.hidden);
      expect(cover, findsNothing);
      expect(manager.relocks, 0);
    });

    testWidgets('App Lock\'s time without use: the cover, the wallets still open', (tester) async {
      final root = await mount(tester);
      pass(const Duration(minutes: 11));
      await hideAndShow(tester);
      expect(cover, findsOneWidget);
      expect(manager.relocks, 1);
      expect(manager.closes, isEmpty);
      expect(root.appLockTopRouteName, '/send');
    });

    testWidgets('"Lock after" ran out: the unlock screen replaces the stack, then the close', (
      tester,
    ) async {
      final root = await mount(tester);
      pass(const Duration(minutes: 31));
      await hideAndShow(tester);
      await tester.pumpAndSettle();
      expect(manager.closes, ['/unlock']);
      expect(root.navigator.canPop(), isFalse);
      expect(cover, findsNothing, reason: 'nothing left to cover');
      expect(manager.relocks, 0);
    });

    testWidgets('input is use; input at the cover does not postpone "Lock after"', (tester) async {
      await mount(tester);
      pass(const Duration(minutes: 9));
      await tester.tapAt(const Offset(400, 500));
      pass(const Duration(minutes: 9));
      await hideAndShow(tester);
      expect(cover, findsNothing, reason: '9 minutes since the last use');

      pass(const Duration(minutes: 11));
      await hideAndShow(tester);
      expect(cover, findsOneWidget);

      // Someone types and clicks at the cover every five minutes; the last use
      // of the wallet was 20 minutes ago.
      for (var i = 0; i < 2; i++) {
        pass(const Duration(minutes: 5));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.tapAt(const Offset(400, 500));
      }
      expect(manager.closes, isEmpty);
      await hideAndShow(tester);
      await tester.pumpAndSettle();
      expect(manager.closes, ['/unlock'], reason: '30 minutes since the last use');
    });
  });

  testWidgets('elsewhere, nothing locks', (tester) async {
    AppLockLifecycle.desktopOS = false;
    AppLockLifecycle.mobile = false;
    await AppLockPreferences.setMinutes(0);
    final root = await mount(tester);
    await lifecycle(tester, AppLifecycleState.paused);
    pass(const Duration(hours: 1));
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(cover, findsNothing);
    expect(manager.relocks, 0);
    expect(root.pauses, 0);
  });
}
