import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The customer's own choices for this phone: the language, light or dark,
/// and whether saved codes sit behind Face ID. Kept on the device, read once
/// before the first frame so the app never opens in the wrong language and
/// then flips.
class AppSettings extends ChangeNotifier {
  AppSettings({this.preferences});

  /// Where the choices are kept; none in tests and previews.
  final SharedPreferencesAsync? preferences;

  /// The languages the app speaks, in the order the picker shows them.
  static const List<String> languages = ['ar', 'en', 'fr'];

  /// Whether the customer may choose the language. Off for now: the app's
  /// own words are translated, but the catalog (brands, values, how-to
  /// hints) and the payment methods still come from the relay in Arabic
  /// only, so an English or French app would be half Arabic. While it is
  /// off the app is Arabic, whatever an earlier build saved.
  static const bool languageChoice = false;

  static const _languageKey = 'settings.language';
  static const _themeKey = 'settings.theme';
  static const _lockKey = 'settings.code_lock';

  String _language = 'ar';
  ThemeMode _themeMode = ThemeMode.system;
  bool _codeLock = true;

  /// Arabic unless the customer chose otherwise: the app is Arabic first.
  String get language => _language;
  Locale get locale => Locale(languageChoice ? _language : 'ar');
  ThemeMode get themeMode => _themeMode;

  /// Face ID (or the fingerprint) before saved codes are shown. On by
  /// default: they are money.
  bool get codeLock => _codeLock;

  Future<void> load() async {
    final preferences = this.preferences;
    if (preferences == null) {
      return;
    }
    try {
      final language = await preferences.getString(_languageKey);
      final theme = await preferences.getString(_themeKey);
      final lock = await preferences.getBool(_lockKey);
      if (languages.contains(language)) {
        _language = language!;
      }
      _themeMode =
          ThemeMode.values.where((mode) => mode.name == theme).firstOrNull ??
          ThemeMode.system;
      _codeLock = lock ?? true;
    } on Object {
      // Unreadable choices fall back to the defaults; the app still opens.
    }
    notifyListeners();
  }

  void setLanguage(String language) {
    if (!languages.contains(language) || language == _language) {
      return;
    }
    _language = language;
    notifyListeners();
    _save(() => preferences?.setString(_languageKey, language));
  }

  void setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) {
      return;
    }
    _themeMode = mode;
    notifyListeners();
    _save(() => preferences?.setString(_themeKey, mode.name));
  }

  void setCodeLock(bool on) {
    if (on == _codeLock) {
      return;
    }
    _codeLock = on;
    notifyListeners();
    _save(() => preferences?.setBool(_lockKey, on));
  }

  /// A choice that cannot be written still holds for this session.
  void _save(Future<void>? Function() write) {
    write()?.catchError((Object _) {});
  }
}
