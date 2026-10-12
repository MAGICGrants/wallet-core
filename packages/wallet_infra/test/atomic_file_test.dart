import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('atomic_file'));
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> leftovers() =>
      tmp.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')).toList();

  test('writes a new file and replaces an existing one', () async {
    final file = File('${tmp.path}/wallet');
    await writeStringAtomic(file, 'first');
    expect(file.readAsStringSync(), 'first');
    await writeStringAtomic(file, 'second');
    expect(file.readAsStringSync(), 'second');
    expect(leftovers(), isEmpty);
  });

  test('writes of one file at once each land whole, and the last one wins', () async {
    final file = File('${tmp.path}/wallet');
    final contents = [for (var i = 0; i < 20; i++) 'version $i ' * 2000];
    await Future.wait([for (final c in contents) writeStringAtomic(file, c)]);
    expect(contents, contains(file.readAsStringSync()));
    expect(leftovers(), isEmpty);
  });

  test('a failed rename leaves the target as it was and no temporary file', () async {
    // A directory where the file should go: the rename fails.
    final target = Directory('${tmp.path}/wallet')..createSync();
    File('${target.path}/inside').writeAsStringSync('kept');
    await expectLater(
      writeStringAtomic(File(target.path), 'new'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File('${target.path}/inside').readAsStringSync(), 'kept');
    expect(leftovers(), isEmpty);
  });
}
