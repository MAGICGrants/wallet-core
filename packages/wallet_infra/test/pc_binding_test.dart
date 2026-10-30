import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The files a typed password protects are bound to the PC's TPM where there
/// is one (Windows). These run against a fake TPM.
void main() {
  late Directory tmp;
  late FakeMachineKeys tpm;
  const typed = 'correct horse battery staple';

  File record() => File('${tmp.path}/${PcBinding.fileName}');

  List<String> recordedKeys() => [
    for (final b in (jsonDecode(record().readAsStringSync()) as Map)['bindings'] as List)
      (b as Map)['key'] as String,
  ];

  /// Writes a file the way the stores do, and returns its password.
  Future<PcWrite> writeFile() async {
    final target = await PcBinding.forWrite(typed);
    await target.write(() async {});
    return target;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pc_binding');
    WalletPaths.install(
      linuxDirName: '.test_wallet',
      windowsAppDataDir: 'MAGIC Grants/Test Wallet',
      directories: FixedDirectories(tmp),
    );
    PcBinding.keys = tpm = FakeMachineKeys();
  });

  tearDown(() {
    PcBinding.endSession();
    PcBinding.keys = const NoMachineKeys();
    WalletPaths.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('with no TPM nothing is bound: the typed password alone, and no record', () async {
    PcBinding.keys = const NoMachineKeys();
    final target = await writeFile();
    expect(target.bound, isFalse);
    expect(target.password, typed);
    expect(record().existsSync(), isFalse);

    final candidates = await PcBinding.passwordsFor(typed);
    expect(candidates.passwords, [typed]);
    expect(candidates.unavailable, isFalse);
  });

  test('with a TPM the password carries its secret, and opens only with it', () async {
    final target = await writeFile();
    expect(target.bound, isTrue);
    expect(target.password, isNot(typed));
    expect(target.password, endsWith(typed));
    expect(recordedKeys(), hasLength(1));

    final candidates = await PcBinding.passwordsFor(typed);
    expect(candidates.passwords, [target.password, typed]);
    expect(candidates.isBound(0), isTrue);
    expect(candidates.isBound(1), isFalse);
    expect(candidates.unavailable, isFalse);
  });

  test('the same binding serves the next file, and a session signs once', () async {
    final first = await writeFile();
    final signs = tpm.signs;
    final second = await writeFile();
    expect(second.password, first.password);
    expect(tpm.names, hasLength(1));
    expect(tpm.signs, signs, reason: 'the secret is kept for the session');

    PcBinding.endSession();
    expect((await PcBinding.passwordsFor(typed)).passwords.first, first.password);
    expect(tpm.signs, signs + 1, reason: 'after a full lock the TPM is asked again');
  });

  test('on another PC, or with the TPM cleared, the binding is unavailable', () async {
    await writeFile();
    PcBinding.endSession();
    tpm.forgetAll();
    final candidates = await PcBinding.passwordsFor(typed);
    expect(candidates.passwords, [typed], reason: 'only an unbound file could still open');
    expect(candidates.unavailable, isTrue);
  });

  test('a different key under the same name is told from the right one', () async {
    await writeFile();
    PcBinding.endSession();
    tpm.replace(tpm.names.single);
    final candidates = await PcBinding.passwordsFor(typed);
    expect(candidates.passwords, [typed]);
    expect(candidates.unavailable, isTrue);
  });

  test('a TPM that does not answer is unavailable, not a wrong password', () async {
    await writeFile();
    PcBinding.endSession();
    tpm.failing = true;
    expect((await PcBinding.passwordsFor(typed)).unavailable, isTrue);
  });

  test('a TPM that fails while making a key leaves the file unbound', () async {
    tpm.failing = true;
    final target = await writeFile();
    expect(target.bound, isFalse);
    expect(target.password, typed);
    expect(record().existsSync(), isFalse);
  });

  test('a new binding is on record before its file is written, the old one after', () async {
    final old = await writeFile();
    final oldKey = recordedKeys().single;
    PcBinding.endSession();
    tpm.forgetAll(); // The old binding can no longer be produced.

    final target = await PcBinding.forWrite(typed);
    expect(target.bound, isTrue);
    expect(target.password, isNot(old.password));
    List<String>? duringWrite;
    await target.write(() async => duringWrite = recordedKeys());
    expect(duringWrite, hasLength(2), reason: 'a write cut short still finds both');
    expect(duringWrite!.last, oldKey);
    expect(recordedKeys(), [duringWrite!.first], reason: 'the replaced one is dropped');
  });

  test('deleting the record forgets the binding', () async {
    await writeFile();
    await PcBinding.deleteRecord();
    expect(record().existsSync(), isFalse);
    expect((await PcBinding.passwordsFor(typed)).passwords, [typed]);
  });

  test('a damaged record is read as none', () async {
    record().writeAsStringSync('{not json');
    final candidates = await PcBinding.passwordsFor(typed);
    expect(candidates.passwords, [typed]);
    expect(candidates.unavailable, isFalse);
  });
}
