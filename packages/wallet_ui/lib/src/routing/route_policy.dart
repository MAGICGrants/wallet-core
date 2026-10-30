import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show LogLevel, log;

/// Who may open a route.
enum RouteAccess {
  /// Before any unlock: onboarding, the lock screens themselves, legal pages.
  public,

  /// Only once the user is past every lock (wallet_domain's `AppSession`).
  unlocked,
}

/// Every route an app has, and who may open it. Deny by default: a route with
/// no entry is refused, and so is an [RouteAccess.unlocked] one while the app
/// is locked.
///
/// An app checks it in `onGenerateRoute` (returning a [RefusedRoute]) and
/// tests that the table names every route it defines ([check]), so a new
/// screen cannot be added without saying who may open it.
class RoutePolicy {
  const RoutePolicy(this.access);

  final Map<String, RouteAccess> access;

  bool allows(String? name, {required bool unlocked}) => switch (access[name]) {
    RouteAccess.public => true,
    RouteAccess.unlocked => unlocked,
    null => false,
  };

  bool requiresUnlock(String? name) => access[name] == RouteAccess.unlocked;

  /// Route names with no entry, and entries with no route. Both must be empty.
  ({Set<String> unlisted, Set<String> stale}) check(Iterable<String> routes) {
    final names = routes.toSet();
    final listed = access.keys.toSet();
    return (unlisted: names.difference(listed), stale: listed.difference(names));
  }
}

/// What `onGenerateRoute` returns for a route [RoutePolicy] refuses: a
/// transparent route that removes itself after its first frame, so the screen
/// underneath stays and nothing new is shown. As the only route (nothing
/// beneath it) it stays, blank: failing closed.
class RefusedRoute<T> extends PageRouteBuilder<T> {
  RefusedRoute(RouteSettings settings, {bool listed = true})
    : super(
        settings: settings,
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const _RemoveSelf(),
      ) {
    // Only names the app lists: an unlisted one may have come from outside.
    log(LogLevel.warn, '[Routes] Refused ${listed ? settings.name : 'an unlisted route'}');
  }
}

class _RemoveSelf extends StatefulWidget {
  const _RemoveSelf();

  @override
  State<_RemoveSelf> createState() => _RemoveSelfState();
}

class _RemoveSelfState extends State<_RemoveSelf> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive || route.isFirst) return;
      Navigator.of(context).removeRoute(route);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Consumes every route the platform pushes (a deep link, an Android intent's
/// data or `route` extra) and drops it, so `WidgetsApp` never turns one into a
/// screen. Register it before the app's `MaterialApp` is built: observers are
/// asked in the order they were added, and the first that handles the push
/// ends it.
///
/// Payment links do not come this way: they arrive over `PaymentLinkChannel`
/// and wait in a `PaymentLinkGate`.
class RouteLinkBlocker with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    log(LogLevel.info, '[Routes] Dropped a route pushed from outside the app');
    return true;
  }
}
