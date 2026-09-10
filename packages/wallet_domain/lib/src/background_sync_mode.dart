/// What an unattended run of a wallet actually does.
///
/// "Background sync" names two structurally different things, and only one of
/// them is a sync. Getting this wrong is the easiest way to build the wrong
/// feature, so it is a property every coin answers rather than a string
/// comparison in the scheduler.
///
/// | Coin / mode | Mode | Keys in the process | Cost of a run |
/// | --- | --- | --- | --- |
/// | Monero, node | [scan] | the view key, and nothing else | minutes to hours |
/// | Monero, LWS | [check] | the server holds the view key | seconds |
/// | Bitcoin | [check] | an xpub | seconds |
/// | Ethereum | [check] | an address | seconds |
enum BackgroundSyncMode {
  /// Nothing to advance unattended: no server is configured, or this coin has
  /// no unattended path at all. A scheduling window must never open this
  /// wallet's file; for Monero that is the expensive part of the whole run.
  none,

  /// A remote server already did the scanning; a run *checks* what it found.
  ///
  /// Bitcoin over Electrum, Ethereum over RPC, Monero against a light-wallet
  /// server. View-only by construction; the wallet holds an xpub, an address,
  /// or credentials the server already has; so there is no key exposure for a
  /// background mode to reduce, and nothing to prepare. Network-latency bound,
  /// which is why even a ~30 s iOS refresh window can afford one.
  check,

  /// The wallet trial-decrypts every output on-device.
  ///
  /// Monero on a full node, and nothing else in this repository. CPU and
  /// bandwidth bound, so a scheduling window has to be able to afford it, and
  /// it is the only mode where *which key the process holds* is a question,
  /// because scanning needs the view key alone.
  scan,
}
