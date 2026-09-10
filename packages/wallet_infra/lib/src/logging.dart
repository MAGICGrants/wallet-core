import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;

enum LogLevel { info, warn, error }

/// Helpers for logging about sensitive values without disclosing them.
///
/// **Read this before adding a log line.** A wallet log is a privacy artifact:
/// users attach them to support threads, they sit in `/sdcard` on Android, and
/// they get pasted into issue trackers. A log naming an address or an amount
/// deanonymises the person who sent it, permanently.
///
/// Three tiers, and the API mirrors them:
///
///  - **Never**: seeds, mnemonics, private keys, passwords, raw server
///    payloads. Not truncated, not hashed. Use [secret], or say nothing.
///  - **Pseudonymous only**: addresses, txids, OpenAlias domains, subaddress
///    labels. Use [id]; a per-process salted fingerprint that correlates
///    lines within one run and is meaningless outside it.
///  - **Coarse only**: amounts and balances. Use [amount], which discloses
///    order of magnitude and nothing else.
///
/// Everything else; heights, counts, durations, status codes, error strings
/// from our own code; is fine verbatim, and is what actually makes a log
/// useful.
class Redact {
  Redact._();

  /// Stand-in for a value that must never be logged.
  static const String secret = '<redacted>';

  /// Per-process salt. Regenerated every launch and never persisted, so a
  /// fingerprint cannot be correlated across runs, users, or log files; only
  /// within the single log it appears in, which is all debugging needs.
  static final Uint8List _salt = Uint8List.fromList(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );

  /// Non-reversible pseudonym for an identifying string.
  ///
  /// Use for addresses, txids, OpenAlias domains; anything that identifies a
  /// party or a transaction. Two log lines about the same address share a
  /// fingerprint, which is what lets you follow a bug; nobody reading the log
  /// can recover the address, and the same address in a different session
  /// fingerprints differently.
  ///
  /// Truncated plaintext (`4AbC…xY9z`) is deliberately **not** offered: a
  /// prefix and suffix of a Monero address is enough to find it on chain.
  static String id(String? value) {
    if (value == null || value.isEmpty) return '<empty>';
    final digest = SHA256Digest()..update(_salt, 0, _salt.length);
    final bytes = Uint8List.fromList(utf8.encode(value));
    digest.update(bytes, 0, bytes.length);
    final out = Uint8List(32);
    digest.doFinal(out, 0);
    final hex = out.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '#$hex';
  }

  /// Order of magnitude of an amount in base units, never the value.
  ///
  /// Enough to tell dust from a sweep, or zero from non-zero, which is what
  /// balance and transaction bugs actually turn on. A deliberate, bounded
  /// disclosure: it narrows an amount to a power of ten and no further.
  static String amount(BigInt? baseUnits) {
    if (baseUnits == null) return '<null>';
    final abs = baseUnits.abs();
    if (abs == BigInt.zero) return '<amount:0>';
    final sign = baseUnits.isNegative ? '-' : '';
    return '<amount:$sign~1e${abs.toString().length - 1}>';
  }

  /// Size of a payload, for a body that must not be logged.
  ///
  /// Server responses carry addresses, amounts and output data. Log that one
  /// arrived and how big it was, never what it said.
  static String body(int byteLength) => '<body:$byteLength bytes>';
}

/// Where formatted log lines go.
///
/// The apps' original `logging.dart` mixed three concerns: the `log()` API,
/// verbosity gating via SharedPreferences, and a rotating file sink built on
/// `path_provider` + `share_plus`. Only the first belongs in a library; the
/// other two are plugin-backed, which would make every consumer of this package
/// untestable under `flutter test`.
///
/// So the core formats and gates; the app installs a sink that persists.
abstract class LogSink {
  const LogSink();

  Future<void> write(LogLevel level, String line);
}

/// Default sink: errors always, everything else only in debug builds.
/// Matches what the apps did before a file sink was installed.
class DebugPrintLogSink extends LogSink {
  const DebugPrintLogSink();

  @override
  Future<void> write(LogLevel level, String line) async {
    if (level == LogLevel.error || kDebugMode) debugPrint(line);
  }
}

/// Fans one record out to several sinks, in order. Lets an app persist to a file
/// and print to the console from a single installed sink.
class CompositeLogSink extends LogSink {
  final List<LogSink> sinks;
  const CompositeLogSink(this.sinks);

  @override
  Future<void> write(LogLevel level, String line) async {
    for (final sink in sinks) {
      await sink.write(level, line);
    }
  }
}

/// Collects lines in memory. For tests.
class MemoryLogSink extends LogSink {
  final List<({LogLevel level, String line})> records = [];

  @override
  Future<void> write(LogLevel level, String line) async {
    records.add((level: level, line: line));
  }

  void clear() => records.clear();
}

/// Log configuration, installed once by the app.
class WalletLog {
  WalletLog._();

  static LogSink sink = const DebugPrintLogSink();

  /// Whether `info` records are emitted at all. The app wires this to its
  /// verbose-logging preference; the default keeps info off, matching the
  /// apps' behaviour when the preference is unset.
  static Future<bool> Function() isVerbose = () async => false;

  /// Test helper; restores the defaults.
  static void resetForTesting() {
    sink = const DebugPrintLogSink();
    isVerbose = () async => false;
  }
}

String _timestamp() => DateTime.now().toUtc().toIso8601String();

String _withCoinPrefix(String message, String? coin) {
  if (coin == null || coin.isEmpty) return message;
  final prefix = '[$coin]';
  if (message.startsWith(prefix)) return message;
  return '$prefix $message';
}

/// Formats and emits one record.
///
/// The `{meta, coin}` signature is the superset. A call without
/// positional `[meta]` form is gone; its call sites change during the port.
/// The `coin` prefix is what makes a multicoin log readable and is harmless
/// for a single-coin app.
Future<void> log(LogLevel level, String message, {Map<String, dynamic>? meta, String? coin}) async {
  if (level == LogLevel.info && !await WalletLog.isVerbose()) return;

  final ts = _timestamp();
  final label = level.name.toUpperCase();
  final metaStr = (meta == null || meta.isEmpty) ? '' : ' $meta';

  // No space before metaStr; it already carries its own leading space. Adding
  // one gives a double space, and a trailing space on every meta-less line.
  final output = '[$ts] [$label] ${_withCoinPrefix(message, coin)}$metaStr';

  await WalletLog.sink.write(level, output);
}
