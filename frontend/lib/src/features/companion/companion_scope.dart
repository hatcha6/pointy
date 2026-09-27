import 'package:flutter/widgets.dart';

import '../../data/repositories/companion_repository.dart';
import 'companion_bridge.dart';

/// Makes the companion camera reachable from any screen without threading it
/// through constructors.
///
/// Not for scanning: a phone's scans reach screens as keystrokes
/// (`ScanKeyboard`), so no screen looks the bridge up to hear them. The scope
/// is for the screens that manage the phone itself — pairing, its status, the
/// photo capture sheets — without a constructor parameter each. Screens and
/// tests that do not want it get `null` and behave exactly as before.
class CompanionScope extends InheritedWidget {
  const CompanionScope({
    super.key,
    required this.bridge,
    required this.repository,
    required super.child,
  });

  /// Null before sign-in, and in previews and tests.
  final CompanionBridge? bridge;
  final CompanionRepository? repository;

  static CompanionScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<CompanionScope>();
  }

  static CompanionBridge? bridgeOf(BuildContext context) {
    return maybeOf(context)?.bridge;
  }

  @override
  bool updateShouldNotify(CompanionScope oldWidget) {
    return bridge != oldWidget.bridge || repository != oldWidget.repository;
  }
}
