# wallet_background

Background sync and incoming-payment notifications for both apps: Android's
WorkManager jobs and Continuous Sync foreground service, and iOS's
BGTaskScheduler windows. The apps keep only the isolate entry points.

## Sync Frequency

One app-wide setting, under Settings > Behavior, decides what runs while the
app is closed (`SyncFrequency` in wallet_infra; the sheet is wallet_ui's
`showSyncFrequencySheet`, applied with `applySyncFrequency`). **Transaction
Notifications** is a separate setting: it only decides whether a run that
finds a payment shows a notification, never whether runs happen.

Coins sync in one of two ways (`CryptoWallet.backgroundSyncMode`). A **check**
asks a server that already scanned: Bitcoin, Ethereum, Monero on a light-wallet
server. A **full scan** downloads and scans every block on the device: Monero
on a node.

| Sync Frequency | Android | iOS |
|---|---|---|
| **Continuous** | A foreground service, with a persistent notification, keeps every coin with a server connected and syncing. A full scan has no charging or WiFi limit. | Not offered (unsupported). |
| **Periodic** | Two jobs, each registered only while some coin gives it work (below). | Two iOS windows, each registered only while some coin gives it work (below). |
| **Off** | Nothing in the background; coins sync only while the app is open. | Same. |

New installs start on Periodic. The first launch after the setting was added
moves the old toggles onto it (`migrateLegacySyncSettings`): Continuous Sync on
became Continuous, Background Sync or notifications on became Periodic, and an
existing install with all of them off stayed Off.

### Periodic on Android

Two WorkManager jobs, each every ~15 minutes (Android's minimum):

- **Light job** (`PeriodicTasks.txNotifier`): any network, battery not low.
  Checks every check coin, Tor ones included.
- **Full-scan job** (`PeriodicTasks.scan`): only while charging and on WiFi.
  Runs every full scan, and checks the check coins too.

| Coins with a server | Not charging, or not on WiFi | Charging and on WiFi |
|---|---|---|
| Bitcoin and/or Ethereum only | Checks them | Checks them |
| Monero on a light-wallet server (with or without Bitcoin/Ethereum) | Checks all of them | Checks all of them |
| Monero on a node, nothing else | Nothing runs: no light job is registered; the full-scan job waits | Scans Monero |
| Monero on a node, plus Bitcoin and/or Ethereum | Checks Bitcoin/Ethereum | Checks Bitcoin/Ethereum, scans Monero |
| No coin has a server | No job registered | No job registered |

The two jobs share the app's process and take turns (below): the light job
skips while the full-scan job holds the wallets, since that one checks the same
coins, and the full-scan job has a running light job let go first.

### Periodic on iOS

iOS decides when each window runs:

- **Short refresh** (`PeriodicTasks.iosRefresh`): ~30 seconds. No Tor (a
  bootstrap can outlast it) and no full scan.
- **Long processing** (`PeriodicTasks.iosProcessing`): only while charging,
  usually overnight, a few minutes. Tor and full scans included.

| Coins with a server | Short refresh | Long processing (charging) |
|---|---|---|
| Bitcoin and/or Ethereum, no Tor | Checks them | Checks them |
| Bitcoin and/or Ethereum, using Tor | Not registered | Checks them |
| Monero on a light-wallet server, no Tor (with or without Bitcoin/Ethereum) | Checks all of them | Checks all of them |
| Monero on a light-wallet server using Tor | Skips Monero; checks Bitcoin/Ethereum without Tor | Checks all of them |
| Monero on a node, nothing else | Not registered | Scans Monero |
| Monero on a node, plus Bitcoin and/or Ethereum | Checks Bitcoin/Ethereum without Tor | Checks Bitcoin/Ethereum, scans Monero |
| No coin has a server | Not registered | Not registered |

The processing window can only require "any network", not WiFi, so a scan
there may run on cellular. iOS can also end the window early; a scanning
wallet checkpoints every few minutes as it goes
(`CryptoWallet.syncCheckpointInterval`), so little is lost.

### New coins

The rules above follow the sync type, not the coin. A coin added later that has
to scan on the device, such as Bitcoin Silent Payments or Zcash shielded
addresses, reports `BackgroundSyncMode.scan` and so takes the Monero node rows:
only the full-scan job on Android, while charging and on WiFi, and only the long
processing window on iOS. A coin that asks a server reports `check` and takes
the Bitcoin/Ethereum rows.

### Where it is decided

- Registration: `applyBackgroundTaskRegistration`, after the setting changes,
  after a saved connection has been applied (the wallet rebuilt for it), when
  the wallet home opens, and on every launch. It registers a task only when
  `syncableCoins` (the same choice a run makes) finds work for it, and updates a
  task that stays in place rather than pushing its next run back. Never call it
  from a connection form's save: it asks whether each wallet file exists, and a
  Monero wallet whose just-saved mode has no file yet would switch back to the
  mode that has one.
- A run: `dispatchBackgroundTask` routes each task to a window, and does
  nothing unless the setting is Periodic (a task already handed to the isolate
  can arrive after the user changed it). `runTxNotifier` re-checks which coins
  the window may sync, because iOS can deliver a task scheduled under a
  connection the user has since changed.

## Everything here is view-only

Nothing that runs without the user holds a key that could spend: not a
Periodic run, not Android's Continuous Sync. Security keys on or off makes no
difference.

| Coin | What a background run opens |
|---|---|
| Monero, node | wallet2's view-only background copy, `<wallet>_node.background` (spend key removed, its own cache password) |
| Monero, light-wallet server | nothing: it asks the server, with the address and view key |
| Bitcoin | the account xpub |
| Ethereum and ERC-20 | the address |

- A run never loads the wallet password or decrypts the seed store
  (`WalletManager.isUnattendedRun`). A coin whose view-only material is not set
  up yet is skipped, never opened with its keys; Monero never falls back to the
  main wallet.
- The material is kept while Sync Frequency is anything but Off
  (`unattendedRunsEnabled`) or security keys are on, and only on Android, iOS
  and macOS (`WalletManager.applyViewOnlySetting`). `applySyncFrequency` sets it
  up when the setting changes (`WalletManager.applySyncSettings`), and so does
  Monero's background copy, which a node needs for any run without the user.
- The background copy does not watch the mempool, so a payment is announced at
  its first confirmation. What it scanned merges into the main wallet the next
  time that opens (wallet2 replays only the transactions it saved).

## One holder at a time

On Android the app, the Continuous Sync service and a periodic run can all live
in one process, where wallet2's file locks never exclude one another. So only
one of them holds the wallets at a time:

- **The app** holds them whenever any is open, with its keys or view-only after
  the spend wallet locked, and announces payments itself. Before it opens them
  with the password it claims them (`WalletManager.claimWalletFiles`, installed
  by `ForegroundSyncLink`): a periodic run and the service store, close and say
  so first.
- **The Continuous Sync service** (`BackgroundSyncTaskHandler`) starts holding
  nothing and pings the app every 30 seconds. It holds the view-only wallets
  only while the app holds none (at its lock screen after a cold start, say) or
  has stopped answering (Android closed its screen), and lets go on the app's
  claim (`SyncHandoff`).
- **A periodic run** skips while the app or the service holds the wallets, and
  lets go when another claims them mid-run (`WalletHolders`). Android's two
  Periodic jobs answer on the same name and take turns the same way. Every run closes
  its wallets at the end: WorkManager destroys its isolate next, and a wallet
  left open would stay behind in a process the app or the service keeps alive.

## When the app is closed

- **Swiped away:** Android destroys the app's isolate without closing its
  wallets, while the service keeps the process alive. The app lists its open
  native Monero wallets with the process id and its isolate's token
  (wallet_monero's `NativeWalletRegistry`). Whoever takes over (the service
  after three missed pings, a periodic run, or the app's next isolate on its
  claim) closes the ones a destroyed isolate left (`closeOrphanedMoneroWallets`).
  The service holds the view-only copies meanwhile. Not every live isolate can
  be told from a destroyed one: a second instance of the app, started while
  the first still runs, takes the first one's wallets for left behind and
  closes them while they are in use.
- **Killed** (low memory, a native crash): the service restarts itself and
  holds nothing until no app answers its pings.
- **Force-stopped:** nothing runs until the app is opened again; WorkManager
  then reschedules itself and the app restarts the service. The next unlock
  merges whatever the view-only copy saved.

## Layout

- `background_sync.dart`: `BackgroundSync` (the app's seams), `syncableCoins`,
  `runTxNotifier` (one periodic pass), `dispatchBackgroundTask`, WorkManager and
  iOS scheduling.
- `foreground_sync_service.dart`: the Continuous Sync task handler, service
  control, and `applySyncFrequency`.
- `foreground_sync_link.dart`: the app's side of the hand-off.
- `sync_handoff.dart`: the service's rules and its messages, pure Dart.
- `wallet_holders.dart`: the named ports the app, the service and a periodic run
  answer on.
