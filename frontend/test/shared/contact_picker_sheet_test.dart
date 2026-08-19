import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/contact_picker_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _customers = [
  Customer(
    id: 7,
    customerNumber: 'C-0007',
    fullName: 'سالم علي',
    phone: '0911111111',
    email: '',
    gender: CustomerGender.unspecified,
    marketingConsent: false,
    notes: '',
    isActive: true,
  ),
];

const _suppliers = [
  SupplierContact(
    id: 12,
    name: 'شركة الحسن',
    contactName: 'أحمد',
    phone: '0922222222',
    email: '',
    address: '',
    notes: '',
    isActive: true,
  ),
];

/// The customer and supplier pickers are opened mid-sale — to put a customer on
/// a sale, to collect a debt, to pick a supplier for a purchase. Both used to
/// dead-end: a dropped link showed "تعذر تحميل العملاء والموردين." with nothing
/// to press, and a search that matched nothing claimed the shop had no
/// customers at all. The only way out of either was closing the sheet and
/// reopening it.
void main() {
  testWidgets('a failed customer load offers a retry that loads the list', (
    tester,
  ) async {
    final repository = _FakeContactRepository(failLoads: true);
    await _pumpPicker(tester, repository: repository, customers: true);

    expect(find.text('تعذر تحميل العملاء والموردين.'), findsOneWidget);
    expect(find.text('سالم علي'), findsNothing);

    repository.failLoads = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل العملاء والموردين.'), findsNothing);
    expect(find.text('سالم علي'), findsOneWidget);
  });

  testWidgets('a failed supplier load offers a retry that loads the list', (
    tester,
  ) async {
    final repository = _FakeContactRepository(failLoads: true);
    await _pumpPicker(tester, repository: repository, customers: false);

    expect(find.text('تعذر تحميل العملاء والموردين.'), findsOneWidget);

    repository.failLoads = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(find.text('شركة الحسن'), findsOneWidget);
  });

  testWidgets('a customer search that matched nothing quotes the term and '
      'clears back to the full list', (tester) async {
    final repository = _FakeContactRepository();
    await _pumpPicker(tester, repository: repository, customers: true);

    expect(find.text('سالم علي'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'زبون لا وجود له');
    await _settleSearchDebounce(tester);

    // Not "لا يوجد عملاء بعد." — the shop has customers, this search does not.
    expect(find.text('لا يوجد عملاء بعد.'), findsNothing);
    expect(find.textContaining('زبون لا وجود له'), findsWidgets);
    // The sheet has no funnel, so the escape must not mention filters.
    expect(find.text('مسح البحث والفلاتر'), findsNothing);

    await tester.tap(find.text('مسح البحث'));
    await tester.pumpAndSettle();

    expect(repository.lastSearch, isEmpty);
    expect(find.text('سالم علي'), findsOneWidget);
  });

  testWidgets('a supplier search that matched nothing clears back to the '
      'full list', (tester) async {
    final repository = _FakeContactRepository();
    await _pumpPicker(tester, repository: repository, customers: false);

    await tester.enterText(find.byType(TextField), 'مورد لا وجود له');
    await _settleSearchDebounce(tester);

    expect(find.text('لا يوجد موردون بعد.'), findsNothing);

    await tester.tap(find.text('مسح البحث'));
    await tester.pumpAndSettle();

    expect(repository.lastSearch, isEmpty);
    expect(find.text('شركة الحسن'), findsOneWidget);
  });

  testWidgets('a genuinely empty customer list keeps its plain message', (
    tester,
  ) async {
    final repository = _FakeContactRepository(empty: true);
    await _pumpPicker(tester, repository: repository, customers: true);

    expect(find.text('لا يوجد عملاء بعد.'), findsOneWidget);
    expect(find.text('مسح البحث'), findsNothing);
  });
}

/// The search field debounces by 350ms before it queries; a pending timer does
/// not schedule a frame, so `pumpAndSettle` alone returns before it fires.
Future<void> _settleSearchDebounce(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required _FakeContactRepository repository,
  required bool customers,
}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () => customers
                  ? showCustomerPickerSheet(
                      context: context,
                      repository: repository,
                    )
                  : showSupplierPickerSheet(
                      context: context,
                      repository: repository,
                    ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository({this.failLoads = false, this.empty = false})
    : super(PosApiService());

  bool failLoads;
  final bool empty;
  String? lastSearch;

  bool _matches(String haystack) {
    final term = (lastSearch ?? '').trim();
    return term.isEmpty || haystack.contains(term);
  }

  @override
  Future<Result<CustomerPage>> loadCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    lastSearch = query.search;
    if (failLoads) {
      return Error(Exception('load failed'));
    }
    return Ok(
      CustomerPage(
        customers: empty
            ? const []
            : _customers.where((c) => _matches(c.fullName)).toList(),
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async {
    lastSearch = query.search;
    if (failLoads) {
      return Error(Exception('load failed'));
    }
    return Ok(
      SupplierPage(
        suppliers: empty
            ? const []
            : _suppliers.where((s) => _matches(s.name)).toList(),
        hasMore: false,
      ),
    );
  }
}
