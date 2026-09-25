import 'dart:typed_data';

import '../../core/result.dart';
import '../models/print_audit_event.dart';
import '../models/sale_order.dart' show PaymentMethod;
import '../models/shop_settings.dart';
import '../repositories/printing_repository.dart';
import '../repositories/shop_settings_repository.dart';
import 'order_document_service.dart';
import 'print_transport.dart';

/// Prints proof-of-payment slips for every payment flow (customer per-invoice,
/// customer account, supplier disbursement).
///
/// It owns the one sequence those flows would otherwise each copy — load the
/// shop settings, load the logo, then dispatch to
/// [PrintingRepository.printProofOfPayment] — so the receipt/disbursement
/// layout, audit trail, and settings plumbing stay defined in a single place.
/// Callers build the [PaymentProof] from their own domain object and hand it
/// over; the account helper below is the exception, because two entry points
/// (the customer page and the POS collect-debt dialog) would otherwise build
/// the same account receipt.
class PaymentProofPrinter {
  PaymentProofPrinter({
    required PrintingRepository printingRepository,
    required ShopSettingsRepository shopSettingsRepository,
  }) : _printingRepository = printingRepository,
       _shopSettingsRepository = shopSettingsRepository;

  final PrintingRepository _printingRepository;
  final ShopSettingsRepository _shopSettingsRepository;

  /// Prints a fully-built [proof], loading the shop settings + logo internally.
  Future<PrintTransportResult> printProof({
    required PaymentProof proof,
    required int paymentId,
    required PrintAuditPaymentKind paymentKind,
  }) async {
    final shopSettings = await _loadShopSettings();
    return _printingRepository.printProofOfPayment(
      proof: proof,
      paymentId: paymentId,
      paymentKind: paymentKind,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );
  }

  /// Builds + prints a customer receipt ("سند قبض") for an *account* payment —
  /// one not tied to a single invoice (the backend allocates it oldest-first
  /// across the customer's open debt, so there is no related document number).
  /// [balanceAfter] is the customer's remaining outstanding balance afterwards.
  Future<PrintTransportResult> printCustomerAccountReceipt({
    required int paymentId,
    required String partyName,
    String? partyContact,
    required double amount,
    required PaymentMethod method,
    required double balanceAfter,
  }) {
    const labels = OrderDocumentLabels.arabic();
    return printProof(
      proof: PaymentProof(
        kind: PaymentProofKind.receipt,
        reference: '$paymentId',
        partyName: partyName,
        partyContact: partyContact,
        amount: amount,
        method: labels.paymentMethodLabel(method),
        balanceAfter: balanceAfter,
        createdAt: DateTime.now(),
      ),
      paymentId: paymentId,
      paymentKind: PrintAuditPaymentKind.customer,
    );
  }

  /// Builds + prints a disbursement ("سند صرف") for a payment made to a
  /// supplier *on account* — split by the server across what the shop owed
  /// them, so there is no single order to name. [paymentId] is the first
  /// payment the split wrote; [balanceAfter] is what the shop still owes.
  Future<PrintTransportResult> printSupplierAccountDisbursement({
    required int paymentId,
    required String partyName,
    String? partyContact,
    required double amount,
    required String methodLabel,
    String reference = '',
    required double balanceAfter,
  }) {
    return printProof(
      proof: PaymentProof(
        kind: PaymentProofKind.disbursement,
        reference: '$paymentId',
        partyName: partyName,
        partyContact: partyContact,
        amount: amount,
        method: methodLabel,
        externalReference: reference,
        balanceAfter: balanceAfter,
        createdAt: DateTime.now(),
      ),
      paymentId: paymentId,
      paymentKind: PrintAuditPaymentKind.supplier,
    );
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final result = await _shopSettingsRepository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final result = await _shopSettingsRepository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }
}
