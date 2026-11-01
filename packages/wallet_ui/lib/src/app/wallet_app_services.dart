import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show WalletManager;
import 'package:wallet_fiat/wallet_fiat.dart' show FiatRateModel;
import 'package:wallet_infra/wallet_infra.dart' show TorSettingsService;

/// The services a wallet app runs beside its screens, for its root State
/// (after [WidgetsBindingObserver], which the app registers):
///
/// * at launch ([startWalletServices]): the built-in Tor when it is the chosen
///   mode (before onboarding, nothing is chosen yet), fiat rates, and on a
///   desktop OS the incoming-transaction announcements, since there is no
///   background isolate there;
/// * back in front: a fiat fetch that failed is retried at once;
/// * leaving for the background on a phone ([markIncomingTxsSeen]): what was on
///   screen counts as seen, so a background isolate does not announce it again.
mixin WalletAppServices<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  /// The app's own wallet manager and fiat model (from its providers).
  WalletManager get appWalletManager;
  FiatRateModel get appFiatRates;

  bool _servicesStarted = false;
  WalletManager? _announcing;
  int _announcedTxCount = 0;

  /// Starts the services, once. With no wallet yet, fiat waits for onboarding
  /// to start it.
  void startWalletServices({required bool walletExists}) {
    if (_servicesStarted) return;
    _servicesStarted = true;
    unawaited(TorSettingsService.sharedInstance.startBuiltInIfChosen(walletExists: walletExists));

    // Attached once so the model knows which coins to price; every
    // startService() afterwards needs no manager.
    final fiat = appFiatRates..attachWalletManager(appWalletManager);
    if (walletExists) unawaited(fiat.startService());

    // From launch, wallet or not, so one made later is announced for too. The
    // first check seeds from the current time, so a restore's history is not.
    if (_desktopOS) _announcing = appWalletManager..addListener(_announceOnGrowth);
  }

  /// Records the transactions on screen as seen, announcing nothing, so one the
  /// user watched arrive is not announced again. For a phone's `paused`.
  void markIncomingTxsSeen() {
    unawaited(appWalletManager.notifyNewIncomingTxsAll(announce: false));
  }

  // The count is a cheap gate, so unrelated changes (balance, connectivity) do
  // not reach the keystore; notifyNewIncomingTxsAll decides (hash-based, and it
  // respects the notifications toggle).
  void _announceOnGrowth() {
    final manager = _announcing;
    if (manager == null) return;
    final count = manager.allWallets.fold<int>(0, (sum, w) => sum + w.txHistory.length);
    if (count <= _announcedTxCount) return;
    _announcedTxCount = count;
    unawaited(manager.notifyNewIncomingTxsAll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Back in front, perhaps on another network (a VPN where Tor is blocked):
    // a rate that failed is fetched now, not on its backoff or the next poll.
    if (state == AppLifecycleState.resumed && _servicesStarted) appFiatRates.retryIfFailed();
  }

  @override
  void dispose() {
    _announcing?.removeListener(_announceOnGrowth);
    super.dispose();
  }
}

// No background isolate announces incoming transactions here. The iOS build on
// a Mac is not one of these: it keeps iOS's background sync.
final bool _desktopOS = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
