import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/print_audit_event.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/fake_print_transport.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/data/services/payment_proof_printer.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PaymentProofPrinter', () {
    test(
      'printCustomerAccountReceipt builds a customer receipt with the account '
      'shape (no related invoice) and forwards the loaded settings + logo',
      () async {
        final printing = _RecordingPrintingRepository();
        final logo = Uint8List.fromList([1, 2, 3]);
        final settingsRepo = _StubShopSettingsRepository(
          settings: ShopSettings.fromJson(const {}),
          logoBytes: logo,
        );
        final printer = PaymentProofPrinter(
          printingRepository: printing,
          shopSettingsRepository: settingsRepo,
        );

        await printer.printCustomerAccountReceipt(
          paymentId: 42,
          partyName: 'سعيد',
          partyContact: '0911',
          amount: 25.5,
          method: PaymentMethod.card,
          balanceAfter: 10,
        );

        expect(printing.calls, 1);
        expect(printing.paymentId, 42);
        expect(printing.paymentKind, PrintAuditPaymentKind.customer);
        expect(settingsRepo.loadSettingsCalls, 1);
        expect(printing.shopSettings, same(settingsRepo.settings));
        expect(printing.shopLogoBytes, same(logo));

        final proof = printing.proof!;
        expect(proof.kind, PaymentProofKind.receipt);
        expect(proof.reference, '42');
        expect(proof.partyName, 'سعيد');
        expect(proof.partyContact, '0911');
        expect(proof.amount, 25.5);
        expect(proof.balanceAfter, 10);
        expect(proof.method, 'بطاقة');
        // An account payment spans the customer's open invoices, so the proof
        // carries no single related document number.
        expect(proof.relatedDocumentNumber, isNull);
      },
    );

    test('printProof forwards a caller-built proof unchanged', () async {
      final printing = _RecordingPrintingRepository();
      final settingsRepo = _StubShopSettingsRepository(
        settings: ShopSettings.fromJson(const {}),
        logoBytes: null,
      );
      final printer = PaymentProofPrinter(
        printingRepository: printing,
        shopSettingsRepository: settingsRepo,
      );
      const proof = PaymentProof(
        kind: PaymentProofKind.disbursement,
        reference: '7',
        partyName: 'مورد',
        amount: 100,
        method: 'نقد',
      );

      await printer.printProof(
        proof: proof,
        paymentId: 7,
        paymentKind: PrintAuditPaymentKind.supplier,
      );

      expect(printing.calls, 1);
      expect(printing.proof, same(proof));
      expect(printing.paymentId, 7);
      expect(printing.paymentKind, PrintAuditPaymentKind.supplier);
    });
  });
}

class _RecordingPrintingRepository extends PrintingRepository {
  // Inject fake transports so constructing the real repository never touches a
  // platform channel (the default Bluetooth/serial transports do).
  _RecordingPrintingRepository()
    : super(
        PosApiService(),
        serialTransport: const FakePrintTransport(),
        bluetoothTransport: const FakePrintTransport(),
        wifiTransport: const FakePrintTransport(),
        usbTransport: const FakePrintTransport(),
      );

  int calls = 0;
  PaymentProof? proof;
  int? paymentId;
  PrintAuditPaymentKind? paymentKind;
  ShopSettings? shopSettings;
  Uint8List? shopLogoBytes;

  @override
  Future<PrintTransportResult> printProofOfPayment({
    required PaymentProof proof,
    required int paymentId,
    required PrintAuditPaymentKind paymentKind,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    calls++;
    this.proof = proof;
    this.paymentId = paymentId;
    this.paymentKind = paymentKind;
    this.shopSettings = shopSettings;
    this.shopLogoBytes = shopLogoBytes;
    return const PrintTransportResult.success('ok');
  }
}

class _StubShopSettingsRepository extends ShopSettingsRepository {
  _StubShopSettingsRepository({required this.settings, required this.logoBytes})
    : super(PosApiService());

  final ShopSettings settings;
  final Uint8List? logoBytes;
  int loadSettingsCalls = 0;

  @override
  Future<Result<ShopSettings>> loadSettings() async {
    loadSettingsCalls++;
    return Ok(settings);
  }

  @override
  Future<Result<Uint8List?>> loadLogoBytes(ShopSettings? settings) async {
    return Ok(logoBytes);
  }
}
