import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

const _link =
    'monero:4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge?tx_amount=1.5';

/// The gate, with a lock flag, a "which screen is showing" flag and a clock
/// the test drives.
class _Harness {
  _Harness({Set<String> schemes = const {'monero'}}) {
    gate = PaymentLinkGate(
      schemes: schemes,
      unlocked: unlocked,
      landing: landing,
      canLand: () => landing.value,
      open: opened.add,
      clock: () => now,
    );
  }

  final unlocked = ValueNotifier(false);

  /// True when a screen behind the locks is showing.
  final landing = ValueNotifier(true);
  final opened = <String>[];
  DateTime now = DateTime.utc(2026, 10, 16, 12);
  late final PaymentLinkGate gate;
}

void main() {
  testWidgets('drops everything that is not a payment link of its schemes', (tester) async {
    final h = _Harness()..unlocked.value = true;
    for (final raw in [
      '',
      '/settings',
      'x:///advanced_security',
      'https://example.com/monero:4abc',
      'bitcoin:bc1qxyz',
      'monero:${'a' * 3000}',
    ]) {
      h.gate.offer(raw);
    }
    await tester.pump();
    expect(h.gate.pending, isNull);
    expect(h.opened, isEmpty);
  });

  testWidgets('holds a link until the user is past every lock', (tester) async {
    final h = _Harness();
    h.gate.offer(_link);
    await tester.pump();
    expect(h.opened, isEmpty);
    expect(h.gate.pending, _link);

    h.unlocked.value = true;
    await tester.pump();
    expect(h.opened, [_link]);
    expect(h.gate.pending, isNull);

    // Once: later lock changes do not open it again.
    h.unlocked.value = false;
    h.unlocked.value = true;
    await tester.pump();
    expect(h.opened, [_link]);
  });

  testWidgets('unlocked but on a lock or onboarding screen: waits for one behind them', (
    tester,
  ) async {
    final h = _Harness()
      ..unlocked.value = true
      ..landing.value = false;
    h.gate.offer(_link);
    await tester.pump();
    expect(h.opened, isEmpty);

    h.landing.value = true;
    await tester.pump();
    expect(h.opened, [_link]);
  });

  testWidgets('a lock between the decision and the frame keeps it held', (tester) async {
    final h = _Harness()..unlocked.value = true;
    h.gate.offer(_link);
    h.unlocked.value = false; // before the frame that would open it
    await tester.pump();
    expect(h.opened, isEmpty);
    expect(h.gate.pending, _link);

    h.unlocked.value = true;
    await tester.pump();
    expect(h.opened, [_link]);
  });

  testWidgets('one link at a time: the latest', (tester) async {
    final h = _Harness(schemes: {'monero', 'bitcoin'});
    h.gate.offer(_link);
    h.gate.offer('BITCOIN:bc1qxyz?amount=0.1');
    h.unlocked.value = true;
    await tester.pump();
    expect(h.opened, ['BITCOIN:bc1qxyz?amount=0.1']);
  });

  testWidgets('a link that waited too long is dropped', (tester) async {
    final h = _Harness();
    h.gate.offer(_link);
    h.now = h.now.add(const Duration(minutes: 11));
    h.unlocked.value = true;
    await tester.pump();
    expect(h.opened, isEmpty);
    expect(h.gate.pending, isNull);
  });

  testWidgets('after dispose nothing is held or opened', (tester) async {
    final h = _Harness();
    h.gate.offer(_link);
    h.gate.dispose();
    h.gate.offer(_link);
    h.unlocked.value = true;
    await tester.pump();
    expect(h.opened, isEmpty);
    expect(h.gate.pending, isNull);
  });

  group('PaymentLinkChannel', () {
    const channel = MethodChannel(PaymentLinkChannel.name);

    testWidgets('takes the launch link, then each one that arrives', (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'takeInitialLink' ? _link : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final got = <String>[];
      await PaymentLinkChannel.listen(got.add);
      expect(got, [_link]);

      await messenger.handlePlatformMessage(
        PaymentLinkChannel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('link', 'monero:4second')),
        (_) {},
      );
      expect(got, [_link, 'monero:4second']);
    });

    testWidgets('no native side (desktop): nothing arrives and nothing throws', (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => throw MissingPluginException());
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final got = <String>[];
      await PaymentLinkChannel.listen(got.add);
      expect(got, isEmpty);
    });
  });
}
