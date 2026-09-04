import 'package:flutter/widgets.dart';

import '../../data/repositories/companion_repository.dart';
import 'companion_bridge.dart';

/// Makes the companion camera reachable from any screen without threading it
/// through constructors.
///
/// Phone scanning is ambient — it belongs to every scanning surface at once —
/// so passing a bridge down through POS, purchasing, stock count and half a
/// dozen dialogs would mean editing each of them (and every preview harness and
/// widget test that builds one) to add a parameter they only forward. A scope
/// keeps the feature additive: screens that want it look it up, screens and
/// tests that do not get `null` and behave exactly as before.
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
