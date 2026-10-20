import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// App Lock over the screens the user left, drawn above the app's navigator:
/// place it in `MaterialApp.builder`, around the navigator it is given.
///
/// Pushed as a route instead, App Lock sat on the same stack as those screens,
/// and one that finished something after the return (a send, a saved
/// connection, a key set up) and popped itself popped App Lock and showed what
/// was under it. Nothing in the navigator can reach this.
///
/// While [shown], the app under it takes no focus, pointer input or
/// semantics, and [cover] gets a navigator of its own for its sheets, dialogs
/// and toasts. It must not use the app's navigator: it tells the app it is
/// done, and the app hides it. The app also swallows the system back button
/// meanwhile (`WidgetsBindingObserver.didPopRoute`, registered before the
/// `MaterialApp`), which would otherwise pop a screen out of sight.
class AppLockCover extends StatelessWidget {
  const AppLockCover({super.key, required this.shown, required this.cover, required this.child});

  final ValueListenable<bool> shown;
  final WidgetBuilder cover;

  /// The app: the navigator `MaterialApp.builder` hands over, and whatever
  /// the app draws around it.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: shown,
      child: child,
      builder: (context, shown, app) => Stack(
        fit: StackFit.expand,
        children: [
          // The same widgets either way, so the app keeps its state.
          ExcludeFocus(
            excluding: shown,
            child: ExcludeSemantics(
              excluding: shown,
              child: IgnorePointer(ignoring: shown, child: app),
            ),
          ),
          if (shown)
            // The app's HeroController is its navigator's alone.
            HeroControllerScope.none(
              child: Navigator(
                onGenerateRoute: (settings) => PageRouteBuilder<void>(
                  settings: settings,
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (context, _, _) => cover(context),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
