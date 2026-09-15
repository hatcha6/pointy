// Dev-only preview harness for the invoice's cashier / drawer-session
// attribution. Safe to delete — a separate entrypoint, never imported by
// lib/main.dart.
//
// Run it with `make frontend-invoice-attribution-preview`, then open:
//   ?screen=board    every state side by side (phone + wide, light + dark)
//   ?screen=linked   the details pane full-viewport, attribution as links
//   ?screen=plain    the same pane for a user who may not follow the links
//   ?screen=loading  what the pane shows while the real document is fetched
//   ?screen=dark     the linked pane under the dark palette
//   ?screen=filters  the invoices filter sheet, cashier section included
//
// See AGENTS.md — a black canvas after start is a browser refresh issue, not a
// slow compile. Reload once.

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_details_screen.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_filter_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  runApp(const InvoiceAttributionPreviewApp());
}

class InvoiceAttributionPreviewApp extends StatelessWidget {
  const InvoiceAttributionPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final screen = Uri.base.queryParameters['screen'] ?? 'board';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: screen == 'dark' ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: switch (screen) {
        'linked' => _pane(linked: true),
        'plain' => _pane(linked: false),
        'loading' => _pane(linked: true, neverResolves: true),
        'dark' => _pane(linked: true),
        'filters' => _filters(),
        _ => const _Board(),
      },
    );
  }
}

/// The master-detail pane exactly as the invoices screen embeds it.
Widget _pane({required bool linked, bool neverResolves = false}) {
  final service = PosApiService();
  return Scaffold(
    body: SafeArea(
      child: InvoiceDetailsView(
        saleRepository: _FakeSaleRepository(neverResolves: neverResolves),
        printingRepository: PrintingRepository(service),
        shopSettingsRepository: ShopSettingsRepository(service),
        catalogRepository: CatalogRepository(service),
        contactRepository: ContactRepository(service),
        // What the invoices LIST hands over: totals and attribution, no lines.
        initialOrder: _listRow(),
        capabilities: AuthorizationCapabilities.forUser(_manager()),
        onOpenCashier: linked ? (_) {} : null,
        onOpenRegisterSession: linked ? (_) {} : null,
        showHeader: true,
      ),
    ),
  );
}

/// The filter sheet's body, rendered inline so a screenshot catches it without
/// having to drive a modal open through a Flutter-web canvas.
Widget _filters({bool selected = true}) {
  final service = PosApiService();
  return Scaffold(
    body: SafeArea(
      child: InvoiceFilterSheet(
        query: selected
            ? const SaleOrderQuery(cashierId: 4, cashierName: 'سالم الفيتوري')
            : const SaleOrderQuery(),
        contactRepository: ContactRepository(service),
        userRepository: _FakeUserRepository(),
      ),
    ),
  );
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
              _frame('منسوبة — هاتف', 390, 900, _pane(linked: true)),
              _frame('بلا صلاحية فتح — هاتف', 390, 900, _pane(linked: false)),
              _frame(
                'أثناء التحميل',
                390,
                900,
                _pane(linked: true, neverResolves: true),
              ),
              _frame('الفلاتر — هاتف', 390, 900, _filters()),
              _frame(
                'الفلاتر — بلا كاشير',
                390,
                900,
                _filters(selected: false),
              ),
              _frame('منسوبة — لوحة عريضة', 620, 900, _pane(linked: true)),
              _frame(
                'منسوبة — الوضع الليلي',
                390,
                900,
                _pane(linked: true),
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

class _FakeUserRepository extends UserRepository {
  _FakeUserRepository() : super(PosApiService());

  @override
  Future<Result<PosUserPage>> loadUsers({
    int page = 1,
    String search = '',
    String role = '',
  }) async {
    const people = [
      (4, 'salem', 'سالم الفيتوري'),
      (5, 'bahr', 'بحر'),
      (6, 'mkhalid', 'محمد خالد'),
    ];
    final term = search.trim();
    return Ok(
      PosUserPage(
        users: [
          for (final (id, username, name) in people)
            if (term.isEmpty || name.contains(term) || username.contains(term))
              PosUser(
                id: id,
                username: username,
                displayName: name,
                role: UserRole.cashier,
                isActive: true,
              ),
        ],
        hasMore: false,
      ),
    );
  }
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository({this.neverResolves = false}) : super(PosApiService());

  /// Holds the fetch open so the loading state can be screenshotted.
  final bool neverResolves;

  @override
  Future<Result<SaleOrder>> loadOrder(int saleOrderId) {
    if (neverResolves) {
      return Future.any([]);
    }
    return Future.value(Ok(_fullOrder()));
  }
}

SaleOrder _listRow() {
  return SaleOrder(
    id: 42,
    receiptNumber: '1042',
    status: 'paid',
    paymentStatus: 'paid',
    registerSession: 7,
    registerSessionNumber: 'RS-7',
    cashierId: 4,
    cashierName: 'سالم الفيتوري',
    customerName: 'سارة أحمد',
    lineCount: 2,
    lines: const [],
    payments: const [],
    subtotal: 47,
    total: 47,
    amountPaid: 47,
    createdAt: DateTime(2026, 9, 15, 11, 4),
  );
}

SaleOrder _fullOrder() {
  final row = _listRow();
  return SaleOrder(
    id: row.id,
    receiptNumber: row.receiptNumber,
    status: row.status,
    paymentStatus: row.paymentStatus,
    registerSession: row.registerSession,
    registerSessionNumber: row.registerSessionNumber,
    cashierId: row.cashierId,
    cashierName: row.cashierName,
    customerName: row.customerName,
    lineCount: row.lineCount,
    lines: const [
      SaleOrderLine(
        id: 1,
        productId: 1,
        variantId: 1,
        productName: 'قهوة عربية 250غ',
        quantity: 2,
        returnedQuantity: 0,
        returnableQuantity: 2,
        unitPrice: 16,
        total: 32,
      ),
      SaleOrderLine(
        id: 2,
        productId: 2,
        variantId: 2,
        productName: 'سكر ناعم 1كغ',
        quantity: 3,
        returnedQuantity: 0,
        returnableQuantity: 3,
        unitPrice: 5,
        total: 15,
      ),
    ],
    payments: const [
      SalePayment(
        id: 1,
        method: PaymentMethod.cash,
        amount: 47,
        commissionPercent: 0,
        commissionAmount: 0,
      ),
    ],
    subtotal: row.subtotal,
    total: row.total,
    amountPaid: row.amountPaid,
    createdAt: row.createdAt,
  );
}

PosUser _manager() {
  return PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'display_name': 'مدير النظام',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  });
}
