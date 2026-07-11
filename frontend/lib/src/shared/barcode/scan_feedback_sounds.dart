import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'scan_feedback_sounds_stub.dart'
    if (dart.library.io) 'scan_feedback_sounds_io.dart' as impl;

/// Audible outcome of a barcode action, mirroring [BarcodeScanStatus]-style
/// resolution results wherever a scan is resolved:
/// - [success]: the code resolved to a product and it was added.
/// - [notFound]: the lookup worked but no product carries this code.
/// - [error]: the code could not be looked up at all (unreadable/rejected
///   code or a failed request) — neither an add nor a clean miss.
enum ScanFeedback { success, notFound, error }

/// Signature the view models take so tests can record feedback without audio.
typedef ScanFeedbackPlayer = void Function(ScanFeedback feedback);

/// Plays the short feedback chimes for barcode actions on the POS and
/// purchasing screens.
///
/// compat/win8: audioplayers' Windows backend needs mfmediaengine.dll, which
/// does not exist on Windows 7 — the import alone would keep the till from
/// starting. This build plays the bundled WAVs through winmm.dll PlaySound
/// (present on every Windows) instead; non-Windows platforms are silent.
///
/// Sound is reinforcement, never a gate: every failure here is swallowed so a
/// till without audio still scans exactly as before.
class ScanFeedbackSounds {
  ScanFeedbackSounds._();

  static final ScanFeedbackSounds instance = ScanFeedbackSounds._();

  static const Map<ScanFeedback, String> _assets = {
    ScanFeedback.success: 'assets/sounds/success.wav',
    ScanFeedback.notFound: 'assets/sounds/not-found.wav',
    ScanFeedback.error: 'assets/sounds/error.wav',
  };

  /// True under `flutter test`, where no audio backend exists.
  static bool get _isUnderTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  /// Fire-and-forget: never awaited by scan flows and never throws.
  void play(ScanFeedback feedback) {
    if (_isUnderTest) {
      return;
    }
    unawaited(_play(feedback));
  }

  Future<void> _play(ScanFeedback feedback) async {
    try {
      await impl.playAsset(_assets[feedback]!);
    } catch (error) {
      debugPrint('scan feedback sound failed: $error');
    }
  }
}
