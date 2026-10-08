/// vtnerd's FHSE (FIDO2 hmac-secret encryption) guarding the wallet password.
///
/// The wallet password becomes FHSE's root, derived from the seed
/// ([WalletKeyTree]). Until security keys are set up it sits in the keystore as
/// before; once they are ([FhseVault], [FhseWalletGuard.engage]) only a key and
/// its PIN can release it. Install [FhseWalletGuard] on
/// `WalletManager.passwordGuard` to use it.
library;

export 'src/fhse_native.dart' show FhseException, FhseNative;
export 'src/fhse_secret.dart' show FhseSecret, fhseSecretLength;
export 'src/fhse_vault.dart';
export 'src/wallet_key_tree.dart';
