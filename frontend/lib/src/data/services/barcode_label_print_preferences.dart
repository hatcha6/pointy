import '../../core/storage/app_key_value_store.dart';

/// Whether barcode-label stickers carry the price, remembered per device.
///
/// A shop decides once whether its labels show a price — a grocery that reprices
/// weekly wants bare barcodes, a boutique wants the price on the tag — and then
/// never wants to be asked again. The per-print switch stays (a one-off label
/// can still go either way); this only makes the last answer the next default,
/// including for the command palette's one-tap "print label", which asks
/// nothing at all.
///
/// Device-local on purpose: it follows the label printer, which is a property of
/// the counter it sits on, not of the shop record.
class BarcodeLabelPrintPreferences {
  const BarcodeLabelPrintPreferences();

  static const _includePriceKey = 'barcode_label.include_price';

  /// Defaults to true — a fresh install prints the price until told otherwise.
  Future<bool> includePrice() async {
    try {
      final store = await AppKeyValueStore.instance();
      return (await store.getString(_includePriceKey)) != '0';
    } catch (_) {
      return true;
    }
  }

  Future<void> setIncludePrice(bool value) async {
    try {
      final store = await AppKeyValueStore.instance();
      await store.setString(_includePriceKey, value ? '1' : '0');
    } catch (_) {
      // Best-effort: a remembered default is a convenience, and the print
      // itself already carries the choice the user just made.
    }
  }
}

/// The app-wide label print preferences.
const barcodeLabelPrintPreferences = BarcodeLabelPrintPreferences();
