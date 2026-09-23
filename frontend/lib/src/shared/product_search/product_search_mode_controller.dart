import 'package:flutter/widgets.dart';

import '../../data/services/device_settings_storage_service.dart';

/// Whether this machine's product searches offer the search-mode picker —
/// search by code or by name alone, besides the ordinary search.
///
/// A per-device switch in Device Settings, read by the product search on the
/// till, the purchasing screen and the catalog. Loaded once at startup and
/// written back on every change, the way the theme is, so turning it on or off
/// reaches every one of those screens without a restart.
class ProductSearchModeController extends ChangeNotifier {
  ProductSearchModeController({
    DeviceSettingsStorageService storage = const DeviceSettingsStorageService(),
    bool pickerEnabled = false,
  }) : _storage = storage,
       _pickerEnabled = pickerEnabled;

  final DeviceSettingsStorageService _storage;

  bool _pickerEnabled;
  bool get pickerEnabled => _pickerEnabled;

  /// Reads the stored choice. A storage failure leaves the picker off rather
  /// than holding up startup over a search option.
  Future<void> load() async {
    final bool stored;
    try {
      stored = await _storage.loadProductSearchModePicker();
    } on Object {
      return;
    }
    if (stored != _pickerEnabled) {
      _pickerEnabled = stored;
      notifyListeners();
    }
  }

  /// Turns the picker on or off, returning whether the choice was saved. A
  /// failed save puts the switch back, so the screen never shows a setting
  /// the machine will have forgotten by its next start.
  Future<bool> setPickerEnabled(bool enabled) async {
    if (enabled == _pickerEnabled) {
      return true;
    }
    _pickerEnabled = enabled;
    notifyListeners();
    try {
      await _storage.saveProductSearchModePicker(enabled);
      return true;
    } on Object {
      _pickerEnabled = !enabled;
      notifyListeners();
      return false;
    }
  }
}

/// Publishes the [ProductSearchModeController] to every screen, and rebuilds
/// the searches that read it when the switch changes.
class ProductSearchModeScope
    extends InheritedNotifier<ProductSearchModeController> {
  const ProductSearchModeScope({
    super.key,
    required ProductSearchModeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ProductSearchModeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ProductSearchModeScope>()
        ?.notifier;
  }

  /// Whether product searches under [context] show the picker. False with no
  /// scope above them — a preview or a test that did not ask for it.
  static bool pickerEnabledOf(BuildContext context) {
    return maybeOf(context)?.pickerEnabled ?? false;
  }
}
