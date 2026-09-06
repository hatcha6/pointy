// Dev-only preview harness for the document lifecycle's user-facing surface.
// Safe to delete — a separate entrypoint, never imported by lib/main.dart.
//
// Run it with `make frontend-document-trail-preview`, then open:
//   ?screen=board      every state side by side (phone + wide, light + dark)
//   ?screen=trail      the history sheet full-viewport, for responsive QA
//   ?screen=retracted  a voided invoice, so the callout can be read in place
//
// See AGENTS.md — a black canvas after start is a browser refresh issue, not a
// slow compile. Reload once.

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/document_trail_event.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/document_trail_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/documents/document_trail_scope.dart';
import 'package:pointy_frontend/src/shared/documents/document_trail_sheet.dart';
import 'package:pointy_frontend/src/shared/order/sale_order_details_content.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  runApp(const DocumentTrailPreviewApp());
}

class DocumentTrailPreviewApp extends StatelessWidget {
  const DocumentTrailPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final screen = Uri.base.queryParameters['screen'] ?? 'board';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: DocumentTrailScope(
          repository: _FakeTrailRepository(_events()),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: switch (screen) {
        'trail' => _TrailHost(events: _events()),
        'retracted' => _invoice(_voidedOrder()),
        _ => const _Board(),
      },
    );
  }
}

/// The sheet body, rendered inline so a screenshot catches it without having to
/// drive a modal open through a Flutter-web canvas.
Widget _trail(List<DocumentTrailEvent> events) {
  return Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: DocumentTrailSheet(
          repository: _FakeTrailRepository(events),
          documentType: 'purchase_order',
          documentId: 1,
          documentNumber: 'P20260905000042',
        ),
      ),
    ),
  );
}

Widget _invoice(SaleOrder order) {
  return Scaffold(
    body: SafeArea(
      child: SaleOrderDetailsContent(order: order, showTitle: true),
    ),
  );
}

class _TrailHost extends StatelessWidget {
  const _TrailHost({required this.events});

  final List<DocumentTrailEvent> events;

  @override
  Widget build(BuildContext context) => _trail(events);
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFEEF1F5),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 24,
            runSpacing: 24,
            children: [
              _frame('سجل المستند — هاتف', 390, 844, _trail(_events())),
              _frame(
                'سجل المستند — بلا سجل',
                390, 844,
                _trail(const []),
              ),
              _frame('فاتورة ملغاة — هاتف', 390, 844, _invoice(_voidedOrder())),
              // 860 is what the modal actually gives an expanded sheet
              // (AdaptiveModalSizing), so the wide frame shows the real
              // maximum rather than a stretch the app never renders.
              _frame('سجل المستند — عريض', 860, 844, _trail(_events())),
              _frame(
                'سجل المستند — الوضع الليلي',
                390,
                844,
                _trail(_events()),
                dark: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _frame(
    String label,
    double width,
    double height,
    Widget child, {
    bool dark = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
        ),
        SizedBox(
          width: width,
          height: height,
          child: Theme(
            data: dark ? PointyTheme.dark() : PointyTheme.light(),
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: Size(width, height),
                  padding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// --- fakes -------------------------------------------------------------------

class _FakeTrailRepository extends DocumentTrailRepository {
  _FakeTrailRepository(this._events) : super(PosApiService());

  final List<DocumentTrailEvent> _events;

  @override
  Future<Result<List<DocumentTrailEvent>>> loadTrail({
    required String documentType,
    required int documentId,
  }) async => Ok(_events);
}

List<DocumentTrailEvent> _events() {
  return [
    DocumentTrailEvent(
      id: 3,
      documentType: 'purchase_order',
      objectId: 1,
      documentNumber: 'P20260905000042',
      action: DocumentTrailAction.cancelled,
      reason: 'المورد اعتذر عن التوريد، والبضاعة لم تصل.',
      changes: const [],
      actorUsername: 'أحمد',
      createdAt: DateTime(2026, 9, 5, 14, 32),
    ),
    DocumentTrailEvent(
      id: 2,
      documentType: 'purchase_order',
      objectId: 1,
      documentNumber: 'P20260905000042',
      action: DocumentTrailAction.corrected,
      reason: 'سعر الكرتونة كان ٨ بدل ١٢.',
      changes: const [
        DocumentFieldChange(field: 'total', from: '96.00', to: '144.00'),
        DocumentFieldChange(field: 'unit_cost', from: '8.00', to: '12.00'),
        DocumentFieldChange(
          field: 'supplier_invoice_number',
          from: '',
          to: 'INV-7741',
        ),
      ],
      actorUsername: 'سالم',
      createdAt: DateTime(2026, 9, 5, 11, 8),
    ),
    DocumentTrailEvent(
      id: 1,
      documentType: 'purchase_order',
      objectId: 1,
      documentNumber: 'P20260905000042',
      action: DocumentTrailAction.submitted,
      reason: '',
      changes: const [],
      actorUsername: 'سالم',
      createdAt: DateTime(2026, 9, 4, 9, 15),
    ),
  ];
}

SaleOrder _voidedOrder() {
  return SaleOrder(
    id: 7,
    receiptNumber: 'R20260905000018',
    status: 'void',
    docStatus: 'cancelled',
    cancelledAt: DateTime(2026, 9, 5, 16, 4),
    cancelledByUsername: 'أحمد',
    cancelReason: 'الزبون غيّر رأيه قبل مغادرة المحل.',
    lines: [
      SaleOrderLine(
        id: 1,
        productId: 1,
        variantId: 1,
        productName: 'قهوة مطحونة ٢٥٠غ',
        quantity: 2,
        unitPrice: 12.5,
        total: 25,
        subtotal: 25,
        discountTotal: 0,
        returnedQuantity: 2,
        returnableQuantity: 0,
      ),
    ],
    payments: const [],
    subtotal: 25,
    discountTotal: 0,
    total: 25,
    amountPaid: 0,
    balanceDue: 0,
    createdAt: DateTime(2026, 9, 5, 15, 40),
  );
}
