import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_details_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_details_screen.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// "What has this cashier left on tab?" used to mean reading one "recent sales"
/// run and picking the آجل rows out of a column of settled cash invoices by
/// eye, then opening each to see what was still owed. The debt now has its own
/// section, with the remaining balance on the row.
void main() {
  testWidgets('credit invoices get their own section, apart from cash sales', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpProfile(tester);

    expect(find.text('آخر فواتير العملاء'), findsOneWidget);
    expect(find.text('الفواتير الآجلة'), findsOneWidget);

    // Each invoice sits under exactly one heading.
    expect(
      _sectionContains(tester, 'آخر فواتير العملاء', 'INV-CASH'),
      isTrue,
      reason: 'the cash sale belongs to the sales section',
    );
    expect(
      _sectionContains(tester, 'الفواتير الآجلة', 'INV-CREDIT-1'),
      isTrue,
      reason: 'the debt belongs to the credit section',
    );
    expect(
      _sectionContains(tester, 'آخر فواتير العملاء', 'INV-CREDIT-1'),
      isFalse,
      reason: 'a debt counted under both headings is counted twice',
    );
  });

  testWidgets('a credit row leads with what is still owed', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpProfile(tester);

    // 40.00 issued, 15.00 collected — the row shows the 25.00 remaining, not
    // the invoice total, because the remainder is what is being looked for.
    expect(find.textContaining('25.00'), findsWidgets);
  });

  testWidgets('the section totals the debt its five rows cannot show', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpProfile(tester);

    // 9 credit invoices issued in all; the list shows the newest few, so the
    // count and the outstanding total have to be stated outright.
    expect(find.textContaining('9'), findsWidgets);
    expect(find.textContaining('55.00'), findsWidgets);
  });

  testWidgets('a user with no debt says so rather than showing nothing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpProfile(tester, creditSales: const []);

    expect(find.text('الفواتير الآجلة'), findsOneWidget);
    expect(find.text('لا توجد فواتير آجلة لهذا المستخدم.'), findsOneWidget);
  });
}

/// Whether [text] appears inside the detail section titled [sectionTitle].
bool _sectionContains(WidgetTester tester, String sectionTitle, String text) {
  final section = find.ancestor(
    of: find.text(sectionTitle),
    matching: find.byType(PointyDetailSection),
  );
  expect(section, findsOneWidget, reason: 'no section titled $sectionTitle');
  return tester
      .widgetList<Text>(
        find.descendant(of: section, matching: find.byType(Text)),
      )
      .any((widget) => widget.data == text);
}

Map<String, Object?> _saleJson({
  required int id,
  required String receiptNumber,
  required String saleType,
  required String total,
  String amountPaid = '0.00',
  String balanceDue = '0.00',
  String paymentStatus = 'paid',
}) {
  return {
    'id': id,
    'receipt_number': receiptNumber,
    'status': saleType == 'credit' ? 'open' : 'paid',
    'sale_type': saleType,
    'customer_name': 'سارة أحمد',
    'register_session_number': 'RS-7',
    'subtotal': total,
    'discount_total': '0.00',
    'total': total,
    'amount_paid': amountPaid,
    'balance_due': balanceDue,
    'payment_status': paymentStatus,
    'due_date': null,
    'is_overdue': false,
    'created_at': '2026-09-15T09:00:00Z',
  };
}

Future<void> _pumpProfile(
  WidgetTester tester, {
  List<Map<String, Object?>>? creditSales,
}) async {
  const user = {
    'id': 4,
    'username': 'bahr',
    'display_name': 'بحر',
    'email': '',
    'role': 'cashier',
    'permissions': <String>[],
    'is_active': true,
  };
  final credit =
      creditSales ??
      [
        _saleJson(
          id: 11,
          receiptNumber: 'INV-CREDIT-1',
          saleType: 'credit',
          total: '40.00',
          amountPaid: '15.00',
          balanceDue: '25.00',
          paymentStatus: 'partial',
        ),
        _saleJson(
          id: 12,
          receiptNumber: 'INV-CREDIT-2',
          saleType: 'credit',
          total: '30.00',
          balanceDue: '30.00',
          paymentStatus: 'unpaid',
        ),
      ];

  final service = PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient((request) async {
      return http.Response(
        jsonEncode({
          'user': user,
          'summary': {
            'sales': {
              'invoice_count': 10,
              'credit_invoice_count': credit.isEmpty ? 0 : 9,
              'credit_outstanding_total': credit.isEmpty ? '0.00' : '55.00',
            },
            'register_sessions': const <String, Object?>{},
            'cash_movements': const <String, Object?>{},
            'purchasing': const <String, Object?>{},
            'supplier_payments': const <String, Object?>{},
            'activity': const <String, Object?>{},
          },
          'recent_sales': [
            _saleJson(
              id: 10,
              receiptNumber: 'INV-CASH',
              saleType: 'standard',
              total: '25.00',
              amountPaid: '25.00',
            ),
          ],
          'recent_credit_sales': credit,
          'recent_purchase_orders': const <Object?>[],
          'recent_register_sessions': const <Object?>[],
          'recent_activity': const <Object?>[],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  final posUser = PosUser.fromJson(user);
  final viewModel = UserDetailsViewModel(
    UserRepository(service),
    initialUser: posUser,
  );
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: UserDetailsScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(posUser),
        onManagePermissions: (_) async => false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
