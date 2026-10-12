import 'seed/seed.dart';

/// Holds the wallet password somewhere other than the device keystore.
///
/// On mobile the wallet password is minted at onboarding and kept in the
/// keystore, behind App Lock when that is on. An app that installs a guard on
/// [WalletManager.passwordGuard] changes two things:
///
/// - **Where a new wallet's password comes from.** [passwordForNewWallet]
///   supplies it instead of a random one; `wallet_fhse` derives it from the
///   seed, so the wallet's files can be opened again with the seed alone.
/// - **Where it lives once the guard is engaged.** While [isEngaged] is false
///   the password stays in the keystore exactly as before. Once it is true the
///   keystore holds no copy: nothing opens until the app unlocks the guard
///   (for `wallet_fhse`, a security key and its PIN) and hands the password to
///   [WalletManager.unlockWithGuardedPassword]. It then stays in memory until
///   [WalletManager.fullyLock].
///
/// On Linux and Windows the user types a password and nothing is kept in a
/// keystore. A guard still supplies a new wallet's password there, and the
/// typed one only unlocks it (`WalletPasswordStore`). Without a guard the
/// typed password is the wallet password, as it always was.
abstract class WalletPasswordGuard {
  const WalletPasswordGuard();

  /// The password for a wallet about to be created or restored from [seed].
  /// Called before any wallet file is written.
  Future<String> passwordForNewWallet(SeedSource seed);

  /// The wallet now exists, encrypted with [password]. Persist whatever the
  /// guard needs to engage later.
  Future<void> walletCreated(String password);

  /// True when the guard, not the keystore, holds the password.
  Future<bool> isEngaged();

  /// The wallet was deleted; forget everything kept for it.
  Future<void> walletDeleted();

  /// Linux and Windows, while engaged: whether [typed] is the password the
  /// guard was engaged under. The typed password unlocks the guard there
  /// (`wallet_fhse`: the FHSE file's outer password), so a wrong one is
  /// turned away before anything else is asked for. A guard that cannot tell
  /// refuses.
  Future<bool> acceptsTypedPassword(String typed) async => false;
}
