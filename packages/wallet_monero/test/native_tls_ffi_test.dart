// monero.dart marks almost its whole surface `@Deprecated("TODO")`, the
// generator's marker for "not yet exercised"; there is no replacement API.
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:wallet_monero/testing.dart';

/// TLS against the real native library on this host: LWS and node, direct
/// and through SOCKS, and the wallet's own connect path. See
/// [nativeTlsChecks] for what each check proves. The apps run the same checks
/// on Android, iOS, Linux and Windows in their integration tests.
///
/// Runs in `native.yml`, which builds the library and sets MONERO_LIB_PATH (and
/// the loader path, for the isolates the wallet spawns). Skips without the
/// library, or fails under REQUIRE_MONERO_FFI=1.
void main() {
  final libPath = Platform.environment['MONERO_LIB_PATH'];
  final required = Platform.environment['REQUIRE_MONERO_FFI'] == '1';

  bool libraryLoads() {
    if (libPath != null && libPath.isNotEmpty) monero.libPath = libPath;
    try {
      monero.WalletManagerFactory_getLWSFWalletManager();
      return true;
    } catch (_) {
      return false;
    }
  }

  final available = libraryLoads();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('native_tls'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  for (final check in nativeTlsChecks(libPath: libPath)) {
    test(check.name, () async {
      if (!available) {
        if (required) {
          fail(
            'REQUIRE_MONERO_FFI=1 but monero_c did not load (libPath="${monero.libPath}"). '
            'Build it with scripts/build-moneroc-ci.sh and set MONERO_LIB_PATH.',
          );
        }
        return markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
      }
      await check.run(tmp);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
