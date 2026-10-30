import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// The seed check's record: it lives in the keystore, keeps a day and a count
/// only, expires after about six months, and goes with the wallet.
void main() {
  late MemorySecretStore secrets;

  setUp(() {
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    SharedPreferencesService.store = MemoryPreferenceStore();
  });

  tearDown(() {
    WalletSecrets.resetForTesting();
    SharedPreferencesService.resetForTesting();
  });

  test('nothing recorded reads as never checked', () async {
    final state = await SeedCheckStore.read();
    expect(state.verifiedDay, isNull);
    expect(state.failures, 0);
    expect(state.isCurrent(DateTime.utc(2026, 10, 19)), isFalse);
  });

  test('a correct check counts for about six months, then lapses', () async {
    final checked = DateTime.utc(2026, 1, 10, 15);
    await SeedCheckStore.markVerified(checked);
    final state = await SeedCheckStore.read();

    expect(state.isCurrent(checked), isTrue);
    expect(state.isCurrent(checked.add(const Duration(days: 181))), isTrue);
    expect(state.isCurrent(checked.add(const Duration(days: 182))), isFalse);
  });

  test('only a day number and a count are stored', () async {
    await SeedCheckStore.markVerified(DateTime.utc(2026, 1, 10, 15, 30));
    await SeedCheckStore.recordFailure();

    final stored = jsonDecode(secrets.values[SeedCheckStore.key]!) as Map<String, dynamic>;
    expect(stored.keys.toSet(), {'verifiedDay', 'failures'});
    expect(stored['verifiedDay'], DateTime.utc(2026, 1, 10).millisecondsSinceEpoch ~/ 86400000);
  });

  test('wrong tries add up, and a correct check or a reset clears them', () async {
    expect(await SeedCheckStore.recordFailure(), 1);
    expect(await SeedCheckStore.recordFailure(), 2);

    await SeedCheckStore.resetFailures();
    expect((await SeedCheckStore.read()).failures, 0);

    await SeedCheckStore.recordFailure();
    await SeedCheckStore.markVerified(DateTime.utc(2026, 3, 1));
    final state = await SeedCheckStore.read();
    expect(state.failures, 0);
    expect(state.verifiedDay, isNotNull);
  });

  test('a reset keeps the last correct day', () async {
    await SeedCheckStore.markVerified(DateTime.utc(2026, 3, 1));
    final day = (await SeedCheckStore.read()).verifiedDay;
    await SeedCheckStore.recordFailure();
    await SeedCheckStore.resetFailures();
    expect((await SeedCheckStore.read()).verifiedDay, day);
  });

  test('an unreadable record reads as never checked', () async {
    secrets.values[SeedCheckStore.key] = 'not json';
    final state = await SeedCheckStore.read();
    expect(state.verifiedDay, isNull);
    expect(state.failures, 0);
  });

  test('deleting the wallet deletes the record', () async {
    final tmp = Directory.systemTemp.createTempSync('seed_check');
    addTearDown(() {
      WalletAppConfig.resetForTesting();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    final wallet = FakeWallet('XMR');
    final manager = WalletManager(coins: () => [wallet]);
    addTearDown(manager.dispose);

    await SeedCheckStore.markVerified(DateTime.utc(2026, 3, 1));
    await manager.deleteAll();

    expect(secrets.values.containsKey(SeedCheckStore.key), isFalse);
  });
}
