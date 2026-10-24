import 'package:flutter/foundation.dart';

/// Whether the user is past every lock this install has: App Lock when it is
/// on, the typed password on Linux and Windows, and security keys when they
/// are engaged. One flag for the whole app, set by whoever completes the last
/// step and cleared by every lock.
///
/// It decides what can happen without the user: a payment link waits for it
/// before it may open the Send form, and the apps refuse every route that
/// needs it while it is false. It is not what protects the wallet files (the
/// password does that); it is what keeps screens and links behind the locks.
///
/// - **Locked** at launch, when an App Lock relock is armed, on a full lock
///   ("Fully lock after", the desktop "Lock after"), and when the wallet is
///   deleted.
/// - **Unlocked** only when the last required step finishes: the unlock screen
///   with no key to follow, a security key or the recovery phrase, launching
///   with no lock at all, or finishing onboarding.
///
/// Per isolate; background isolates never show a screen.
abstract final class AppSession {
  static final ValueNotifier<bool> _unlocked = ValueNotifier(false);

  static ValueListenable<bool> get unlocked => _unlocked;

  static bool get isUnlocked => _unlocked.value;

  static void markUnlocked() => _unlocked.value = true;

  static void lock() => _unlocked.value = false;

  @visibleForTesting
  static void resetForTesting() => _unlocked.value = false;
}
