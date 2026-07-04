import 'package:flutter_tts/flutter_tts.dart';

/// Speaks the found product aloud on the price-checker kiosk (name + price).
///
/// Deliberately defensive: TTS depends on an on-device voice for the language,
/// and some desktop platforms have no engine at all. Every call is guarded so a
/// missing engine or absent Arabic voice simply produces no sound — never an
/// error the kiosk has to handle. First use lazily initialises the engine so a
/// kiosk that never finds a product pays nothing.
class KioskSpeechService {
  KioskSpeechService({String language = 'ar'}) : _language = language;

  final String _language;
  FlutterTts? _tts;
  bool _initFailed = false;

  Future<void> _ensureReady() async {
    if (_tts != null || _initFailed) {
      return;
    }
    try {
      final tts = FlutterTts();
      await tts.setLanguage(_language);
      // flutter_tts maps 0.5 to a natural, intelligible pace on Android; the
      // platform default (1.0) is noticeably rushed for shoppers.
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1.0);
      _tts = tts;
    } catch (_) {
      // No engine on this platform — mark it so we don't keep retrying.
      _initFailed = true;
    }
  }

  /// Speaks [text], interrupting anything already being spoken (a fresh scan
  /// should not wait behind the previous product). Fire-and-forget.
  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    await _ensureReady();
    final tts = _tts;
    if (tts == null) {
      return;
    }
    try {
      await tts.stop();
      await tts.speak(trimmed);
    } catch (_) {
      // Voice for the language not installed, engine busy, etc. — stay silent.
    }
  }

  Future<void> dispose() async {
    try {
      await _tts?.stop();
    } catch (_) {
      // Nothing to clean up if the engine never started.
    }
  }
}
