import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wallet_infra/wallet_infra.dart' show LogLevel, log;

/// The one thing a link from outside can do in these apps: pre-fill the Send
/// form for a payment link (`monero:`, and in Spice `bitcoin:` and
/// `ethereum:`), and only once the user is past every lock.
///
/// A link is held, never followed: [offer] keeps it if its scheme is one of
/// [schemes] and it is at most [maxLength] long, and drops anything else. One
/// is held at a time (the latest). It is handed to [open] only when [unlocked]
/// is true (wallet_domain's `AppSession`) and [canLand] says the screen showing
/// is one behind the locks, so the unlock flow's own navigation has finished.
/// [open] still parses it against the wallets and pushes the Send form, which
/// reviews and confirms the payment as always; a link never sends anything.
class PaymentLinkGate {
  PaymentLinkGate({
    required Set<String> schemes,
    required this.unlocked,
    required this.landing,
    required this.canLand,
    required this.open,
    this.ttl = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : schemes = {for (final s in schemes) s.toLowerCase()},
       _clock = clock ?? DateTime.now {
    unlocked.addListener(_tryRelease);
    landing.addListener(_tryRelease);
  }

  /// Longer than any payment link (address, amount, a short description).
  static const maxLength = 2048;

  final Set<String> schemes;
  final ValueListenable<bool> unlocked;

  /// Notifies when the screen showing changes, so [canLand] is asked again.
  final Listenable landing;
  final bool Function() canLand;
  final void Function(String link) open;

  /// A link that waited longer than this for the unlock is dropped.
  final Duration ttl;
  final DateTime Function() _clock;

  ({String link, DateTime at})? _pending;
  bool _scheduled = false;
  bool _disposed = false;

  @visibleForTesting
  String? get pending => _pending?.link;

  /// A link from the operating system.
  void offer(String raw) {
    if (_disposed) return;
    final link = raw.trim();
    final scheme = link.length > maxLength ? null : Uri.tryParse(link)?.scheme.toLowerCase();
    if (scheme == null || !schemes.contains(scheme)) {
      // Never the link itself: it may hold an address.
      log(LogLevel.info, '[PaymentLink] Dropped a link that is not a payment link');
      return;
    }
    _pending = (link: link, at: _clock());
    _tryRelease();
  }

  void _tryRelease() {
    if (_disposed || _scheduled || _pending == null) return;
    if (!unlocked.value || !canLand()) return;
    _scheduled = true;
    // After the frame, so whatever navigation brought the user here is done,
    // and checked again: a lock in between keeps the link held.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final held = _pending;
      if (_disposed || held == null || !unlocked.value || !canLand()) return;
      _pending = null;
      if (_clock().difference(held.at) > ttl) {
        log(LogLevel.info, '[PaymentLink] Dropped a payment link that waited too long');
        return;
      }
      open(held.link);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    unlocked.removeListener(_tryRelease);
    landing.removeListener(_tryRelease);
  }
}

/// Where payment links come from: each app's `MainActivity` (Android) and
/// `AppDelegate` (iOS) forward a link with one of the app's schemes here, and
/// nowhere else. Flutter's own deep linking is off in both, so no link can
/// push a route. Desktop registers no link schemes and has no native side.
abstract final class PaymentLinkChannel {
  static const name = 'org.magicgrants.wallet/payment_links';
  static const _channel = MethodChannel(name);

  /// Starts receiving: [onLink] gets the link the app was opened with, if any,
  /// then every link that arrives while it runs.
  static Future<void> listen(void Function(String link) onLink) async {
    _channel.setMethodCallHandler((call) async {
      final link = call.arguments;
      if (call.method == 'link' && link is String) onLink(link);
    });
    try {
      final initial = await _channel.invokeMethod<String>('takeInitialLink');
      if (initial != null) onLink(initial);
    } on MissingPluginException {
      // No native side on this platform (desktop).
    } on PlatformException catch (e) {
      log(LogLevel.warn, '[PaymentLink] Could not read the launch link: ${e.code}');
    }
  }
}
