import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/hmac_parity.dart';
import 'package:wallet_fhse/wallet_fhse.dart';

/// The hmac-secret parity tool: the Dart side (HmacParity and its screen)
/// against a stand-in key, and tool/hmac_parity.sh against stand-ins for
/// libfido2's tools. The readings themselves come from real keys; see
/// test/README.md.

/// A key that answers with a fixed function of (credential, salt) and records
/// what it was asked. Pure Dart, so these tests need no host build of `src/`.
class _ParityKey implements SecurityKeyAuthenticator {
  static const pin = '123456';
  final salts = <Uint8List>[];
  final credentialIdsAsked = <List<Uint8List>>[];
  var _next = 1;

  static Uint8List _output(Uint8List credentialId, Uint8List salt) => Uint8List.fromList([
    for (var i = 0; i < 32; i++) salt[i] ^ credentialId[i % credentialId.length],
  ]);

  void _verify(KeyVerification verification) {
    if (!verification.isBuiltIn && !verification.isSystem && verification.pin != pin) {
      throw const SecurityKeyException(SecurityKeyFailure.pinInvalid, message: 'wrong PIN');
    }
  }

  @override
  Future<KeyAssertion> enroll({
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
  }) async {
    _verify(verification);
    salts.add(salt);
    expect(userId, hasLength(64));
    final id = Uint8List.fromList(List.filled(48, _next++));
    return KeyAssertion(credentialId: id, hmacSecret: _output(id, salt));
  }

  @override
  Future<KeyAssertion> getHmacSecret({
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
  }) async {
    _verify(verification);
    salts.add(salt);
    credentialIdsAsked.add(credentialIds);
    final id = credentialIds.single;
    return KeyAssertion(credentialId: id, hmacSecret: _output(id, salt));
  }
}

String _hmacLine(String report) =>
    report.split('\n').firstWhere((l) => l.startsWith('hmac-secret: '));

void main() {
  group('HmacParity', () {
    test('the salt is 32 bytes and the script has the same one', () {
      expect(HmacParity.salt, hasLength(32));
      final script = File('tool/hmac_parity.sh').readAsStringSync();
      expect(
        RegExp(r"^SALT_B64='([^']+)'$", multiLine: true).firstMatch(script)!.group(1),
        HmacParity.saltBase64,
      );
      expect(
        RegExp(r"^SALT_LABEL='([^']+)'$", multiLine: true).firstMatch(script)!.group(1),
        HmacParity.saltLabel,
      );
      expect(
        RegExp(r"^RP_ID='([^']+)'$", multiLine: true).firstMatch(script)!.group(1),
        SecurityKeyService.rpId,
      );
    });

    test('enrolls and reads over the parity salt, never another', () async {
      final key = _ParityKey();
      final parity = HmacParity(key);
      const pin = KeyVerification.pin('123456');

      final enrolled = await parity.enroll(pin);
      final again = await parity.assertCredential(enrolled.credentialId, pin);

      expect(key.salts, [HmacParity.salt, HmacParity.salt]);
      expect(key.credentialIdsAsked.single, [enrolled.credentialId]);
      expect(again.hmacSecret, enrolled.hmacSecret);
      expect(again.credentialId, enrolled.credentialId);
    });

    test('reports in the script\'s line format', () {
      final result = HmacParityResult(
        credentialId: Uint8List.fromList([1, 2, 3]),
        hmacSecret: Uint8List.fromList(List.filled(32, 0xab)),
      );
      expect(result.report(backend: 'test').split('\n'), [
        'backend: test',
        'rp: fhse:encryption',
        'salt: ${HmacParity.saltBase64}',
        'credential: AQID',
        'hmac-secret: ${base64Encode(List.filled(32, 0xab))}',
      ]);
      expect(result.libfido2Command, "sh tool/hmac_parity.sh assert 'AQID'");
    });

    test('parses credential ids as base64 (any form) or hex', () {
      final bytes = Uint8List.fromList([0xfb, 0xff, 0x01, 0x02, 0x03]);
      expect(HmacParity.parseCredentialId(base64Encode(bytes)), bytes); // +/8BAgM=
      expect(HmacParity.parseCredentialId(' -_8BAgM \n'), bytes); // URL-safe, unpadded
      expect(HmacParity.parseCredentialId('fbff010203'), bytes);
      expect(HmacParity.parseCredentialId('FB FF 01 02 03'), bytes);
      expect(HmacParity.parseCredentialId(''), isNull);
      expect(HmacParity.parseCredentialId('not base64!'), isNull);
    });
  });

  group('HmacParityScreen', () {
    Future<void> pump(WidgetTester tester, _ParityKey key, {bool systemPrompts = false}) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: HmacParityScreen(
            authenticator: key,
            systemPrompts: systemPrompts,
            status: const Stream.empty(),
          ),
        ),
      );
    }

    testWidgets('creates a credential, then reads it again to the same output', (tester) async {
      final key = _ParityKey();
      await pump(tester, key);

      await tester.enterText(find.widgetWithText(TextField, 'Security key PIN'), '123456');
      await tester.tap(find.text('Create credential'));
      await tester.pumpAndSettle();

      final created = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      expect(created, contains('hmac-secret: '));
      expect(created, contains('sh tool/hmac_parity.sh assert'));

      // The credential field now holds the new credential; read it back.
      await tester.tap(find.text('Read credential'));
      await tester.pumpAndSettle();
      final read = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      expect(_hmacLine(read), _hmacLine(created));
      expect(key.salts, everyElement(HmacParity.salt));
    });

    testWidgets('shows the key\'s error and no result on a wrong PIN', (tester) async {
      await pump(tester, _ParityKey());
      await tester.enterText(find.widgetWithText(TextField, 'Security key PIN'), '000000');
      await tester.tap(find.text('Create credential'));
      await tester.pumpAndSettle();
      expect(find.textContaining('wrong PIN'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('asks for no PIN where the system prompts (Windows)', (tester) async {
      final key = _ParityKey();
      await pump(tester, key, systemPrompts: true);
      expect(find.widgetWithText(TextField, 'Security key PIN'), findsNothing);
      await tester.tap(find.text('Create credential'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
    });
  });

  group('tool/hmac_parity.sh', () {
    // Stand-ins for libfido2's tools: each records its arguments and input and
    // prints what a key would.
    final credentialId = base64Encode(List.generate(64, (i) => i));
    final hmac = base64Encode(List.filled(32, 0xab));
    const cdh = 'S/USLzRFVMU73i67jNK349FgCtYxw4Wl18ziPHeFRZo=';
    late Directory stubs;

    // CBOR-wrapped authenticator data, as fido2-assert prints it: a 37-byte
    // byte string (rpIdHash, flags, signCount).
    String authData(int flags) =>
        base64Encode([0x58, 37, ...List.filled(32, 0), flags, 0, 0, 0, 1]);

    void stub(String name, String body) {
      final file = File('${stubs.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', file.path]);
    }

    setUp(() {
      stubs = Directory.systemTemp.createTempSync('hmac_parity_stubs');
      stub('fido2-token', r'echo "/dev/hidraw7: vendor=0x1050, product=0x0407 (Yubico YubiKey)"');
      stub('fido2-cred', '''
case " \$* " in
  *" -V "*) echo "\$*" > "\$STUB_DIR/cred-verify.args"; cat > "\$STUB_DIR/cred-verify.in"; exit 0 ;;
esac
echo "\$*" > "\$STUB_DIR/cred.args"
cat > "\$STUB_DIR/cred.in"
printf '%s\\n' '$cdh' 'fhse:encryption' packed 'AAAA' '$credentialId' 'c2ln'
''');
      stub('fido2-assert', '''
echo "\$*" > "\$STUB_DIR/assert.args"
cat > "\$STUB_DIR/assert.in"
printf '%s\\n' '$cdh' 'fhse:encryption' "\$STUB_AUTHDATA" 'c2ln' "\$STUB_HMAC"
''');
    });

    tearDown(() => stubs.deleteSync(recursive: true));

    ProcessResult run(List<String> args, {int flags = 0x05, String? hmacOut}) => Process.runSync(
      'sh',
      ['tool/hmac_parity.sh', ...args],
      environment: {
        'PATH': '${stubs.path}:${Platform.environment['PATH']}',
        'STUB_DIR': stubs.path,
        'STUB_AUTHDATA': authData(flags),
        'STUB_HMAC': hmacOut ?? hmac,
      },
    );

    List<String> recorded(String name) =>
        File('${stubs.path}/$name').readAsStringSync().trimRight().split('\n');

    test('enroll: creates as FHSE does, then reads over the parity salt', () {
      final r = run(['enroll']);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      // No -v: it would ask for built-in UV before the PIN, which a key without
      // a fingerprint reader refuses.
      expect(recorded('cred.args').single, '-M -h -c 3 /dev/hidraw7 es256');
      expect(recorded('cred-verify.args').single, '-V -h -c 3 es256');
      final credIn = recorded('cred.in');
      expect(credIn.sublist(0, 3), [cdh, 'fhse:encryption', 'FHSE Encryption']);
      expect(base64Decode(credIn[3]), hasLength(64));

      expect(recorded('assert.args').single, '-G -h -v /dev/hidraw7');
      expect(recorded('assert.in'), [cdh, 'fhse:encryption', credentialId, HmacParity.saltBase64]);

      expect((r.stdout as String).trimRight().split('\n'), [
        'backend: libfido2 (fido2-assert)',
        'rp: fhse:encryption',
        'salt: ${HmacParity.saltBase64}',
        'credential: $credentialId',
        'hmac-secret: $hmac',
      ]);
    }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);

    test('assert: takes the app\'s credential in any base64 form, and a device', () {
      final urlSafe = credentialId.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      final r = run(['assert', urlSafe, '/dev/hidraw3']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(recorded('assert.args').single, '-G -h -v /dev/hidraw3');
      expect(recorded('assert.in')[2], credentialId);
      expect(r.stdout, contains('hmac-secret: $hmac'));
    }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);

    test('refuses an answer the key gave without verifying the user', () {
      final r = run(['assert', credentialId], flags: 0x01);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('did not verify the user'));
      expect(r.stdout, isNot(contains('hmac-secret:')));
    }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);

    test('refuses an hmac-secret that is not 32 bytes', () {
      final r = run(['assert', credentialId], hmacOut: base64Encode(List.filled(64, 1)));
      expect(r.exitCode, 1);
      expect(r.stderr, contains('not 32 bytes'));
    }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);

    test('prints usage on bad arguments', () {
      expect(run([]).exitCode, 2);
      expect(run(['assert']).exitCode, 2);
      expect(run(['bogus']).exitCode, 2);
    }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);
  });
}
