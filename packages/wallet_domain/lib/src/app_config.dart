import 'package:wallet_infra/wallet_infra.dart';

import 'seed/seed_policy.dart';

/// Names the wallet file for a coin. Injected because the two apps already
/// shipped different schemes and neither should have to migrate users:
/// Skylight wrote `mywallet` (single coin), Spice writes `mywallet_xmr`.
typedef WalletFileNamer = String Function(String coinSymbol);

/// Namespaces a SharedPreferences key for a coin.
///
/// Also injected, and for a sharper reason than cosmetics: Skylight's shipped
/// keys are bare (`walletRestoreHeight`), Spice's are coin-prefixed
/// (`xmr_walletRestoreHeight`). Hardcoding either scheme in the core silently
/// orphans one app's persisted connection settings, subaddress support flags
/// and restore height on upgrade; the user lands on a wallet that thinks it
/// has never been configured.
typedef PrefKeyNamer = String Function(String coinSymbol, String key);

/// Everything the shared core needs to know about the app embedding it.
///
/// The rule this type exists to enforce: **no `if (isSkylight)` ever appears
/// below the app layer.** A behavioural difference is either a field here, an
/// overridable hook on `CryptoWallet`, or it does not belong in the core.
class WalletAppConfig {
  const WalletAppConfig({
    required this.appDirName,
    required this.windowsAppDataDir,
    required this.methodChannelPrefix,
    required this.walletFileNamer,
    required this.prefKeyNamer,
    required this.seedPolicy,
  });

  /// Unix/macOS application directory, e.g. `.skylight_wallet`.
  final String appDirName;

  /// Windows `%APPDATA%` subpath, e.g. `MAGIC Grants/Skylight Wallet`.
  final String windowsAppDataDir;

  /// Platform channel prefix, e.g. `org.magicgrants.skylight`.
  final String methodChannelPrefix;

  final WalletFileNamer walletFileNamer;
  final PrefKeyNamer prefKeyNamer;
  final SeedPolicy seedPolicy;

  /// Preserves Skylight's shipped on-disk and prefs layout exactly: one coin,
  /// so no suffix and no namespace.
  static WalletAppConfig get skylight => WalletAppConfig(
    appDirName: '.skylight_wallet',
    windowsAppDataDir: 'MAGIC Grants/Skylight Wallet',
    methodChannelPrefix: 'org.magicgrants.skylight',
    walletFileNamer: (_) => 'mywallet',
    prefKeyNamer: (_, key) => key,
    seedPolicy: SeedPolicy.skylight,
  );

  static WalletAppConfig get spice => WalletAppConfig(
    appDirName: '.spice_wallet',
    windowsAppDataDir: 'MAGIC Grants/Spice Wallet',
    methodChannelPrefix: 'org.magicgrants.spice',
    walletFileNamer: (coin) => 'mywallet_${coin.toLowerCase()}',
    prefKeyNamer: (coin, key) => '${coin.toLowerCase()}_$key',
    seedPolicy: SeedPolicy.spice,
  );

  static WalletAppConfig? _instance;

  static WalletAppConfig get instance {
    final config = _instance;
    if (config == null) {
      throw StateError('WalletAppConfig.install() must be called before using wallet_domain.');
    }
    return config;
  }

  /// Call once, from the app's `main()`, before any wallet is constructed.
  ///
  /// Also forwards the directory naming into `wallet_infra`'s [WalletPaths].
  /// That layer sits below this one and cannot import it, but an app should
  /// still configure one object, not two.
  ///
  /// [directories] overrides the `path_provider` boundary; tests pass a
  /// [FixedDirectories] pointing at a temp dir.
  static void install(WalletAppConfig config, {DirectoryProvider? directories}) {
    _instance = config;
    WalletPaths.install(
      linuxDirName: config.appDirName,
      windowsAppDataDir: config.windowsAppDataDir,
      directories: directories,
    );
  }

  /// Test-only: reset between cases so a leaked config can't cross-contaminate.
  static void resetForTesting() {
    _instance = null;
    WalletPaths.resetForTesting();
  }
}
