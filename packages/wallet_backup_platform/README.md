# wallet_backup_platform

The metadata backup's platform side (see `wallet_backup` for the format):

- **iOS:** the app's own iCloud container (`ICloudLocation`, with the Swift
  half in `ios/Classes`). No picker and no setup; needs iCloud Drive on. Files
  sit outside the container's Documents folder, so the Files app does not show
  them.
- **Android:** Auto Backup. The files go to `<app dir>/metadata_backup/`
  (`app_flutter/metadata_backup/`), the one folder the app's backup rules
  include. Android copies it about once a night to the user's Google Drive, or
  to the phone's own backup service (Seedvault on GrapheneOS and CalyxOS), and
  restores it on install, before the first launch. No Kotlin.
- **Everywhere:** saving the whole backup as one file (the share sheet on a
  phone, a save dialog on a desktop OS) and importing one.
- **The screens:** Settings > Backup (`MetadataBackupScreen`) and the prompt
  after a restore (`scheduleBackupRestorePrompt`), with their strings in
  `lib/src/l10n` (`BackupLocalizations`; regenerate with `flutter gen-l10n`).

The device state (device id, next seq, Lamport clock, the address-book base)
lives in `<app dir>/metadata_backup_state/`, which iOS is told to leave out of
the phone's own backups and Android's rules never include, so a phone restored
from a backup starts a new device id (plan §4.1).

iCloud and Auto Backup are run by the operating system, so they ignore the
app's Tor setting; the Backup screen says so.

## What an app does

1. In `main()`, on the UI isolate: `MetadataBackupSetup.install(...)` with the
   app's name, iCloud container and export file name. Background isolates do
   not install it.
2. Add `BackupLocalizations.delegate`, route to `MetadataBackupScreen` from
   Settings, and call `scheduleBackupRestorePrompt(context)` just before a
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
   app has its own container.
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

Neither has been run yet.
