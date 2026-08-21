import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/discount_rule.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/discount_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/discounts/view_models/discount_management_view_model.dart';
import 'package:pointy_frontend/src/features/discounts/views/discount_details_screen.dart';

/// The beneficiaries list is the only place a manager can check *who* a
/// discount actually reached. A failed load named the failure and stopped
/// there — and unlike the rule itself there is no other control on the screen
/// that refetches it, so the manager had to leave and re-enter the discount.
void main() {
  testWidgets('a failed beneficiaries load offers a retry that refills it', (
    tester,
  ) async {
    final api = _DiscountApi(failFirstBeneficiaries: true);
    await _pumpDetails(tester, api);

    expect(find.text('تعذر تحميل المستفيدين من الخصم.'), findsOneWidget);
    final retry = find.byKey(
      const ValueKey('discount_beneficiaries_retry_button'),
    );
    expect(retry, findsOneWidget);

    final before = api.beneficiaryRequestCount;
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(api.beneficiaryRequestCount, before + 1);
    expect(find.text('تعذر تحميل المستفيدين من الخصم.'), findsNothing);
    expect(find.text('سالم'), findsWidgets);
  });

  testWidgets('the retry fits the fixed-height section on a narrow till', (
    tester,
  ) async {
    // The beneficiaries list lives in a `SizedBox` with a hardcoded height, so
    // a taller failure state overflows unless that height accounts for it —
    // and the title wraps to a second line once the till is this narrow.
    final api = _DiscountApi(failFirstBeneficiaries: true);
    await _pumpDetails(tester, api, size: const Size(420, 1600));

    expect(
      find.byKey(const ValueKey('discount_beneficiaries_retry_button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a healthy beneficiaries load shows no retry', (tester) async {
    final api = _DiscountApi(failFirstBeneficiaries: false);
    await _pumpDetails(tester, api);

    expect(
      find.byKey(const ValueKey('discount_beneficiaries_retry_button')),
      findsNothing,
    );
    expect(find.text('سالم'), findsWidgets);
  });
}

/// Pumps the details screen on a viewport tall enough to keep the (lazily
/// built) beneficiaries section mounted, so the assertions are about the error
/// state and not about `ListView` recycling.
Future<void> _pumpDetails(
  WidgetTester tester,
  _DiscountApi api, {
  Size size = const Size(1200, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final managementViewModel = DiscountManagementViewModel(
    DiscountRepository(api.service),
  );
  addTearDown(managementViewModel.dispose);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: DiscountDetailsScreen(
        initialRule: DiscountRule.fromJson(_ruleJson()),
        discountRepository: DiscountRepository(api.service),
        managementViewModel: managementViewModel,
        catalogRepository: CatalogRepository(api.service),
        contactRepository: ContactRepository(api.service),
        capabilities: AuthorizationCapabilities.forUser(
          PosUser.fromJson(_managerJson()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A discounts backend that fails the *first* beneficiaries request and serves
/// normally afterwards — the shape of a LAN blip, which is what makes a retry
/// the correct affordance rather than a permanent error.
class _DiscountApi {
  _DiscountApi({required this.failFirstBeneficiaries});

  final bool failFirstBeneficiaries;
  int beneficiaryRequestCount = 0;
  late final PosApiService service = PosApiService(client: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path.endsWith('/discount-rules/3/beneficiaries/')) {
      beneficiaryRequestCount += 1;
      if (failFirstBeneficiaries && beneficiaryRequestCount == 1) {
        return http.Response('', 500);
      }
      return _json({
        'count': 1,
        'next': null,
        'results': [
          {
            'id': 11,
            'name': 'سالم',
            'kind': 'customer',
            'redemption_count': 2,
            'total_discount': '15.00',
          },
        ],
      });
    }
    if (path.endsWith('/discount-rules/3/')) {
      return _json(_ruleJson());
    }
    if (path.endsWith('/discount-rules/')) {
      return _json({'count': 0, 'next': null, 'results': const <Object?>[]});
    }
    return http.Response('', 404);
  }
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> _ruleJson() => {
  'id': 3,
  'name': 'خصم نهاية الأسبوع',
  'description': '',
  'channel': 'sales',
  'application_type': 'automatic',
  'scope': 'order',
  'value_type': 'percentage',
  'value': '10.00',
  'priority': 1,
  'is_active': true,
};

Map<String, Object?> _managerJson() => {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير النظام',
  'role': 'manager',
  'is_active': true,
  'permissions': const ['discounts.view_discountrule'],
};
