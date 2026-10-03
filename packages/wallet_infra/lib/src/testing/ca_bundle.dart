import 'dart:convert';
import 'dart:typed_data';

import '../net/cacert.dart';
import 'test_pki.dart';

/// Makes [CaBundle] serve [pem] instead of the packaged Mozilla set: a test
/// root a test server chains to, or simply something a test without a Flutter
/// binding (which cannot load assets) can load. Undo with
/// [CaBundle.resetForTesting].
void useTestCaBundle([String pem = TestPki.rootCa]) {
  CaBundle.resetForTesting();
  CaBundle.load = () async => Uint8List.fromList(utf8.encode(pem));
}
