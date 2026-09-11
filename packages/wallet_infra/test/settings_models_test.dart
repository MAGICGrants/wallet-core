import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Completes once [m] fires its first notification (the async load).
Future<void> whenNotified(ChangeNotifier m) {
  final c = Completer<void>();
  m.addListener(() {
    if (!c.isCompleted) c.complete();
  });
  return c.future.timeout(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferencesService.store = MemoryPreferenceStore());
  tearDown(SharedPreferencesService.resetForTesting);

  group('ThemeModel', () {
    test('defaults to system', () {
      expect(ThemeModel().theme, 'system');
    });

    test('loads a stored theme', () async {
      await SharedPreferencesService.set<String>(SettingsKeys.theme, 'dark');
      final model = ThemeModel();
      await whenNotified(model);
      expect(model.theme, 'dark');
    });

    test('setTheme updates state and persists', () async {
      final model = ThemeModel();
      model.setTheme('light');
      expect(model.theme, 'light');
      await Future<void>.delayed(Duration.zero);
      expect(await SharedPreferencesService.get<String>(SettingsKeys.theme), 'light');
    });

    test('setTheme ignores null', () {
      final model = ThemeModel();
      model.setTheme(null);
      expect(model.theme, 'system');
    });
  });

  group('LanguageModel', () {
    test('loads a stored language', () async {
      await SharedPreferencesService.set<String>(SettingsKeys.language, 'pt');
      final model = LanguageModel();
      await whenNotified(model);
      expect(model.language, 'pt');
    });

    test('setLanguage updates state and persists', () async {
      final model = LanguageModel();
      model.setLanguage('en');
      expect(model.language, 'en');
      await Future<void>.delayed(Duration.zero);
      expect(await SharedPreferencesService.get<String>(SettingsKeys.language), 'en');
    });

    test('setLanguage notifies synchronously, without waiting on the write', () {
      final model = LanguageModel();
      var notified = false;
      model.addListener(() => notified = true);

      model.setLanguage('pt');

      expect(notified, isTrue, reason: 'listeners must fire before the persist await');
      expect(model.language, 'pt');
    });
  });
}
