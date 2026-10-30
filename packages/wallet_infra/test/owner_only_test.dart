import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Linux keeps the wallet's folder to its owner: `0700` folders, `0600` files,
/// and a umask that keeps it so for whatever is written later. The same libc
/// calls exist on macOS, where these tests run as well.
void main() {
  late Directory tmp;
  late int previousUmask;

  int mode(String path) => FileStat.statSync(path).mode & 0x1FF;

  void setMode(String path, String octal) => Process.runSync('chmod', [octal, path]);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('owner_only');
    previousUmask = setUmask(0x12); // 022, the usual default
  });

  tearDown(() {
    setUmask(previousUmask);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('tightens what an earlier build left readable to others', () {
    final dir = Directory('${tmp.path}/.test_wallet')..createSync();
    final key = File('${dir.path}/wallet.key')..writeAsStringSync('k');
    final sub = Directory('${dir.path}/metadata_backup')..createSync();
    final inner = File('${sub.path}/state')..writeAsStringSync('s');
    for (final path in [dir.path, sub.path]) {
      setMode(path, '755');
    }
    for (final path in [key.path, inner.path]) {
      setMode(path, '644');
    }

    expect(restrictToOwner(dir), isTrue);
    expect(mode(dir.path), ownerOnlyDirMode);
    expect(mode(sub.path), ownerOnlyDirMode);
    expect(mode(key.path), ownerOnlyFileMode);
    expect(mode(inner.path), ownerOnlyFileMode);
  });

  test('from then on, new files and folders are the owner\'s only', () {
    final dir = Directory('${tmp.path}/.test_wallet')..createSync();
    restrictToOwner(dir);

    final file = File('${dir.path}/wallet.fhse')..writeAsStringSync('new');
    final sub = Directory('${dir.path}/tor_data')..createSync();
    expect(mode(file.path), ownerOnlyFileMode);
    expect(mode(sub.path), ownerOnlyDirMode);
  });

  test('a link is left alone, and so is what it points to', () {
    final outside = File('${tmp.path}/outside')..writeAsStringSync('mine');
    setMode(outside.path, '644');
    final dir = Directory('${tmp.path}/.test_wallet')..createSync();
    Link('${dir.path}/link').createSync(outside.path);

    expect(restrictToOwner(dir), isTrue);
    expect(mode(outside.path), 0x1A4); // 0644, untouched
  });

  test('a folder that is not there is reported, not thrown', () {
    expect(restrictToOwner(Directory('${tmp.path}/missing')), isFalse);
  });
}
