/// Background sync + incoming-tx notification orchestration shared by the apps.
///
/// Kept separate because it sits above `wallet_domain` (it drives a
/// `WalletManager`) and pulls in `workmanager` and `flutter_foreground_task`.
/// An app without background sync shouldn't have to compile those.
///
/// The isolate entry points, the WorkManager and foreground-service `@pragma`
/// callbacks; must stay in the app. A fresh background isolate has to reinstall
/// the app's wallet-core statics first, and this package can't reach the app's
/// bootstrap. Each entry bootstraps, then delegates to `BackgroundSync.install`,
/// `dispatchBackgroundTask` or `BackgroundSyncTaskHandler`.
library;

export 'package:flutter_foreground_task/flutter_foreground_task.dart' show NotificationIcon;

export 'src/background_sync.dart';
export 'src/foreground_sync_service.dart';
