import 'package:flutter/widgets.dart';

import '../../data/repositories/document_trail_repository.dart';

/// Puts a document's history within reach of any screen that shows a document.
///
/// A scope rather than a constructor parameter, for the same reason the
/// companion camera is one: the trail is not a feature of purchasing or of
/// sales, it belongs to every document there is, and threading a repository
/// through every screen that might show one would be a parameter nobody reads
/// on a dozen constructors.
///
/// Installed above the Navigator so pushed routes can see it. Null in previews
/// and tests that do not need it, which is what [maybeOf] is for: a screen
/// asks, and simply does not offer the action when the answer is nothing.
class DocumentTrailScope extends InheritedWidget {
  const DocumentTrailScope({
    super.key,
    required this.repository,
    required super.child,
  });

  final DocumentTrailRepository? repository;

  static DocumentTrailRepository? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<DocumentTrailScope>()
        ?.repository;
  }

  @override
  bool updateShouldNotify(DocumentTrailScope oldWidget) {
    return repository != oldWidget.repository;
  }
}
