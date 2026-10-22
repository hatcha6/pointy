import 'dart:typed_data';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';

/// Prints and shares a purchase order with the shop's own masthead.
///
/// One place that fetches the shop's name and logo and hands the order to
/// this device's documents printer, shared by the order's page and the result
/// a submit ends in, so the two never print differently.
class PurchaseOrderDocuments {
  const PurchaseOrderDocuments({
    required PrintingRepository printingRepository,
    required ShopSettingsRepository shopSettingsRepository,
  }) : _printing = printingRepository,
       _shopSettings = shopSettingsRepository;

  final PrintingRepository _printing;
  final ShopSettingsRepository _shopSettings;

  /// Where a receipt's stickers go — each handset's own, each lot's dated.
  PrintingRepository get printingRepository => _printing;

  Future<bool> print(PurchaseOrder order) async {
    final settings = await _loadShopSettings();
    final result = await _printing.printPurchaseOrder(
      order: order,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
    );
    return result.isSuccess;
  }

  Future<OrderDocumentActionStatus> share(PurchaseOrder order) async {
    final settings = await _loadShopSettings();
    return _printing.sharePurchaseOrder(
      order: order,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
    );
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final result = await _shopSettings.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final result = await _shopSettings.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }
}
