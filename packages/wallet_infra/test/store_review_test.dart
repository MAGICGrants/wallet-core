import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// A send makes the user eligible; the next launch asks the store, at most once
/// every 30 days. Where there is no store to ask -- the F-Droid and GitHub
/// builds, any install Google Play did not make -- nothing is asked and nothing
/// is written.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(StoreReview.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;
  late Object? Function() reply;

  // Midday UTC; what is stored is just the calendar day.
  final now = DateTime.utc(2026, 9, 23, 12, 34, 56);
  DateTime day(int offset) => DateTime.utc(2026, 9, 23).add(Duration(days: offset));

  setUp(() {
    SharedPreferencesService.store = MemoryPreferenceStore();
    StoreReview.resetForTesting();
    StoreReview.clock = () => now;
    calls = [];
    reply = () => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final value = reply();
      if (value is PlatformException) throw value;
      return value;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    StoreReview.resetForTesting();
    SharedPreferencesService.resetForTesting();
  });

  Future<bool?> eligible() => SharedPreferencesService.get<bool>(SettingsKeys.storeReviewEligible);
  Future<int?> lastAsked() =>
      SharedPreferencesService.get<int>(SettingsKeys.storeReviewLastAskedDay);
  Future<void> askedOn(DateTime d) => SharedPreferencesService.set<int>(
    SettingsKeys.storeReviewLastAskedDay,
    d.millisecondsSinceEpoch,
  );
  Future<void> launch({bool Function()? stillAppropriate}) =>
      StoreReview.requestIfDue(settle: Duration.zero, stillAppropriate: stillAppropriate);

  group('markEligible', () {
    test('records eligibility where a store can be asked', () async {
      StoreReview.availableForTesting = true;
      await StoreReview.markEligible();
      expect(await eligible(), isTrue);
    });

    test('writes nothing where no store can be asked', () async {
      StoreReview.availableForTesting = false;
      await StoreReview.markEligible();
      expect(await eligible(), isNull, reason: 'not even that a send happened');
    });
  });

  group('requestIfDue', () {
    setUp(() => StoreReview.availableForTesting = true);

    test('not eligible: the store is not asked', () async {
      await launch();
      expect(calls, isEmpty);
    });

    test('eligible and never asked: asks once, records the day, clears eligibility', () async {
      await StoreReview.markEligible();
      await launch();

      expect(calls, ['requestReview']);
      expect(await lastAsked(), day(0).millisecondsSinceEpoch, reason: 'the day, not the moment');
      expect(await eligible(), isNull, reason: 'the next ask needs another send');
    });

    test('acts once per launch, however often the home screen is shown', () async {
      await launch();
      // A send during this session, then home again: still this launch.
      await StoreReview.markEligible();
      await launch();

      expect(calls, isEmpty);
      expect(await eligible(), isTrue, reason: 'asked on the next launch instead');
    });

    test('within 30 days of the last ask: not asked, and still eligible after', () async {
      await askedOn(day(-29));
      await StoreReview.markEligible();
      await launch();

      expect(calls, isEmpty);
      expect(await eligible(), isTrue);
    });

    test('30 days after the last ask: asked again', () async {
      await askedOn(day(-30));
      await StoreReview.markEligible();
      await launch();

      expect(calls, ['requestReview']);
      expect(await lastAsked(), day(0).millisecondsSinceEpoch);
    });

    test('a last ask dated in the future does not block forever', () async {
      await askedOn(day(400));
      await StoreReview.markEligible();
      await launch();

      expect(calls, ['requestReview']);
    });

    test('left eligible if the home screen was left before the dialog was due', () async {
      await StoreReview.markEligible();
      await launch(stillAppropriate: () => false);

      expect(calls, isEmpty);
      expect(await eligible(), isTrue);
      expect(await lastAsked(), isNull);
    });

    test('nothing recorded when the native side did not ask the store', () async {
      await StoreReview.markEligible();
      reply = () => false;
      await launch();

      expect(calls, ['requestReview']);
      expect(await lastAsked(), isNull);
      expect(await eligible(), isTrue);
    });

    test('a failing native call is caught, and nothing is recorded', () async {
      await StoreReview.markEligible();
      reply = () => PlatformException(code: 'boom');
      await launch();

      expect(await lastAsked(), isNull);
      expect(await eligible(), isTrue);
    });
  });

  test('unavailable: never asks, even with eligibility carried over', () async {
    // Written by an earlier build that could ask, say.
    await SharedPreferencesService.set<bool>(SettingsKeys.storeReviewEligible, true);
    StoreReview.availableForTesting = false;
    await launch();

    expect(calls, isEmpty);
  });

  test('availability off the desktop test host: no channel call, unavailable', () async {
    // flutter test runs on the host OS, which is neither Android nor iOS.
    expect(await StoreReview.isAvailable, isFalse);
    expect(calls, isEmpty);
  });
}
