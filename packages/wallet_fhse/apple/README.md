# Swift the apps compile in (iOS and macOS)

One copy serves both apps:

- The Swift half of the security-key channel (iOS and macOS).
  `SecurityKeyOperations.swift` talks CTAP2 to the key through YubiKit Swift;
  `SecurityKeyChannel.swift` maps it to the method channel that
  `lib/src/security_key_service.dart` calls.
- `PrivacyCover.swift` (iOS): App Lock's privacy cover, the launch screen over
  the app whenever its scene is not active, installed from each app's
  AppDelegate (not on a Mac running the iOS build).
- `SecureScreen.swift` (iOS): keeps the window out of screenshots and screen
  recordings while `wallet_infra`'s `SecureScreenMixin` asks for it. Each app's
  AppDelegate answers the `org.magicgrants.wallet/secure_screen` channel with it.

They are not part of this plugin's pods: YubiKit Swift is a Swift package, and
a CocoaPods pod cannot depend on one. Each app adds YubiKit Swift to its Runner
target and compiles these files there, through the link Flutter keeps to
this package before every build:

- iOS: `ios/.symlinks/plugins/wallet_fhse/apple/`
- macOS: `macos/Flutter/ephemeral/.symlinks/plugins/wallet_fhse/apple/`

The app registers the channel itself (`SecurityKeyChannel(messenger:)`, in its
AppDelegate on iOS and MainFlutterWindow on macOS).

Each app's iOS Info.plist lists the applets the NFC reader may select, under
`com.apple.developer.nfc.readersession.iso7816.select-identifiers`: FIDO
(`A0000006472F0001`) and YubiKey Management (`A000000527471117`). Without the
second, iOS refuses the serial-number read over NFC, so the check that a key is
the one that was set up never runs there.
