import 'package:flutter/foundation.dart';

import '../storage/preferences.dart';

/// The app's language preference (a locale code), defaulting to the device
/// locale, persisted and exposed as [ChangeNotifier] state.
class LanguageModel with ChangeNotifier {
  String _language = PlatformDispatcher.instance.locale.languageCode;

  String get language => _language;

  LanguageModel() {
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final preferencesLanguage = await SharedPreferencesService.get<String>(SettingsKeys.language);
    if (preferencesLanguage != null) {
      _language = preferencesLanguage;
      notifyListeners();
    }
  }

  void setLanguage(String? newLanguage) async {
    if (newLanguage == null) return;
    _language = newLanguage;
    notifyListeners();
    await SharedPreferencesService.set<String>(SettingsKeys.language, newLanguage);
  }
}
