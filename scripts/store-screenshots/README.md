# Store screenshots

`scripts/store-screenshots.sh` takes Skylight's and Spice's listing screenshots from the real
app running on sample wallets. The App Store sets come from iOS simulators and the F-Droid set
from an Android emulator (a Pixel). Every run gets the same screens, the same figures and a
9:41 status bar. Nothing reaches a server, and none of it ships in a release build.

## The pieces

- **wallet-core**:
  - `package:wallet_domain/screenshots.dart`: `SampleActivity` (the fixed balance and
    history), the `SampleWallet` mixin, and `StoreShots.capture`, the test's half of the
    handshake with the script.
  - `package:wallet_monero|wallet_bitcoin|wallet_ethereum/screenshots.dart`: the sample
    wallets.
  - `package:wallet_fhse/screenshots.dart`: Advanced Security showing keys that don't exist.
  - `package:wallet_backup/screenshots.dart` with `MetadataBackupSetup.serviceForTesting`: a
    backup that reports itself on.
  - `FiatRates.fixedRates`: fixed prices.
  - `scripts/store-screenshots.sh` and `fit.swift` here.
- **Each app**:
  - `integration_test/store_screenshots_test.dart` walks the app and asks for each picture.
  - `scripts/store-screenshots.sh` holds `STORE_SHOTS`, the listing's screenshots in priority
    order.
  - `appCoins` in `lib/wallet_core_glue.dart` is the one hook the test uses.

## Order

`STORE_SHOTS` in each app's `scripts/store-screenshots.sh` is the priority order:

- The App Store sets take the first 10 (Apple's limit per size), numbered `01-…` to `10-…`.
- F-Droid takes them all, as `01.png`, `02.png`, …; F-Droid sorts names as text, hence the
  two digits.

Each app's design-system artifact lists the same order in `store-listing.md`. Change both
together.

## Requirements

- A Flutter new enough for wallet-core, and this checkout beside the app (`../wallet-core`),
  with the app's `pubspec_overrides.yaml` pointing at it. Run `flutter pub get` in the app
  first.
- **App Store sets:** Xcode with an iOS simulator runtime.
- **F-Droid set:** the Android SDK with `emulator`, `platform-tools` and a system image, plus
  a JDK 17 for the Gradle build. The AVD, once (on Intel, use `x86_64` in place of
  `arm64-v8a`):

  ```bash
  sdkmanager "emulator" "platform-tools" "system-images;android-35;google_apis;arm64-v8a"
  avdmanager create avd -n Store_Shots_Pixel_8 -d pixel_8 -k "system-images;android-35;google_apis;arm64-v8a"
  ```

  The script starts it when no emulator is running. `ANDROID_HOME` (default
  `~/Library/Android/sdk`) and `ANDROID_AVD` override the paths.

## Taking them

From each app's root (`skylight-wallet`, `spice-wallet`):

```bash
scripts/store-screenshots.sh                                  # App Store: iPhone and iPad
scripts/store-screenshots.sh --device android --update-fdroid # F-Droid: the Pixel
```

The output lands in `build/store_screenshots/<version>/`:

- `source/<device>/`: every capture, as taken.
- `app-store/iphone-6.9` (1320×2868), `app-store/iphone-6.5` (1242×2688) and
  `app-store/ipad-13` (2064×2752): ready to upload, in order, without alpha.
- `fdroid/`: the Pixel's captures in order.

`--update-fdroid` replaces `fastlane/metadata/android/en-US/images/phoneScreenshots/` with
`fdroid/`. Commit those; the App Store sets go to the artifact, not the repo.

A first build per device takes several minutes; after that a device takes about 3. Don't edit
the script while it runs: bash reads it as it goes.

## Checking them

Look at every picture before publishing:

- the theme each screen was asked for (see `STORE_SHOTS`)
- the 9:41 status bar
- no keyboard, toast, dialog, spinner or half-finished animation

The script switches the "Store Shots iPad" simulator to Full Screen Apps (Settings >
Multitasking & Gestures) on first use. A windowed app carries a resize arc in the corner of
every picture, so if you see one, check that setting.

If a screen is wrong, fix the test (wait longer, close the dialog, tap another label) rather
than editing pictures.

When the test fails, it photographs the screen it stopped on (`<device>-failure.png`) and logs
the text on it. Look for `store shots: stopped on:` in `<device>-test.log`. `Never appeared:
<finder>` names the step that broke.

## Not yet run: Android

The Android path was written without an emulator to hand. What it relies on, in case the first
run stops:

- `Directory.systemTemp` is the app's cache directory, which the script reads with
  `adb shell run-as <package> cat cache/store_shots/request`. `run-as` needs a debug build,
  which `flutter test` makes.
- The notification permission is granted with `pm grant` as soon as the app is installed,
  before the app can ask: the system's dialog is out of the test's reach. Another system
  dialog would need the same treatment, or a tap with `adb shell input`.
- Dark mode is the system's, switched with `adb shell cmd uimode night yes|no`, and the app's
  theme setting is System.
- The status bar is System UI's demo mode: 9:41, full signal and battery, no notification
  icons.
- The onboarding taps match the iOS walk. A label or step that differs on Android needs the
  test changed for both, or a `Platform.isAndroid` branch.
