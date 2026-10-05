import 'package:flutter/widgets.dart';

import '../../core/result.dart';
import '../../data/models/unit_attribute.dart';

typedef UnitAttributeDefinitionsSource =
    Future<Result<List<UnitAttributeDefinition>>> Function(int assetTypeId);

/// The shop's attribute definitions, per kind of article, fetched once.
///
/// The capture sheet is opened from the receiving bay, the counter purchase
/// and (later) consignment intake, none of which otherwise has any reason to
/// hold the tracked-stock repository. They ask this instead. A definition set
/// changes when somebody edits it in settings, so an answer is kept for a few
/// minutes rather than forever; a failed read is not kept at all.
class UnitAttributeCatalog {
  UnitAttributeCatalog(
    this._source, {
    this.maxAge = const Duration(minutes: 5),
  });

  final UnitAttributeDefinitionsSource _source;
  final Duration maxAge;
  final Map<int, (DateTime, Future<List<UnitAttributeDefinition>>)> _cache = {};

  Future<List<UnitAttributeDefinition>> definitionsFor(int? assetTypeId) {
    if (assetTypeId == null) {
      return Future.value(const []);
    }
    final cached = _cache[assetTypeId];
    if (cached != null && DateTime.now().difference(cached.$1) < maxAge) {
      return cached.$2;
    }
    final future = _source(assetTypeId).then((result) {
      switch (result) {
        case Ok<List<UnitAttributeDefinition>>(:final value):
          return value;
        case Error<List<UnitAttributeDefinition>>():
          _cache.remove(assetTypeId);
          return const <UnitAttributeDefinition>[];
      }
    });
    _cache[assetTypeId] = (DateTime.now(), future);
    return future;
  }

  void invalidate() => _cache.clear();
}

/// Makes the [UnitAttributeCatalog] reachable from any sheet. Absent — a test,
/// a preview — means no definitions, and the capture sheet then looks exactly
/// as it always did.
class UnitAttributeCatalogScope extends InheritedWidget {
  const UnitAttributeCatalogScope({
    super.key,
    required this.catalog,
    required super.child,
  });

  final UnitAttributeCatalog catalog;

  static UnitAttributeCatalog? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<UnitAttributeCatalogScope>()
        ?.catalog;
  }

  @override
  bool updateShouldNotify(UnitAttributeCatalogScope oldWidget) =>
      oldWidget.catalog != catalog;
}
