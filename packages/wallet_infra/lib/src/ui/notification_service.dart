import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;

/// Local (on-device) notifications, shared by every app on wallet-core.
///
/// The plumbing (init, permission prompt, the incoming-tx channel) is
/// identical across apps; only the desktop branding differs, so that is injected
/// via the static fields below (set once from `main()`). The notification text
/// is passed in by the caller, because it is localized and coin-specific.
class NotificationService {
  final notificationsPlugin = FlutterLocalNotificationsPlugin();

  /// Windows notification identity. Set once from the app's `main()`.
  static String windowsAppName = 'Wallet';
  static String windowsAppUserModelId = '';
  static String windowsGuid = '';

  /// Android status-bar small-icon drawable for the incoming-tx notification
  /// (e.g. `ic_stat_spice`, the same one the foreground-sync service uses). Set
  /// from the app's `main()`; null falls back to the launcher icon.
  static String? androidSmallIcon;

  // Per-isolate: the background task and the foreground service each get their
  // own engine, and the plugin has to be initialized in whichever one is about
  // to show something.
  static bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const initSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettingsIOS = DarwinInitializationSettings(
      // Permissions are requested manually via [promptPermission].
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettingsLinux = LinuxInitializationSettings(defaultActionName: 'Open wallet');

    // Windows requires an absolute path to an .ico file.
    final initSettingsWindows = WindowsInitializationSettings(
      appName: windowsAppName,
      appUserModelId: windowsAppUserModelId,
      guid: windowsGuid,
      iconPath: Platform.isWindows
          ? p.join(
              p.dirname(Platform.resolvedExecutable),
              'data',
              'flutter_assets',
              'assets',
              'app_icon.ico',
            )
          : null,
    );

    await notificationsPlugin.initialize(
      InitializationSettings(
        android: initSettingsAndroid,
        iOS: initSettingsIOS,
        linux: initSettingsLinux,
        windows: initSettingsWindows,
      ),
    );

    _initialized = true;
  }

  Future<bool> promptPermission() async {
    if (Platform.isIOS) {
      final iosPlugin = notificationsPlugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      final granted = await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    } else if (Platform.isAndroid) {
      // Android 13+ needs runtime permission.
      final androidPlugin = notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestNotificationsPermission();
      return granted ?? true; // Older Android versions don't need permission.
    }
    return true; // Other platforms (Linux, etc.)
  }

  /// [title]/[body] are supplied by the caller; they are localized and, for a
  /// multicoin app, coin-specific. Initializes first so it works from a
  /// background isolate that never ran [init] in `main()`.
  Future<void> showIncomingTxNotification({required String title, required String body}) async {
    await init();

    const notificationChannelId = 'incoming_transactions';
    await notificationsPlugin.show(
      0,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          notificationChannelId,
          'Transactions',
          importance: Importance.max,
          priority: Priority.high,
          icon: androidSmallIcon,
        ),
        iOS: const DarwinNotificationDetails(threadIdentifier: notificationChannelId),
      ),
    );
  }
}
