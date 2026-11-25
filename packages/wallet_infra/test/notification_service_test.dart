import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Without macOS settings the plugin threw an ArgumentError from initialize, so
  // the desktop app's incoming-payment notifications never showed on a Mac.
  test('on macOS, the first incoming-payment notification asks permission, then shows', () async {
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? true : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));

    await NotificationService().showIncomingTxNotification(
      title: 'Incoming transaction',
      body: 'You received 0.5 XMR',
    );

    expect(calls.map((c) => c.method), ['initialize', 'show']);
    final settings = (calls.first.arguments as Map).cast<String, Object?>();
    expect(settings['requestAlertPermission'], isTrue);
    expect(settings['requestSoundPermission'], isTrue);
    final shown = (calls.last.arguments as Map).cast<String, Object?>();
    expect(shown['body'], 'You received 0.5 XMR');
    expect((shown['platformSpecifics'] as Map)['threadIdentifier'], 'incoming_transactions');
  });
}
