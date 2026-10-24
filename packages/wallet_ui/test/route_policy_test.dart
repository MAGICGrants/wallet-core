import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

const _policy = RoutePolicy({
  '/welcome': RouteAccess.public,
  '/home': RouteAccess.unlocked,
  '/secret': RouteAccess.unlocked,
});

Route<dynamic> _generate(RouteSettings settings, {required bool unlocked}) {
  if (!_policy.allows(settings.name, unlocked: unlocked)) {
    return RefusedRoute(settings, listed: _policy.access.containsKey(settings.name));
  }
  return MaterialPageRoute(settings: settings, builder: (_) => Text('screen ${settings.name}'));
}

Widget _app({required bool unlocked, String initial = '/welcome'}) => MaterialApp(
  onGenerateRoute: (s) => _generate(s, unlocked: unlocked),
  onGenerateInitialRoutes: (_) => [_generate(RouteSettings(name: initial), unlocked: unlocked)],
);

/// What the engine sends when the platform pushes a route: an Android
/// intent's data, an iOS URL, a deep link.
Future<void> _platformPushes(WidgetTester tester, String location) async {
  final message = SystemChannels.navigation.codec.encodeMethodCall(
    MethodCall('pushRouteInformation', {'location': location, 'state': null}),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.navigation.name,
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  test('deny by default: unlisted routes never, unlocked ones only when unlocked', () {
    expect(_policy.allows('/welcome', unlocked: false), isTrue);
    expect(_policy.allows('/home', unlocked: false), isFalse);
    expect(_policy.allows('/home', unlocked: true), isTrue);
    expect(_policy.allows('/elsewhere', unlocked: true), isFalse);
    expect(_policy.allows(null, unlocked: true), isFalse);
    expect(_policy.requiresUnlock('/home'), isTrue);
    expect(_policy.requiresUnlock('/welcome'), isFalse);
    expect(_policy.requiresUnlock('/elsewhere'), isFalse);
  });

  test('check names routes with no entry and entries with no route', () {
    final c = _policy.check(['/welcome', '/home', '/new']);
    expect(c.unlisted, {'/new'});
    expect(c.stale, {'/secret'});
  });

  testWidgets('a refused route shows nothing and removes itself', (tester) async {
    await tester.pumpWidget(_app(unlocked: false));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.pushNamed('/secret');
    await tester.pumpAndSettle();
    expect(find.text('screen /secret'), findsNothing);
    expect(find.text('screen /welcome'), findsOneWidget);
    expect(navigator.canPop(), isFalse);

    navigator.pushNamed('/not-a-route');
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('a refused first route stays, blank: failing closed', (tester) async {
    await tester.pumpWidget(_app(unlocked: false, initial: '/home'));
    await tester.pumpAndSettle();
    expect(find.text('screen /home'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without the blocker, a pushed route does open a screen', (tester) async {
    // The control for the next test: this is the path a deep link takes.
    await tester.pumpWidget(_app(unlocked: true));
    await _platformPushes(tester, '/home');
    expect(find.text('screen /home'), findsOneWidget);
  });

  testWidgets('RouteLinkBlocker drops every pushed route, even unlocked', (tester) async {
    final blocker = RouteLinkBlocker();
    tester.binding.addObserver(blocker);
    addTearDown(() => tester.binding.removeObserver(blocker));
    await tester.pumpWidget(_app(unlocked: true));

    for (final location in ['/home', 'x:///secret', 'monero:4abc?tx_amount=1', '/welcome']) {
      await _platformPushes(tester, location);
    }
    expect(find.text('screen /home'), findsNothing);
    expect(find.text('screen /secret'), findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });
}
