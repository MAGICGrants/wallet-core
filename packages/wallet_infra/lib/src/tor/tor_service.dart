import 'dart:async';
import 'dart:io';

import 'package:tor_ffi_plugin/tor_ffi_plugin.dart';

import '../logging.dart';
import '../paths.dart';

enum TorConnectionStatus { disconnected, connecting, connected }

/// Owns the bundled Tor daemon.
///
/// No `Provider` is defined here: state management belongs to the app, and a
/// library should not drag riverpod in behind it. Apps wrap [sharedInstance]
/// themselves. See the notes on [start] and [waitUntilConnected].
class TorService {
  Tor? _tor;
  String? _torDataDirPath;
  Future<void>? _startInFlight;

  /// Current status. Same as that fired on the event bus.
  TorConnectionStatus get status => _status;
  TorConnectionStatus _status = TorConnectionStatus.disconnected;

  static final sharedInstance = TorService._();

  TorService._();

  /// Throws if Tor is not connected.
  ({InternetAddress host, int port}) getProxyInfo() {
    if (status == TorConnectionStatus.connected) {
      return (host: InternetAddress.loopbackIPv4, port: _tor!.port);
    }
    throw Exception('Tor proxy info fetched while not connected!');
  }

  /// Starts Tor and establishes a circuit.
  ///
  /// Concurrent callers join the attempt already running rather than starting
  /// a second Tor; the app calls this from startup, from the settings screen
  /// and from a connection retry, so overlap is normal rather than exotic.
  Future<void> start() async {
    if (_status == TorConnectionStatus.connected) return;

    final inFlight = _startInFlight;
    if (inFlight != null) return inFlight;

    final attempt = _start();
    _startInFlight = attempt;

    try {
      await attempt;
    } finally {
      if (identical(_startInFlight, attempt)) _startInFlight = null;
    }
  }

  Future<void> _start() async {
    _tor ??= Tor.instance;
    _torDataDirPath ??= (await getAppDir()).path;

    try {
      _status = TorConnectionStatus.connecting;
      await _tor!.start(torDataDirPath: _torDataDirPath!);
      _status = TorConnectionStatus.connected;
    } catch (e, s) {
      log(LogLevel.error, 'TorService.start failed: $e');
      log(LogLevel.error, s.toString());
      _status = TorConnectionStatus.disconnected;
      rethrow;
    }
  }

  Future<void> disable() async {
    if (_status == TorConnectionStatus.disconnected) return;

    _tor?.disable();
    await _tor?.stop();
    _status = TorConnectionStatus.disconnected;
  }

  /// Waits for Tor to come up, returning whether it did.
  ///
  /// Bounded, and it always cancels its poll timer. An unbounded version does
  /// neither: a Tor that never connects leaves a 50ms timer polling for the
  /// life of the isolate, one per call, and its future never completes at
  /// all, so a caller without its own timeout waits forever. Do not "simplify"
  /// this back.
  ///
  /// A start attempt that failed earlier is retried here, because nothing else
  /// retries it and the app would otherwise stay wedged until a restart.
  Future<bool> waitUntilConnected({Duration timeout = const Duration(seconds: 60)}) async {
    if (status == TorConnectionStatus.connected) return true;

    if (_status == TorConnectionStatus.disconnected && _startInFlight == null) {
      log(LogLevel.info, 'Tor is not running; retrying start.');
      unawaited(start().catchError((Object e) => log(LogLevel.warn, 'Tor start retry failed: $e')));
    }

    final completer = Completer<bool>();
    Timer? poll;
    Timer? deadline;

    void finish(bool connected) {
      poll?.cancel();
      deadline?.cancel();
      if (!completer.isCompleted) completer.complete(connected);
    }

    poll = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (status == TorConnectionStatus.connected) finish(true);
    });

    deadline = Timer(timeout, () {
      log(LogLevel.warn, 'Gave up waiting for Tor after ${timeout.inSeconds}s.');
      finish(false);
    });

    return completer.future;
  }
}
