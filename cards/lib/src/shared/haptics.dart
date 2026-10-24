import 'package:flutter/services.dart';

/// The app's haptic vocabulary: one meaning, one feel, everywhere. Screens
/// say what happened; this decides how it feels. On iPhone the last three
/// are the system's own success, warning and error patterns, the ones Apple
/// Pay and Face ID use, so they read without being learnt.
abstract final class Haptics {
  /// Moving between choices: tabs, chips, filters, the stepper, pages.
  static void select() => HapticFeedback.selectionClick();

  /// A button that starts something: buy, pay, copy.
  static void tap() => HapticFeedback.lightImpact();

  /// It worked: signed in, paid, the card is here.
  static void success() => HapticFeedback.successNotification();

  /// Worth a look, nothing lost: money back in credit, a payment that did
  /// not go through, one under review, a step that cannot be undone, a
  /// connection that dropped.
  static void warning() => HapticFeedback.warningNotification();

  /// Refused: a wrong code, a declined payment.
  static void error() => HapticFeedback.errorNotification();
}
