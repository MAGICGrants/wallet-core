import 'dart:async';
import 'dart:io';

/// The app's half of a capture handshake with a script on the host, which
/// takes each picture with the device's own tools (`simctl`, `adb`) so the
/// status bar is in it, as on a device. Makes it easier to take promotional
/// screenshots and recordings.
///
/// [capture] leaves a request in the app's temporary directory, which the host
/// reads through the simulator's data container or `adb shell run-as`, and
/// waits until the host answers that it has the picture in each theme asked
/// for.
class StoreShots {
  const StoreShots._();

  static Directory get _dir => Directory('${Directory.systemTemp.path}/store_shots');

  /// Asks the host to photograph what is on screen as [name], in the light
  /// theme, the dark one, or both. Leave the screen still until this returns.
  static Future<void> capture(
    String name, {
    bool light = true,
    bool dark = false,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final themes = [if (light) 'light', if (dark) 'dark'];
    if (themes.isEmpty) throw ArgumentError('No theme to take $name in');
    final dir = _dir..createSync(recursive: true);
    final done = File('${dir.path}/done');
    if (done.existsSync()) done.deleteSync();
    // Written whole, then moved into place, so the host never reads half of it.
    File('${dir.path}/request.tmp')
      ..writeAsStringSync('$name ${themes.join(',')}\n')
      ..renameSync('${dir.path}/request');
    final deadline = DateTime.now().add(timeout);
    while (!done.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('The host took no picture of $name', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    done.deleteSync();
  }
}
