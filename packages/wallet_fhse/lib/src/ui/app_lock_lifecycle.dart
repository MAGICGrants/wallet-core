import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show AppSession;
import 'package:wallet_infra/wallet_infra.dart' show BiometricAuth, WalletSecrets;
import 'package:wallet_ui/wallet_ui.dart' show AppLockCover;

import 'security_keys_app.dart';

/// App Lock and the full locks, driven by the app's lifecycle: one copy for
/// every app, mixed into the app root's [State], which is also the app's
/// [WidgetsBindingObserver] (added before the `MaterialApp` builds, so
/// [didPopRoute] is asked before the `MaterialApp`'s own handler).
///
/// On a phone: App Lock's "Lock after" in the background ([AppLockTimer]) and,
/// with security keys on, "Fully lock after" ([SecurityKeyFullLock]). On a
/// desktop OS: "Lock after" a time without use ([DesktopAutoLock]), App Lock's
/// shorter time without use ([DesktopAutoLock.appLock]), and App Lock's
/// "Immediately" as the window is hidden.
///
/// The app supplies its navigator and the route on top of it
/// ([appLockNavigator], [appLockTopRouteName], [appLockTopRoute]), returns
/// [buildAppLock] from `MaterialApp.builder` with its App Lock screen as the
/// cover, and does its own work on the way to the background in
/// [onMobilePaused].
mixin AppLockLifecycle<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  /// Whether this runs a desktop OS's locks, "without use"
  /// ([isDesktopAutoLockPlatform]); replaced in tests.
  @visibleForTesting
  static bool desktopOS = isDesktopAutoLockPlatform;

  /// Whether this runs a phone's locks, in the background: Android and iOS,
  /// the iOS build on a Mac included. Replaced in tests.
  @visibleForTesting
  static bool mobile = Platform.isAndroid || Platform.isIOS;

  @visibleForTesting
  static void resetPlatformForTesting() {
    desktopOS = isDesktopAutoLockPlatform;
    mobile = Platform.isAndroid || Platform.isIOS;
  }

  /// The app's navigator: a lock screen replaces its stack.
  NavigatorState? get appLockNavigator;

  /// The name of the route on top of [appLockNavigator], from the app's
  /// navigator observer, so a relock does not stack a second [appLockRoute]
  /// on one that is already showing.
  String? get appLockTopRouteName;

  /// The route on top of [appLockNavigator] itself.
  Route<dynamic>? get appLockTopRoute;

  /// App Lock's screen as a named route: the way in at every launch, and
  /// after a full lock.
  String get appLockRoute => '/unlock';

  /// The security-key unlock screen ([SecurityKeyUnlockScreen]) as a named
  /// route.
  String get securityKeyUnlockRoute => '/security_key_unlock';

  /// On a phone, as the app reaches `paused`, once App Lock and "Fully lock
  /// after" have noted the time: the app's own work on the way out.
  void onMobilePaused() {}

  // Read once: which platform this is does not change while the app runs.
  late final bool _desktopOS = AppLockLifecycle.desktopOS;
  late final bool _mobile = AppLockLifecycle.mobile;

  // App Lock over the screens the user left (a relock): drawn above the
  // navigator ([AppLockCover]), so a screen finishing something under it
  // cannot pop it the way it could pop a route.
  final _cover = ValueNotifier<bool>(false);

  // App Lock (always on): its "Lock after" time in the background, on mobile.
  final _appLock = AppLockTimer();
  // Set when the app reaches `paused`, so the way back is noticed at its first
  // step (`hidden`), before a link that resumed it could land.
  bool _wasPaused = false;

  // "Fully lock after", with security keys on.
  final _fullLock = SecurityKeyFullLock();

  // "Lock after" a time without use, on a desktop OS: the full close.
  final _desktopLock = DesktopAutoLock();
  // App Lock's shorter time without use, on a desktop OS: covers the app.
  final _desktopAppLock = DesktopAutoLock.appLock();

  @override
  void initState() {
    super.initState();
    if (_desktopOS) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _desktopLock.start(_lockDesktop);
      _desktopAppLock.start(_coverDesktop);
    }
  }

  @override
  void dispose() {
    _cover.dispose();
    _appLock.dispose();
    _fullLock.dispose();
    _desktopLock.dispose();
    _desktopAppLock.dispose();
    if (_desktopOS) HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// What `MaterialApp.builder` returns around the navigator it is given
  /// ([child]): App Lock's [cover] above it ([AppLockCover]) while App Lock
  /// covers the app and, on a desktop OS, a [Listener] that counts pointer
  /// input anywhere as use for "Lock after".
  ///
  /// [cover] is the app's App Lock screen. It calls [hideAppLockCover] once
  /// the user is in, and [appLockCoverNeedsKey] when the wallet closed
  /// meanwhile and a key comes next.
  Widget buildAppLock({required WidgetBuilder cover, required Widget child}) {
    final app = AppLockCover(shown: _cover, cover: cover, child: child);
    if (!_desktopOS) return app;
    // Pointer input anywhere counts as use for "Lock after".
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointer,
      onPointerHover: _onPointer,
      onPointerMove: _onPointer,
      onPointerSignal: _onPointer,
      child: app,
    );
  }

  /// The system back button, while App Lock covers the app: swallowed. It
  /// would otherwise pop a screen out of sight under the cover. Asked before
  /// the MaterialApp's own handler, which registers after this one.
  @override
  Future<bool> didPopRoute() async => _cover.value || await super.didPopRoute();

  /// App Lock over the screens the user left.
  void _showCover() => _cover.value = true;

  /// From the cover: the user is in.
  void hideAppLockCover() => _cover.value = false;

  /// From the cover: the wallet closed meanwhile and a key comes next.
  void appLockCoverNeedsKey() => _replaceStack(securityKeyUnlockRoute);

  /// A lock screen replaces the stack. A cover that is up stays until that
  /// screen is fully in, so nothing it covered shows on the way.
  void _replaceStack(String lockRoute) {
    appLockNavigator?.pushNamedAndRemoveUntil(lockRoute, (route) => false);
    if (_cover.value) _hideCoverOnceIn(appLockTopRoute);
  }

  /// The cover goes once [top], the lock screen just pushed, is fully in.
  void _hideCoverOnceIn(Route<dynamic>? top) {
    if (!mounted || !_cover.value) return;
    // MaterialApp's hero controller holds a pushed page route offstage for its
    // first frame, and an offstage route's animation reads as complete: ask
    // again after that frame. The controller's own callback, added during the
    // push, puts the route back onstage first.
    if (top is ModalRoute && top.offstage) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _hideCoverOnceIn(top));
      return;
    }
    final animation = top is ModalRoute ? top.animation : null;
    if (animation == null || animation.isCompleted) return hideAppLockCover();
    void settled(AnimationStatus status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(settled);
      hideAppLockCover();
    }

    animation.addStatusListener(settled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_desktopOS) {
      _onDesktopLifecycle(state);
      return;
    }
    if (!_mobile) return;

    if (state == AppLifecycleState.paused) {
      _wasPaused = true;
      // App Lock has to cover backgrounding, not just a cold start: once its
      // time is up the password goes and the way back shows the lock. Not
      // while it is showing: the device's own prompt can background the app.
      if (appLockTopRouteName != appLockRoute && !_cover.value) {
        unawaited(_appLock.onBackground(context));
      }
      unawaited(_fullLock.onBackground(context));
      onMobilePaused();
    } else if (_wasPaused) {
      // The first step back (`hidden`, then `inactive`, then `resumed`):
      // before a payment link that brought the app back gets a frame to land.
      _wasPaused = false;
      _onReturn();
    }
  }

  void _onReturn() {
    // Both decided at once, before anything is awaited; App Lock's locks the
    // session ([AppSession]) as it decides.
    final appLockDue = _appLock.takeDueOnReturn();
    // Past "Fully lock after" (or locked by its timer while away): the lock
    // screens replace the stack *before* the wallets close, which takes a
    // while, so the screen being left is never usable with the password still
    // in memory. App Lock comes first when its time is up too.
    if (_fullLock.takeDueOnResume()) {
      // App Lock first when it was showing too (its cover, or its screen):
      // the way in still starts with the device's own check.
      final appLockShowing = _cover.value || appLockTopRouteName == appLockRoute;
      _replaceStack(appLockDue || appLockShowing ? appLockRoute : securityKeyUnlockRoute);
      unawaited(_fullLock.lock(context));
      return;
    }

    if (appLockDue) {
      // Over the current stack rather than replacing it, so unlocking returns
      // straight to the screen the user left; not again over a lock screen.
      if (appLockTopRouteName != appLockRoute) _showCover();
      unawaited(_appLock.lock(context));
    }
  }

  /// A desktop OS. App Lock covers the app after its time without use, or as
  /// the window is hidden for "Immediately" (macOS reports `hidden` when no
  /// window is visible: hidden, minimised, covered, or the screen locked).
  /// Both "without use" clocks are checked as the app comes back, since their
  /// timers can stall while the computer sleeps.
  void _onDesktopLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) {
      unawaited(_coverDesktopIfImmediate());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_onDesktopResumed());
    }
  }

  Future<void> _coverDesktopIfImmediate() async {
    if (await AppLockPreferences.minutes() == 0) await _coverDesktop();
  }

  Future<void> _onDesktopResumed() async {
    // The full close first: it may replace the stack with the unlock screen,
    // and then there is nothing left to cover.
    await _desktopLock.check();
    await _desktopAppLock.check();
  }

  /// App Lock on a desktop OS: the unlock screen goes over whatever is open,
  /// and the wallets stay open and syncing behind it. Linux and Windows ask
  /// for the password again; macOS asks for Touch ID or the Mac's password,
  /// and drops the keychain password meanwhile ([lockAppLock]).
  Future<void> _coverDesktop() async {
    // Already at a lock screen, or onboarding with no wallet yet.
    if (!mounted || !AppSession.isUnlocked) return;
    // A Mac with no way to confirm its owner has nothing to ask. (Where the
    // keystore holds the wallet password, App Lock is the device's own prompt;
    // Linux and Windows type the password instead.)
    if (WalletSecrets.holdsWalletPassword && !await BiometricAuth.isAvailable()) return;
    if (!mounted || !AppSession.isUnlocked) return;
    AppSession.lock();
    if (appLockTopRouteName != appLockRoute) _showCover();
    await lockAppLock(context);
  }

  /// "Lock after" ran out on a desktop OS. The unlock screen replaces the stack
  /// first, then the wallets close and the password is forgotten.
  Future<void> _lockDesktop() async {
    if (!mounted || !await desktopAutoLockApplies(context)) return;
    if (!mounted) return;
    // App Lock first (the typed password on Linux and Windows); a key follows
    // when keys are on.
    _replaceStack(appLockRoute);
    await _desktopLock.lock(context);
  }

  // Use, for both "without use" clocks: any key or pointer input reaching the
  // app.
  bool _onKey(KeyEvent event) {
    _recordUse();
    return false;
  }

  void _onPointer(PointerEvent event) => _recordUse();

  void _recordUse() {
    _desktopLock.recordUse();
    _desktopAppLock.recordUse();
  }
}
