import 'dart:async';
import 'dart:typed_data';

import '../../../core/result.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/print_transport.dart';
import '../../../data/services/repair_intake_printables.dart';

/// How one print went, in the three ways a counter needs to hear about it.
enum JobPrintStatus {
  printed,

  /// No printer on this device does the job — fixed in the printer settings,
  /// not by trying again.
  noPrinter,
  failed;

  static JobPrintStatus of(PrintTransportResult result) {
    if (result.isSuccess) {
      return JobPrintStatus.printed;
    }
    return result.unassignedRole != null
        ? JobPrintStatus.noPrinter
        : JobPrintStatus.failed;
  }
}

/// What a repair intake prints: the receipt the customer takes home, on the
/// receipt printer, and the sticker that goes on their item, on the label
/// printer. Each goes to its own printer through the device's printer list.
///
/// Best-effort by construction: a printer that is off, missing or hung comes
/// back as a status after at most [deadline], never as an exception, because
/// the job is already saved and nothing about printing can un-save it.
class JobPrintActions {
  const JobPrintActions({
    required this.printingRepository,
    this.shopSettingsRepository,
    this.deadline = const Duration(seconds: 30),
  });

  final PrintingRepository printingRepository;

  /// Supplies the shop's name, number, logo and conditions for the receipt.
  /// Optional: without it the receipt still prints, with the defaults.
  final ShopSettingsRepository? shopSettingsRepository;
  final Duration deadline;

  Future<JobPrintStatus> printTicket(OperationsJob job) {
    return _guarded(() async {
      final settings = await _loadSettings();
      return printingRepository.printRepairTicket(
        ticket: buildRepairTicket(job, settings: settings),
        shopSettings: settings,
        shopLogoBytes: await _loadLogo(settings),
      );
    });
  }

  Future<JobPrintStatus> printLabel(OperationsJob job) {
    return _guarded(
      () => printingRepository.printBarcodeLabels([repairLabelPrintLine(job)]),
    );
  }

  Future<JobPrintStatus> _guarded(
    Future<PrintTransportResult> Function() print,
  ) async {
    try {
      final result = await print().timeout(deadline);
      return JobPrintStatus.of(result);
    } on Object {
      return JobPrintStatus.failed;
    }
  }

  Future<ShopSettings?> _loadSettings() async {
    final repository = shopSettingsRepository;
    if (repository == null) {
      return null;
    }
    final result = await repository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadLogo(ShopSettings? settings) async {
    final repository = shopSettingsRepository;
    if (repository == null || settings == null) {
      return null;
    }
    final result = await repository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }
}
