// Dev-only: a receipt printer that always prints, for preview harnesses that
// record a whole sale (the marketing page's clips), so the result reads
// «تمت طباعة الإيصال» instead of "no receipt printed". Nothing is sent
// anywhere. Not part of the shipping app. Safe to delete.
import 'dart:typed_data';

import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';

class PreviewReceiptPrintingRepository extends PrintingRepository {
  PreviewReceiptPrintingRepository() : super(PosApiService());

  @override
  Future<Result<PrinterConfig>> loadReceiptPrinterConfig() async {
    return const Ok(
      PrinterConfig(
        endpoint: PrinterEndpoint(
          kind: PrintTransportKind.fake,
          name: 'طابعة الإيصالات',
          outputMode: PrinterOutputMode.pdfA4,
        ),
      ),
    );
  }

  @override
  Future<PrintTransportResult> printSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    // Long enough for the print step to be seen in the sale's progress.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return const PrintTransportResult.success('preview');
  }
}

/// Shop settings that auto-print every receipt.
class PreviewAutoPrintSettingsRepository extends ShopSettingsRepository {
  PreviewAutoPrintSettingsRepository() : super(PosApiService());

  @override
  Future<Result<ShopSettings>> loadSettings() async {
    return Ok(
      ShopSettings.fromJson(const {
        'shop_name': 'سوق الوفاء',
        'auto_print_receipts': true,
      }),
    );
  }
}
