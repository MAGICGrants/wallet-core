// Builds fhse_native's C library for the host, into build/host, for the tests
// (test/README.md). The sources are the fhse_native package pub resolved, so
// the tests run the same commit the apps ship.
//
//   dart run tool/build_host_library.dart [extra CMake configure arguments]
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  final lib = await Isolate.resolvePackageUri(Uri.parse('package:fhse_native/'));
  if (lib == null) {
    stderr.writeln('fhse_native is not resolved; run `flutter pub get` first');
    exit(1);
  }
  final src = lib.resolve('../src/').toFilePath();
  await _run('cmake', ['-S', src, '-B', 'build/host', '-DCMAKE_BUILD_TYPE=Release', ...args]);
  await _run('cmake', ['--build', 'build/host', '-j${Platform.numberOfProcessors}']);
}

Future<void> _run(String executable, List<String> arguments) async {
  final process = await Process.start(executable, arguments, mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) exit(code);
}
