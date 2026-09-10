import 'dart:io';

import 'package:flutter/services.dart';

import '../paths.dart';

/// Android's system CA store is not visible to the bundled OpenSSL that
/// monero_c links, so the wallet is handed an explicit CA bundle instead.
/// The asset itself lives in the consuming app.
const cacertAssetKey = 'assets/cacert.pem';

Future<void> copyCacertToAppDocumentsDir() async {
  final dir = await WalletPaths.directories.applicationDocuments();
  final cacert = await rootBundle.load(cacertAssetKey);
  await File('${dir.path}/cacert.pem').writeAsBytes(cacert.buffer.asUint8List(), flush: true);
}

Future<File> getCacertFile() async {
  final dir = await WalletPaths.directories.applicationDocuments();
  return File('${dir.path}/cacert.pem');
}
