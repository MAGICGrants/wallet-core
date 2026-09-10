import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// What is actually readable on disk.
///
/// Every other store test asks "does it round-trip?" and "does a bad file
/// degrade rather than throw?". Neither question can fail if the data is
/// written in the clear next to the ciphertext, or written twice, or written
/// somewhere else as well; a round trip only proves the reader and the writer
/// agree.
///
/// So this file asserts the negative: after a save, the secret does not appear
/// **in the bytes**. It is the only tier that would notice a debug sidecar, a
/// plaintext index, a cache that stopped being encrypted, or a store quietly
/// pointed at shared preferences. This is the receipt for that rule.

const _password = 'correct horse battery staple';

/// A distinctive phrase, so a match in a file is unambiguous rather than a
/// coincidence of short hex.
const _mnemonic =
    'zebra vault crimson lantern pepper glacier orbit tulip '
    'meadow falcon quartz ribbon';
const _passphrase = 'salted-passphrase-marker';

/// Everything the wallet layer writes lives under this directory, so scanning
/// it catches a file nobody thought to look for.
Future<List<int>> _allBytesUnder(Directory dir) async {
  final out = <int>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) out.addAll(await entity.readAsBytes());
  }
  return out;
}

/// True when [needle] appears in [haystack] either as raw bytes or inside a
/// base64 region of it; the stores write base64, so a plaintext leak could be
/// hiding one decode away.
bool _leaks(List<int> haystack, String needle) {
  final raw = utf8.decode(haystack, allowMalformed: true);
  if (raw.contains(needle)) return true;

  // Anything base64-shaped in the file, decoded and searched too.
  for (final match in RegExp(r'[A-Za-z0-9+/=]{16,}').allMatches(raw)) {
    try {
      final decoded = base64.decode(
        match.group(0)!.padRight((match.group(0)!.length + 3) ~/ 4 * 4, '='),
      );
      if (utf8.decode(decoded, allowMalformed: true).contains(needle)) return true;
    } catch (_) {
      // Not base64 after all.
    }
  }
  return false;
}

void main() {
  late Directory tmp;
  late MemoryPreferenceStore prefs;
  late MemorySecretStore secrets;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('at_rest');
    prefs = MemoryPreferenceStore();
    SharedPreferencesService.store = prefs;
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  });

  tearDown(() {
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the seed', () {
    setUp(
      () => SeedStore.save(
        seed: const Bip39Seed(_mnemonic, passphrase: _passphrase),
        from: RestorePoint.date(DateTime.utc(2026, 3, 14)),
        password: _password,
      ),
    );

    test('no word of it is anywhere under the app directory', () async {
      final bytes = await _allBytesUnder(tmp);

      expect(_leaks(bytes, _mnemonic), isFalse, reason: 'the whole phrase');
      for (final word in _mnemonic.split(' ')) {
        // Individually, because a partial write or a debug dump would show up
        // one word at a time rather than as the joined phrase.
        expect(_leaks(bytes, word), isFalse, reason: 'the word "$word"');
      }
    });

    test('the passphrase is not there either', () async {
      expect(_leaks(await _allBytesUnder(tmp), _passphrase), isFalse);
    });

    test('the file is the envelope it claims to be, not something else', () async {
      final blob = await File('${tmp.path}/master_seed').readAsString();
      expect(WalletFileCrypto.isValidEncryptedBlobBase64(blob), isTrue);
      // 'SKLW'
      expect(base64.decode(blob.trim()).take(4), [0x53, 0x4B, 0x4C, 0x57]);
    });

    test('saving the same seed twice produces different bytes', () async {
      final first = await File('${tmp.path}/master_seed').readAsBytes();
      await SeedStore.save(
        seed: const Bip39Seed(_mnemonic, passphrase: _passphrase),
        from: RestorePoint.date(DateTime.utc(2026, 3, 14)),
        password: _password,
      );
      final second = await File('${tmp.path}/master_seed').readAsBytes();

      // A fresh salt and IV each time. Identical bytes would mean the file is a
      // deterministic function of the seed, so an observer with a candidate
      // phrase could confirm it by re-encrypting rather than by decrypting.
      expect(second, isNot(first));
    });

    test('it round-trips, so the negatives above are not passing on an empty file', () async {
      final loaded = await SeedStore.load(_password);
      expect(loaded!.seed.mnemonic, _mnemonic);
      expect(loaded.seed.passphrase, _passphrase);
    });
  });

  group('the wallet cache', () {
    const txid = 'f00dbabe0000000000000000000000000000000000000000000000000000cafe';
    const balance = '1337000000000';

    setUp(
      () => WalletCacheStore.save('XMR', {
        'cachedTotalBalanceUnits': balance,
        'cachedTxHistory': jsonEncode([
          {'hash': txid, 'amount': balance},
        ]),
      }, _password),
    );

    test('neither the balance nor the txid is readable', () async {
      final bytes = await _allBytesUnder(tmp);
      expect(_leaks(bytes, txid), isFalse, reason: 'transaction id');
      expect(_leaks(bytes, balance), isFalse, reason: 'balance');
    });

    test('nor does either reach shared preferences or the keystore', () async {
      // Different stores, different protection. The cache being encrypted is
      // no help if the same value is also sitting in a prefs file.
      final elsewhere = [
        ...prefs.values.values.map((v) => v.toString()),
        ...secrets.values.values,
      ].join('\n');
      expect(elsewhere, isNot(contains(txid)));
      expect(elsewhere, isNot(contains(balance)));
    });

    test('it round-trips', () async {
      final loaded = await WalletCacheStore.load('XMR', _password);
      expect(loaded['cachedTotalBalanceUnits'], balance);
    });
  });

  group('the scan itself is honest', () {
    test('a plaintext file under the app directory would be caught', () async {
      // The negatives above are only worth anything if the scanner can find a
      // leak. This is the control: write the secret in the clear and confirm
      // the same check fails.
      await File('${tmp.path}/oops.log').writeAsString('seed: $_mnemonic');

      expect(_leaks(await _allBytesUnder(tmp), _mnemonic), isTrue);
    });

    test('and so would one hidden inside base64', () async {
      await File('${tmp.path}/oops.b64').writeAsString(base64.encode(utf8.encode(_mnemonic)));

      expect(_leaks(await _allBytesUnder(tmp), _mnemonic), isTrue);
    });
  });
}
