import 'dart:typed_data';

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/consignor_statement.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../pdf/consignment_pdf.dart';

/// Prints the consignment documents with the shop's own masthead.
///
/// One place that knows how to fetch the shop's name and logo and hand the
/// page to this device's documents printer, shared by the payables screen and
/// the consignor statement so the two never print differently.
class ConsignmentDocumentPrinter {
  const ConsignmentDocumentPrinter({
    ShopSettingsRepository? shopSettingsRepository,
    PrintingRepository? printingRepository,
    ConsignmentDocumentPdfService documents =
        const ConsignmentDocumentPdfService(),
  }) : _shopSettings = shopSettingsRepository,
       _printingRepository = printingRepository,
       _documents = documents;

  final ShopSettingsRepository? _shopSettings;
  final PrintingRepository? _printingRepository;
  final ConsignmentDocumentPdfService _documents;

  Future<bool> printVoucher(ConsignmentAgreement agreement) async {
    final settings = await _loadShopSettings();
    return _documents.printVoucher(
      agreement: agreement,
      units: agreement.units,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
      printingRepository: _printingRepository,
    );
  }

  Future<bool> printPayout(ConsignorPayout payout) async {
    final settings = await _loadShopSettings();
    return _documents.printPayout(
      payout: payout,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
      printingRepository: _printingRepository,
    );
  }

  Future<bool> printStatement({
    required ConsignorStatement statement,
    required List<ConsignorStatementLine> lines,
    DateTime? start,
    DateTime? end,
  }) async {
    final settings = await _loadShopSettings();
    return _documents.printStatement(
      statement: statement,
      lines: lines,
      start: start,
      end: end,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
      printingRepository: _printingRepository,
    );
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final repository = _shopSettings;
    if (repository == null) {
      return null;
    }
    final result = await repository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final repository = _shopSettings;
    if (repository == null) {
      return null;
    }
    final result = await repository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }
}
