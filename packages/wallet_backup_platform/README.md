# wallet_backup_platform

The metadata backup's platform side (see `wallet_backup` for the format).

The backup is opt-in: off until the user turns it on in Settings > Backup, and
each location below is off until the user turns that on too. Until then
nothing is written anywhere, on the device or off it.

- **iOS:** the app's own iCloud container (`ICloudLocation`, with the Swift
  half in `ios/Classes`). No picker and no setup; needs iCloud Drive on. Files
  sit outside the container's Documents folder, so the Files app does not show
  them.
- **One iCloud container per app.** Skylight uses
  `iCloud.org.magicgrants.skylightwallet` and Spice
  `iCloud.org.magicgrants.spicewallet`, so the same recovery phrase in both
  apps does not share a backup through iCloud; the backup file moves one
  between them. Keep them separate: changing containers after release would be
  a migration.
- **Android:** Auto Backup. The files go to `<app dir>/metadata_backup/`
  (`app_flutter/metadata_backup/`), the one folder the app's backup rules
  include, and only while the user has this location on. Android copies it
  about once a night to the user's Google Drive, or to the phone's own backup
  service (Seedvault on GrapheneOS and CalyxOS), and restores it on install,
  before the first launch. Turning the location off stops adding files; what
  is there stays, and Android keeps carrying it. So does a copy Android
  restored: nothing reads it while the location is off, and nothing deletes it
  (not Skip on the import screen, saving or importing a file, turning the
  backup off or deleting the wallet). Turning Android backup on
  reads it in; only "Delete the Android backup copy", in its card while it is
  off, removes it. No Kotlin.
- **Everywhere:** saving the whole backup as one file (the share sheet on a
  phone, a save dialog on a desktop OS) and importing one.
- **The screens:** Settings > Backup (`MetadataBackupScreen`): the automatic
  locations as toggles, and the backup file below them, usable at any time
  and alongside them. There is no switch of its own: the copy on this device
  is kept only while a location is on, and turning the last one off deletes it,
  leaving iCloud's, Android backup's, every saved file, the wallets and the
  address book. With none on, saving a file or importing one uses the copy for
  that step alone. The only deletes of a
  location's files are its own links, "Delete the iCloud copy" and "Delete the
  Android backup copy", each shown in its card while that location is off. Then "Import wallet data" after
  a restore from the seed (`ImportWalletDataScreen`, shown by
  `scheduleImportWalletData`), with three choices:
  - *From iCloud / Android backup:* looks there first without writing
    anything (`findBackups`). Only if a backup is found is the backup turned on,
    with the location(s) it was found in; otherwise a pop-up says none was
    found and OK returns to the same screen, nothing turned on.
  - *From a backup file:* imports a backup file: its contacts go into the
    address book and its payment details into the payments the wallets have
    synced. Nothing else is kept, and every automatic location stays off.
  - *Skip:* nothing is kept until turned on in Settings > Backup.

  Never shown for a legacy 25-word Monero seed or a polyseed with an offset
  passphrase: they have no backup, so nothing is derived or looked for. Desktop
  has no automatic location, so it offers the file and No. Strings are in
  `lib/src/l10n` (`BackupLocalizations`; regenerate with `flutter gen-l10n`).

The device state (device id, next seq, Lamport clock, the address-book base)
lives in `<app dir>/metadata_backup_state/`, which iOS is told to leave out of
the phone's own backups and Android's rules never include, so a phone restored
from a backup starts a new device id.

iCloud and Auto Backup are run by the operating system, so they ignore the
app's Tor setting; the Backup screen says so.

## What an app does

1. In `main()`, on the UI isolate: `MetadataBackupSetup.install(...)` with the
   app's name, iCloud container and export file name. Background isolates do
   not install it.
2. Add `BackupLocalizations.delegate`, route to `MetadataBackupScreen` from
   Settings, and call `scheduleImportWalletData(context)` just before a
   restore from the seed leaves for the home screen.
3. **iOS.** In `Runner.entitlements`:

   ```xml
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.org.magicgrants.<app></string></array>
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudDocuments</string></array>
   <key>com.apple.developer.ubiquity-container-identifiers</key>
   <array><string>iCloud.org.magicgrants.<app></string></array>
   ```

   and in `Info.plist`, `NSUbiquitousContainers` with
   `NSUbiquitousContainerIsDocumentScopePublic` false. The container must also
   be created in the Apple Developer account and added to the app's App ID. Each
   app has its own container (see above); never point two apps at one.
4. **Android.** `android:allowBackup="true"` with `android:fullBackupContent`
   (Android 11 and earlier) and `android:dataExtractionRules` (12 and later),
   each including only `app_flutter/metadata_backup/` in every section: a
   section left out is fully enabled for all app data, which would carry the
   encrypted seed store and wallet files along. `disableIfNoEncryptionCapabilities`
   is not set: the files are sealed already.
5. **macOS.** `com.apple.security.files.user-selected.read-write` in both
   entitlements files, for the save and open dialogs.

## Testing on a device

- Android: `adb shell bmgr backupnow <package>`, then reinstall and restore the
  seed. Check what was backed up with `adb shell bmgr list sets` or by
  inspecting the backup transport; only `app_flutter/metadata_backup/` should
  be there.
- iOS: two devices on one Apple ID; send from one, unlock the other.

Neither check has been run on devices yet.
