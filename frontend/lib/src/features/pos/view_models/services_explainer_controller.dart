import 'package:flutter/foundation.dart';

import '../../../core/storage/app_key_value_store.dart';

/// Which of the services' explainers this till has been told to hide.
///
/// A service is new to the cashier and to the customer: its first screen
/// explains it. Once the cashier has understood, the explainer is dismissed
/// and stays dismissed on this machine — the help button brings it back.
///
/// Nothing is shown until the stored choice has been read, so a returning
/// cashier never sees the explainer flash up and vanish.
class ServicesExplainerController extends ChangeNotifier {
  ServicesExplainerController({this.storageKey = 'pos_services_explainers'}) {
    _loaded = _load();
  }

  final String storageKey;
  late final Future<void> _loaded;
  final Set<String> _dismissed = {};
  bool _isLoaded = false;
  bool _disposed = false;

  /// The stored choice has been read (or could not be).
  bool get isLoaded => _isLoaded;

  Future<void> get loaded => _loaded;

  /// Whether the explainer of [key] should be on screen right now.
  bool isShown(String key) => _isLoaded && !_dismissed.contains(key);

  Future<void> _load() async {
    try {
      final store = await AppKeyValueStore.instance();
      final stored = await store.getStringList(storageKey);
      if (stored != null) {
        _dismissed.addAll(stored);
      }
    } on Object {
      // An explainer that cannot remember is shown again, which is harmless.
    }
    _isLoaded = true;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Hides the explainer of [key] for good.
  Future<void> dismiss(String key) => _set(key, dismissed: true);

  /// Shows the explainer of [key] again.
  Future<void> restore(String key) => _set(key, dismissed: false);

  Future<void> _set(String key, {required bool dismissed}) async {
    final changed = dismissed ? _dismissed.add(key) : _dismissed.remove(key);
    if (!changed) {
      return;
    }
    notifyListeners();
    try {
      final store = await AppKeyValueStore.instance();
      await store.setStringList(storageKey, _dismissed.toList()..sort());
    } on Object {
      // The choice holds for this session even if it cannot be saved.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
