import 'package:genui/genui.dart';

import 'ai_ui_support.dart';
import 'items/action_items.dart';
import 'items/chart_items.dart';
import 'items/data_items.dart';
import 'items/input_items.dart';
import 'items/layout_items.dart';
import 'items/text_items.dart';

/// The complete vocabulary the assistant may compose UI from.
///
/// Every item is built out of an existing Pointy component and takes no
/// styling from the model. Adding an item here is the only way to widen what
/// the assistant can draw, which is what keeps generated screens on-brand.
abstract final class PointyAiCatalog {
  static List<CatalogItem> get items => <CatalogItem>[
    ...aiLayoutItems,
    ...aiTextItems,
    ...aiDataItems,
    ...aiChartItems,
    ...aiActionItems,
    ...aiInputItems,
  ];

  static Catalog build() => Catalog(items, catalogId: pointyAiCatalogId);

  /// Item names, used by the catalog parity test and by the schema export.
  static List<String> get itemNames =>
      items.map((item) => item.name).toList(growable: false);
}
