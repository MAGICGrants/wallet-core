import 'dart:io';

import 'package:wallet_infra/wallet_infra.dart';

/// Re-encrypts a [WalletFileCrypto] file from the wallet password [from] to
/// [to], keeping what it holds: the password changed while the file's owner
/// was not open (a hidden testnet coin). True when the file now opens with
/// [to], whether re-encrypted here or already under it, and when there is no
/// file; false, leaving it as it is, when neither password opens it.
Future<bool> rekeyWalletFile(File file, {required String from, required String to}) async {
  if (!await file.exists()) return true;
  final blob = await file.readAsString();
  final String plain;
  try {
    plain = await WalletFileCrypto.decryptFromBase64(blob, from);
  } catch (_) {
    try {
      await WalletFileCrypto.decryptFromBase64(blob, to);
      return true;
    } catch (_) {
      return false;
    }
  }
  await writeStringAtomic(file, await WalletFileCrypto.encryptToBase64(plain, to));
  return true;
}
