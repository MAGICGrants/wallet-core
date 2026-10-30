import 'dart:math';

/// This isolate, as the others in the process can name it.
///
/// Android can destroy the app's isolate (the user swipes the app away) while
/// the process lives on for Continuous Sync, and nothing in that isolate gets
/// to close its native wallets. Whoever takes the wallets next closes them
/// ([WalletManager.closeOrphanedWallets]), and needs to tell a dead isolate's
/// wallets from a live one's: the token says whose they are.
abstract final class WalletIsolate {
  /// Random per isolate, and the same for its whole life.
  static final String token = () {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }();
}
