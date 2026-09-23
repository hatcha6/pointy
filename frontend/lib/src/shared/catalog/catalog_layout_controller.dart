import 'package:flutter/foundation.dart';

import '../../core/storage/app_key_value_store.dart';

/// How a catalog browser lays out its products. Stored by name.
enum CatalogLayout {
  /// Picture cards in a responsive grid — the layout every till started with.
  grid,

  /// A table, one product to a row, read down a column like a price list.
  list,
}

/// Remembers which [CatalogLayout] a catalog browser shows on this machine.
///
/// Per device, like the theme, because it follows the counter rather than the
/// shop: a touch till that sells by picture wants cards, a counter that looks
/// items up by name all day wants a table it can read down.
///
/// Reads the stored choice as soon as it is created and shows
/// [CatalogLayout.grid] until it arrives, or when nobody ever chose.
class CatalogLayoutController extends ChangeNotifier {
  CatalogLayoutController({required String storageKey})
    : _storageKey = storageKey {
    _loaded = _load();
  }

  final String _storageKey;
  late final Future<void> _loaded;
  CatalogLayout _layout = CatalogLayout.grid;
  bool _chosen = false;
  bool _disposed = false;

  CatalogLayout get layout => _layout;

  /// Completes once the stored choice has been read, or failed to be.
  Future<void> get loaded => _loaded;

  Future<void> _load() async {
    final CatalogLayout? stored;
    try {
      final store = await AppKeyValueStore.instance();
      final name = await store.getString(_storageKey);
      stored = CatalogLayout.values.asNameMap()[name];
    } on Object {
      // A catalog that cannot read its layout still sells, in the default one.
      return;
    }
    // A layout picked while the read was in flight is the newer word.
    if (_disposed || _chosen || stored == null || stored == _layout) {
      return;
    }
    _layout = stored;
    notifyListeners();
  }

  /// Shows [layout] now and remembers it for this machine's next start.
  Future<void> setLayout(CatalogLayout layout) async {
    _chosen = true;
    if (layout == _layout) {
      return;
    }
    _layout = layout;
    notifyListeners();
    try {
      final store = await AppKeyValueStore.instance();
      await store.setString(_storageKey, layout.name);
    } on Object {
      // The new layout stays on screen; a failed save only means the next
      // start forgets it, which is no reason to undo what was just picked.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
