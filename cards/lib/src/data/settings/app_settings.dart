import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The customer's own choices for this phone: the language, light or dark,
/// whether saved codes sit behind Face ID, and whether the first-run steps
/// were seen. Kept on the device, read once
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
  static const _onboardedKey = 'settings.onboarded';
  static const _usageKey = 'settings.share_usage';

  String _language = 'ar';
  ThemeMode _themeMode = ThemeMode.system;
  bool _codeLock = true;
  bool _shareUsage = true;

  /// Without storage (tests, previews) there is no first run to show.
  late bool _onboarded = preferences == null;

  /// Arabic unless the customer chose otherwise: the app is Arabic first.
  String get language => _language;
  Locale get locale => Locale(languageChoice ? _language : 'ar');
  ThemeMode get themeMode => _themeMode;

  /// Face ID (or the fingerprint) before saved codes are shown. On by
  /// default: they are money.
  bool get codeLock => _codeLock;

  /// Whether usage is shared with product analytics (PostHog): what is
  /// opened and tapped, and masked screen recordings. On unless the
  /// customer turns it off, as the privacy policy says.
  bool get shareUsage => _shareUsage;

  /// Whether the first-run steps were seen (or skipped) on this phone.
  bool get onboarded => _onboarded;

  Future<void> load() async {
    final preferences = this.preferences;
    if (preferences == null) {
      return;
    }
    try {
      final language = await preferences.getString(_languageKey);
      final theme = await preferences.getString(_themeKey);
      final lock = await preferences.getBool(_lockKey);
      final onboarded = await preferences.getBool(_onboardedKey);
      final usage = await preferences.getBool(_usageKey);
      if (languages.contains(language)) {
        _language = language!;
      }
      _themeMode =
          ThemeMode.values.where((mode) => mode.name == theme).firstOrNull ??
          ThemeMode.system;
      _codeLock = lock ?? true;
      _onboarded = onboarded ?? false;
      _shareUsage = usage ?? true;
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

  void setShareUsage(bool on) {
    if (on == _shareUsage) {
      return;
    }
    _shareUsage = on;
    notifyListeners();
    _save(() => preferences?.setBool(_usageKey, on));
  }

  void markOnboarded() {
    if (_onboarded) {
      return;
    }
    _onboarded = true;
    _save(() => preferences?.setBool(_onboardedKey, true));
  }

  /// A choice that cannot be written still holds for this session.
  void _save(Future<void>? Function() write) {
    write()?.catchError((Object _) {});
  }
}
