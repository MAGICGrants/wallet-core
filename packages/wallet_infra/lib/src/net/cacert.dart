import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import '../paths.dart';

/// Mozilla's CA set, as published at curl.se/docs/caextract.html, shipped with
/// this package.
const caBundleAssetKey = 'packages/wallet_infra/assets/cacert.pem';

/// The one trust store for TLS to a Monero server (an LWS or a node), on every
/// platform and in both the native library and Dart.
///
/// The native library links its own OpenSSL, which cannot see the Android or
/// iOS certificate store and whose compiled-in default location holds nothing
/// on a user's machine. It is therefore always handed this bundle as a file.
/// Dart's own requests to the same server (the connection probe, the
/// subaddress registration) trust the same set through [securityContext], so
/// a server the probe accepts is one the wallet can reach, and a root that only
/// the OS trusts (an enterprise or antivirus inspection root) is trusted by
/// neither.
class CaBundle {
  CaBundle._();

  /// Supplies the bundle's bytes. The packaged asset unless a test substitutes
  /// a CA of its own.
  @visibleForTesting
  static Future<Uint8List> Function() load = _loadAsset;

  static Uint8List? _bytes;
  static SecurityContext? _context;
  static String? _written;
  static Future<String>? _inFlight;

  static Future<Uint8List> _loadAsset() async {
    final data = await rootBundle.load(caBundleAssetKey);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// The bundle's bytes, checked to hold at least one PEM certificate.
  static Future<Uint8List> bytes() async {
    final cached = _bytes;
    if (cached != null) return cached;
    final loaded = await load();
    // A truncated or empty asset would leave the native library with an empty
    // trust store, which fails every handshake with an error about the server
    // rather than about us. Refuse it here, where the cause is still known.
    if (!_holdsCertificate(loaded)) {
      throw const FormatException('The CA bundle contains no PEM certificate.');
    }
    return _bytes = loaded;
  }

  static bool _holdsCertificate(List<int> pem) =>
      String.fromCharCodes(pem).contains('-----BEGIN CERTIFICATE-----');

  /// Path of a file holding the bundle, for the native library.
  ///
  /// Written into the app's own directory ([getAppDir]), never the desktop
  /// Documents folder, and rewritten whenever the file is missing or differs
  /// from the shipped bundle, so an app update that refreshes the bundle takes
  /// effect. Concurrent callers share one write. A failure is thrown rather
  /// than answered with a path that does not exist: the caller must not
  /// connect without a trust store.
  static Future<String> path() async {
    final written = _written;
    if (written != null && await File(written).exists()) return written;
    return _inFlight ??= _materialize().whenComplete(() => _inFlight = null);
  }

  static Future<String> _materialize() async {
    final dir = await getAppDir();
    final file = File('${dir.path}${Platform.pathSeparator}cacert.pem');

    final Uint8List contents;
    try {
      contents = await bytes();
    } catch (_) {
      // A background isolate (WorkManager, the foreground service) may have no
      // asset bundle to read. The copy the app itself wrote is the same file,
      // so it is used as long as it still holds certificates.
      if (await file.exists() && _holdsCertificate(await file.readAsBytes())) {
        return _written = file.path;
      }
      rethrow;
    }

    await dir.create(recursive: true);

    if (!await file.exists() || !listEquals(await file.readAsBytes(), contents)) {
      // Write beside the target and rename over it, so no reader (a background
      // isolate, a second process) ever sees a half-written bundle. The name is
      // unique per writer so two of them cannot interleave in one temp file.
      final tmp = File('${file.path}.${pid}_${Random().nextInt(1 << 32)}.tmp');
      try {
        await tmp.writeAsBytes(contents, flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        if (await tmp.exists()) await tmp.delete();
        rethrow;
      }
    }

    return _written = file.path;
  }

  /// A context that trusts exactly the bundle, for Dart requests to a Monero
  /// server.
  static Future<SecurityContext> securityContext() async =>
      _context ??= SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(await bytes());

  @visibleForTesting
  static void resetForTesting() {
    load = _loadAsset;
    _bytes = null;
    _context = null;
    _written = null;
    _inFlight = null;
  }
}
