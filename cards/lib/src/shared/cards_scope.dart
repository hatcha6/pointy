import 'package:flutter/widgets.dart';

import '../dependencies.dart';

/// Hands [CardsDependencies] down the tree.
class CardsScope extends InheritedWidget {
  const CardsScope({
    super.key,
    required this.dependencies,
    required super.child,
  });

  final CardsDependencies dependencies;

  static CardsDependencies of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CardsScope>();
    assert(scope != null, 'No CardsScope above this widget');
    return scope!.dependencies;
  }

  @override
  bool updateShouldNotify(CardsScope oldWidget) =>
      oldWidget.dependencies != dependencies;
}
