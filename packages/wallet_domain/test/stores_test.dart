import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

const _bip39 =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _password = 'wallet-password';
const _fast = 1000;

/// v1 blobs (Spice's original) had no format tag and were always BIP39.
Future<void> _writeV1Blob(File file, {required String mnemonic, required String iso}) async {
  final body = jsonEncode({'v': 1, 'mnemonic': mnemonic, 'restore_date_iso': iso});
  await file.writeAsString(
    await WalletFileCrypto.encryptToBase64(body, _password, iterations: _fast),
  );
}

void main() {
  late Directory tmp;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wallet_stores');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
  });

  tearDown(() {
    WalletAppConfig.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('SeedStore', () {
    test('exists() is false before anything is written', () async {
      expect(await SeedStore.exists(), isFalse);
      expect(await SeedStore.load(_password), isNull);
    });

    test('round-trips each seed format with its tag (v2)', () async {
      final cases = <SeedSource>[
        const Bip39Seed(_bip39),
        const PolyseedSeed('sixteen words go here'),
        const MoneroLegacySeed('twenty five words go here'),
      ];

      for (final seed in cases) {
        final date = DateTime.utc(2026, 3, 14);
        await SeedStore.save(seed: seed, from: RestorePoint.date(date), password: _password);

        final loaded = await SeedStore.load(_password);
        expect(loaded, isNotNull, reason: seed.format.name);
        expect(loaded!.seed.format, seed.format);
        expect(loaded.seed.mnemonic, seed.mnemonic);
        expect((loaded.from as RestoreFromDate).date, date);
      }
    });

    test('round-trips a height restore point verbatim (v3)', () async {
      // The reason v3 stores a RestorePoint rather than a bare date: Skylight's
      // height-based restore must survive as a height, not be degraded to a date
      // A v1/v2 blob has no height and reads back as RestorePoint.date;
      // covered by the v1 test below.
      await SeedStore.save(
        seed: const PolyseedSeed('sixteen words go here'),
        from: const RestorePoint.height(2500000),
        password: _password,
      );

      final loaded = await SeedStore.load(_password);
      expect(loaded!.from, isA<RestoreFromHeight>());
      expect((loaded.from as RestoreFromHeight).height, 2500000);
    });

    test('preserves a passphrase and omits it when empty', () async {
      await SeedStore.save(
        seed: const Bip39Seed(_bip39, passphrase: 'extra'),
        from: RestorePoint.date(DateTime.utc(2026)),
        password: _password,
      );
      expect((await SeedStore.load(_password))!.seed.passphrase, 'extra');

      await SeedStore.save(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
        password: _password,
      );
      expect((await SeedStore.load(_password))!.seed.passphrase, isEmpty);
    });

    test('reads a v1 blob as BIP39', () async {
      // Spice's v1 format predates the tag and was always BIP39. Existing dev
      // wallets must keep opening.
      await _writeV1Blob(
        File('${tmp.path}/master_seed'),
        mnemonic: _bip39,
        iso: DateTime.utc(2025, 6, 1).toIso8601String(),
      );

      final loaded = await SeedStore.load(_password);
      expect(loaded!.seed, isA<Bip39Seed>());
      expect(loaded.seed.mnemonic, _bip39);
      expect((loaded.from as RestoreFromDate).date, DateTime.utc(2025, 6, 1));
    });

    test('the wrong password throws — it must not look like "no seed"', () async {
      await SeedStore.save(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
        password: _password,
      );
      // Returning null here would be read as "no wallet" and send the user
      // through onboarding on top of an existing one.
      expect(SeedStore.load('wrong'), throwsA(isA<FormatException>()));
    });

    test('delete removes the file', () async {
      await SeedStore.save(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
        password: _password,
      );
      expect(await SeedStore.exists(), isTrue);
      await SeedStore.delete();
      expect(await SeedStore.exists(), isFalse);
      expect(await SeedStore.load(_password), isNull);
    });

    test('delete on a missing file is a no-op', () => expect(SeedStore.delete(), completes));
  });

  group('WalletCacheStore', () {
    test('an absent cache is an empty map, not an error', () async {
      expect(await WalletCacheStore.load('XMR', _password), isEmpty);
    });

    test('round-trips a map', () async {
      final data = {
        'height': 3000000,
        'txCount': 4,
        'nested': {'a': 'b'},
      };
      await WalletCacheStore.save('XMR', data, _password);
      expect(await WalletCacheStore.load('XMR', _password), data);
    });

    test('is namespaced per coin', () async {
      await WalletCacheStore.save('XMR', {'a': 1}, _password);
      await WalletCacheStore.save('BTC', {'a': 2}, _password);
      expect((await WalletCacheStore.load('XMR', _password))['a'], 1);
      expect((await WalletCacheStore.load('BTC', _password))['a'], 2);
    });

    test('the coin symbol is case-insensitive on disk', () async {
      await WalletCacheStore.save('XMR', {'a': 1}, _password);
      expect(await WalletCacheStore.load('xmr', _password), {'a': 1});
    });

    group('degrades to empty rather than throwing', () {
      // The cache is derived data. Any failure to read it must mean "re-sync",
      // never an exception into a caller that is just showing a balance.
      test('wrong password', () async {
        await WalletCacheStore.save('XMR', {'a': 1}, _password);
        expect(await WalletCacheStore.load('XMR', 'wrong'), isEmpty);
      });

      test('truncated file', () async {
        await WalletCacheStore.save('XMR', {'a': 1}, _password);
        final f = File('${tmp.path}/xmr_cache');
        final blob = await f.readAsString();
        await f.writeAsString(blob.substring(0, blob.length ~/ 2));
        expect(await WalletCacheStore.load('XMR', _password), isEmpty);
      });

      test('not an envelope at all', () async {
        await File('${tmp.path}/xmr_cache').writeAsString('just some text');
        expect(await WalletCacheStore.load('XMR', _password), isEmpty);
      });

      test('empty file', () async {
        await File('${tmp.path}/xmr_cache').writeAsString('');
        expect(await WalletCacheStore.load('XMR', _password), isEmpty);
      });
    });

    test('delete removes only that coin', () async {
      await WalletCacheStore.save('XMR', {'a': 1}, _password);
      await WalletCacheStore.save('BTC', {'a': 2}, _password);
      await WalletCacheStore.delete('XMR');
      expect(await WalletCacheStore.load('XMR', _password), isEmpty);
      expect(await WalletCacheStore.load('BTC', _password), {'a': 2});
    });

    test('a cached tx history survives the store', () async {
      final tx = TxDetails(
        index: 0,
        direction: 1,
        hash: 'h',
        amountBaseUnits: BigInt.parse('18446744073709551615'),
        feeBaseUnits: BigInt.from(10),
        recipients: const [],
        accountIndex: 0,
        subaddrIndexList: const [],
        timestamp: 1,
        height: 2,
        confirmations: 3,
        key: 'k',
      );
      await WalletCacheStore.save('XMR', {
        'txHistory': jsonEncode([tx.toJson()]),
      }, _password);

      final cached = await WalletCacheStore.load('XMR', _password);
      final parsed = parseCachedTxHistory(cached['txHistory'] as String);
      expect(parsed.single.amountBaseUnits, BigInt.parse('18446744073709551615'));
    });
  });
}
