import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging.dart';

/// Clipboard helper for secrets: seed phrases, private view keys.
///
/// - **Android**: flags the clip as sensitive (`EXTRA_IS_SENSITIVE`, so it is
///   excluded from the paste preview and from clipboard sync) and clears it
///   after [clearAfter] with an in-app timer, because Android has no per-clip
///   expiry API.
/// - **iOS**: writes with `localOnly` (no Handoff or Universal Clipboard) and
///   an `expirationDate`, so the OS clears it even if the app is gone.
///
/// The clipboard is the one place a seed legitimately leaves the app, which is
/// why it gets an expiry rather than a plain `Clipboard.setData`. Everything
/// else about handling these values is in `Redact`.
class SecureClipboard {
  /// Fixed, app-neutral channel name.
  ///
  /// This is meant to become its own plugin package with the native side
  /// attached. Until then the consuming app registers a handler for this exact
  /// name. It is deliberately not a per-app prefix, so there is one name to
  /// implement rather than one per app.
  static const channelName = 'org.magicgrants.wallet/secure_clipboard';

  static const _channel = MethodChannel(channelName);

  static Future<bool>? _systemConfirms;

  /// Whether the OS shows its own confirmation when something is copied.
  ///
  /// Android 13 (API 33) added a standard clipboard confirmation, and Google's
  /// copy/paste guidance is to drop the app's own so the user is not told the
  /// same thing twice. Everywhere else -- iOS, desktop, older Android -- the
  /// system says nothing and the app has to confirm it itself.
  ///
  /// Asked once and cached; the answer cannot change while the process lives.
  static Future<bool> get systemConfirmsCopy => _systemConfirms ??= _askSystemConfirmsCopy();

  /// Test seam: pin the answer without a platform channel.
  @visibleForTesting
  static set systemConfirmsCopyForTesting(bool? value) =>
      _systemConfirms = value == null ? null : Future.value(value);

  static Future<bool> _askSystemConfirmsCopy() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('systemConfirmsCopy') ?? false;
    } catch (e) {
      // An older host build without the method. Assume nothing is shown: a
      // duplicate confirmation is a far smaller failure than none at all.
      log(LogLevel.warn, 'secure clipboard capability probe failed: $e');
      return false;
    }
  }

  static Future<void> copy(String text, {Duration clearAfter = const Duration(seconds: 60)}) async {
    var nativeHandled = false;

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _channel.invokeMethod('copySensitive', {
          'text': text,
          'clearAfterSeconds': clearAfter.inSeconds,
        });
        nativeHandled = true;
      } catch (e) {
        // Never include `text` here.
        log(LogLevel.warn, 'secure clipboard channel failed: $e');
      }
    }

    if (!nativeHandled) {
      await Clipboard.setData(ClipboardData(text: text));
    }

    // iOS clears via the native expiration date; elsewhere run an in-app timer.
    if (!Platform.isIOS) {
      Future.delayed(clearAfter, () async {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        // Only clear if it is still ours; the user may have copied something
        // else in the meantime, and wiping that would be user-hostile.
        if (current?.text == text) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      });
    }
  }
}
