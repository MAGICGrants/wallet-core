import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Screenshot protection is a process-global flag with no reference count, so
/// the mixin has to keep one itself.
///
/// Flutter runs the incoming route's `initState` before the outgoing route's
/// `dispose`, so a naive on/off pair ends with protection *off* when one secret
/// screen replaces another — which is the seed-then-keys onboarding route the
/// protection exists for.
class _Protected extends StatefulWidget {
  const _Protected();
  @override
  State<_Protected> createState() => _ProtectedState();
}

class _ProtectedState extends State<_Protected> with SecureScreenMixin {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  setUp(SecureScreenMixin.resetForTesting);
  tearDown(SecureScreenMixin.resetForTesting);

  testWidgets('protection is held while any protected screen is mounted', (tester) async {
    expect(SecureScreenMixin.mountedProtectedScreens, 0);

    await tester.pumpWidget(const MaterialApp(home: _Protected()));
    expect(SecureScreenMixin.mountedProtectedScreens, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(SecureScreenMixin.mountedProtectedScreens, 0, reason: 'released on the last unmount');
  });

  testWidgets('one protected screen replacing another never drops to zero', (tester) async {
    // Both mounted at once, which is the overlap that used to turn protection
    // off: the count must not reach zero at any point here.
    await tester.pumpWidget(
      const MaterialApp(home: Column(children: [_Protected(), _Protected()])),
    );
    expect(SecureScreenMixin.mountedProtectedScreens, 2);

    await tester.pumpWidget(const MaterialApp(home: Column(children: [_Protected()])));
    expect(
      SecureScreenMixin.mountedProtectedScreens,
      1,
      reason: 'the surviving screen still holds protection',
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(SecureScreenMixin.mountedProtectedScreens, 0);
  });

  testWidgets('the count never goes negative', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Protected()));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(SecureScreenMixin.mountedProtectedScreens, 0);
  });

  group('plugin engagement by platform', () {
    const channel = MethodChannel('screen_protector');
    late List<String> calls;

    setUp(() {
      calls = <String>[];
      SecureScreenMixin.debugForceProtectablePlatform = true;
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
    });

    tearDown(() {
      SecureScreenMixin.debugForceProtectablePlatform = null;
      HostPlatform.iosAppOnMacForTesting = false;
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('arms the plugin on a supported mobile platform', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Protected()));
      await tester.pump();
      expect(SecureScreenMixin.mountedProtectedScreens, 1);
      expect(calls, containsAll(<String>['preventScreenshotOn', 'protectDataLeakageWithBlur']));
    });

    testWidgets('does not arm the plugin when the iOS build runs on a Mac', (tester) async {
      HostPlatform.iosAppOnMacForTesting = true;
      await tester.pumpWidget(const MaterialApp(home: _Protected()));
      await tester.pump();
      expect(SecureScreenMixin.mountedProtectedScreens, 1);
      expect(calls, isEmpty);
    });
  });
}
