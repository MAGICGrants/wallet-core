import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging.dart';
import '../storage/preferences.dart';

/// Asks for a Google Play / App Store rating, with each store's own dialog.
///
/// A successful send makes the user eligible ([markEligible]); the request
/// itself waits for the next launch ([requestIfDue]). Asking on the spot would
/// have the store app reach Google or Apple -- outside Tor, under the user's
/// store account -- seconds after a transaction went out.
///
/// The dialog is the platform's own, untouched: no "enjoying the app?" screen in
/// front of it and never from a button, which both stores forbid. Neither store
/// tells the app whether it was shown or whether the user rated, so the only
/// rule here is "at most once every [cooldown]". Each store layers its own
/// quota on top and skips people who have already reviewed.
///
/// An install that did not come from Google Play never contacts it. The F-Droid
/// and GitHub APKs are built without Play's library at all, so [isAvailable] is
/// false there; the Play build asks the local package manager who installed it
/// before it touches Play, and reports unavailable for anything but the Play
/// Store. Where it is unavailable nothing is stored either, not even the fact
/// that a send happened.
///
/// Like [SecureClipboard], the native side lives in each app, under
/// [channelName].
class StoreReview {
  StoreReview._();

  /// Fixed, app-neutral channel name; each app registers a handler for it.
  static const channelName = 'org.magicgrants.wallet/store_review';

  static const _channel = MethodChannel(channelName);

  /// The least time between two requests.
  static const cooldown = Duration(days: 30);

  /// How long the home screen has to settle before the dialog may appear.
  static const _settle = Duration(seconds: 2);

  static Future<bool>? _available;
  static var _checkedThisLaunch = false;

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Whether this install can show a store review at all. Asked once and
  /// cached: neither the installer nor the build changes while the process
  /// lives.
  static Future<bool> get isAvailable => _available ??= _askAvailable();

  /// Test seam: pin [isAvailable] without a platform channel.
  @visibleForTesting
  static set availableForTesting(bool? value) =>
      _available = value == null ? null : Future.value(value);

  @visibleForTesting
  static void resetForTesting() {
    _available = null;
    _checkedThisLaunch = false;
    clock = DateTime.now;
  }

  static Future<bool> _askAvailable() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      // A host build without the handler: no store to ask.
      log(LogLevel.warn, 'store review availability check failed: $e');
      return false;
    }
  }

  /// A send went through: ask for a review on a later launch.
  static Future<void> markEligible() async {
    if (!await isAvailable) return;
    await SharedPreferencesService.set<bool>(SettingsKeys.storeReviewEligible, true);
  }

  /// Asks for a review if a send made the user eligible and the store has not
  /// been asked within [cooldown]. Call from the home screen: it acts once per
  /// launch, since that screen is rebuilt after every send and unlock and only
  /// the first of those in a process is the app being opened.
  ///
  /// Waits [settle] first, then asks only if [stillAppropriate] still holds --
  /// the dialog must not land on top of a send or receive the user has already
  /// started. If it does not, the user stays eligible for a later launch.
  static Future<void> requestIfDue({
    Duration settle = _settle,
    bool Function()? stillAppropriate,
  }) async {
    if (_checkedThisLaunch) return;
    _checkedThisLaunch = true;

    if (await SharedPreferencesService.get<bool>(SettingsKeys.storeReviewEligible) != true) {
      return;
    }
    if (!_cooledDown(
      await SharedPreferencesService.get<int>(SettingsKeys.storeReviewLastAskedDay),
    )) {
      return;
    }
    if (!await isAvailable) return;

    await Future<void>.delayed(settle);
    if (stillAppropriate != null && !stillAppropriate()) return;

    final bool asked;
    try {
      // True once the store has been asked, whatever it then showed.
      asked = await _channel.invokeMethod<bool>('requestReview') ?? false;
    } catch (e) {
      log(LogLevel.warn, 'store review request failed: $e');
      return;
    }
    if (!asked) return;

    await SharedPreferencesService.set<int>(
      SettingsKeys.storeReviewLastAskedDay,
      _today().millisecondsSinceEpoch,
    );
    await SharedPreferencesService.remove(SettingsKeys.storeReviewEligible);
  }

  /// Today as a UTC calendar day. Only the day is stored: the preference store
  /// is plaintext, and the exact moment is more than the cooldown needs.
  static DateTime _today() {
    final now = clock().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  static bool _cooledDown(int? lastAskedDay) {
    if (lastAskedDay == null) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(lastAskedDay, isUtc: true);
    final today = _today();
    // A day after today means the clock was wrong then, or is now. Either way
    // it says nothing about how long ago the store was asked.
    if (last.isAfter(today)) return true;
    return today.difference(last).inDays >= cooldown.inDays;
  }
}
