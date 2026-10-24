import 'dart:convert';

import 'package:wallet_infra/wallet_infra.dart';

/// Where the user stands with checking their seed phrase: the day they last
/// typed the asked-for words correctly, and how many wrong tries since.
class SeedCheckState {
  const SeedCheckState({required this.verifiedDay, required this.failures});

  /// Days since the epoch (UTC) of the last correct check; null for never.
  final int? verifiedDay;

  /// Wrong tries since the last correct one or the last lock.
  final int failures;

  static const empty = SeedCheckState(verifiedDay: null, failures: 0);

  /// How long a correct check counts for before the home asks again.
  static const validFor = Duration(days: 182);

  /// Whether the user checked within [validFor] of [now].
  bool isCurrent(DateTime now) {
    final day = verifiedDay;
    if (day == null) return false;
    return _day(now) - day < validFor.inDays;
  }
}

int _day(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

/// Keeps [SeedCheckState] in the keystore.
///
/// The keystore rather than preferences so the wrong-try count cannot be reset
/// by editing a plaintext file, which would undo the lock after repeated wrong
/// tries. Only a day number and a count are stored, never a word or a position.
/// [delete] runs with the rest of the wallet's keys when the wallet is deleted.
class SeedCheckStore {
  SeedCheckStore._();

  static const key = 'seedCheck';

  static Future<SeedCheckState> read() async {
    try {
      final stored = await WalletSecrets.store.read(key);
      if (stored == null || stored.isEmpty) return SeedCheckState.empty;
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      return SeedCheckState(
        verifiedDay: decoded['verifiedDay'] as int?,
        failures: decoded['failures'] as int? ?? 0,
      );
    } catch (e) {
      log(LogLevel.warn, 'Could not read the seed check state: ${e.runtimeType}');
      return SeedCheckState.empty;
    }
  }

  /// Records a correct check on [now]'s day and clears the wrong tries.
  static Future<void> markVerified(DateTime now) =>
      _write(SeedCheckState(verifiedDay: _day(now), failures: 0));

  /// Counts a wrong try and returns the count so far.
  static Future<int> recordFailure() async {
    final state = await read();
    final failures = state.failures + 1;
    await _write(SeedCheckState(verifiedDay: state.verifiedDay, failures: failures));
    return failures;
  }

  /// Clears the wrong tries, keeping the last correct day. Called once the app
  /// has locked for them.
  static Future<void> resetFailures() async {
    final state = await read();
    if (state.failures == 0) return;
    await _write(SeedCheckState(verifiedDay: state.verifiedDay, failures: 0));
  }

  static Future<void> delete() async {
    try {
      await WalletSecrets.store.delete(key);
    } catch (e) {
      log(LogLevel.warn, 'Could not clear the seed check state: ${e.runtimeType}');
    }
  }

  static Future<void> _write(SeedCheckState state) async {
    try {
      await WalletSecrets.store.write(
        key,
        jsonEncode({'verifiedDay': state.verifiedDay, 'failures': state.failures}),
      );
    } catch (e) {
      log(LogLevel.warn, 'Could not save the seed check state: ${e.runtimeType}');
    }
  }
}
