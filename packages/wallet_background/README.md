# wallet_background

Background sync and incoming-payment notifications for both apps: Android's
WorkManager task and Continuous Sync foreground service, and iOS's
BGTaskScheduler windows. The apps keep only the isolate entry points.

## Everything here is view-only

Nothing that runs without the user holds a key that could spend. That covers
the periodic **Background sync**, Android's always-on **Continuous sync**, and
the **notification check** the periodic task also runs when only notifications
are on. Security keys on or off makes no difference.

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
- The material is kept while any background run is on (either sync toggle, or
  notifications) or security keys are, and only on Android, iOS and macOS
  (`WalletManager.applyViewOnlySetting`). The apps set it up as the toggles
  change (`WalletManager.applySyncSettings`). Monero's background copy needs a
  sync toggle (`unattendedSyncEnabled`).
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
  lets go when another claims them mid-run (`WalletHolders`). Every run closes
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

- `background_sync.dart`: `BackgroundSync` (the app's seams), `runTxNotifier`
  (one periodic pass), `dispatchBackgroundTask`, WorkManager and iOS scheduling.
- `foreground_sync_service.dart`: the Continuous Sync task handler and service
  control.
- `foreground_sync_link.dart`: the app's side of the hand-off.
- `sync_handoff.dart`: the service's rules and its messages, pure Dart.
- `wallet_holders.dart`: the named ports the app, the service and a periodic run
  answer on.
