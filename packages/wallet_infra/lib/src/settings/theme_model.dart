import 'package:flutter/foundation.dart';

import '../storage/preferences.dart';

/// The app's theme preference, `'system' | 'light' | 'dark'`, persisted and
/// exposed as [ChangeNotifier] state. Material-free on purpose: the app maps the
/// string to a `ThemeMode` itself, so this stays out of the widget layer.
class ThemeModel with ChangeNotifier {
  String _theme = 'system';

  String get theme => _theme;

  ThemeModel() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final preferencesTheme = await SharedPreferencesService.get<String>(SettingsKeys.theme);
    if (preferencesTheme != null) _theme = preferencesTheme;
    notifyListeners();
  }

  void setTheme(String? newTheme) async {
    if (newTheme == null) return;
    _theme = newTheme;
    await SharedPreferencesService.set<String>(SettingsKeys.theme, newTheme);
    notifyListeners();
  }
}
