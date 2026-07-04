import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/contact_picker_sheet.dart';

const _customer = Customer(
  id: 7,
  customerNumber: 'C-0007',
  fullName: 'سالم علي',
  phone: '0911111111',
  email: 'salem@example.com',
  gender: CustomerGender.unspecified,
  marketingConsent: false,
  notes: 'زبون دائم',
  isActive: true,
);

const _supplier = SupplierContact(
  id: 12,
  name: 'شركة الحسن',
  contactName: 'أحمد',
  phone: '0922222222',
  email: '',
  address: 'بنغازي',
  notes: '',
  isActive: true,
);

void main() {
  testWidgets('customer edit sheet prefills, patches, and returns the '
      'updated customer', (tester) async {
    final repository = _FakeContactRepository();
    Customer? edited;
    await _pumpHost(
      tester,
      onOpen: (context) async {
        edited = await showEditCustomerSheet(
          context: context,
          repository: repository,
          customer: _customer,
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    // Prefilled from the existing customer, titled as an edit.
    expect(find.text('تعديل بيانات الزبون'), findsOneWidget);
    expect(find.text('سالم علي'), findsOneWidget);
    expect(find.text('0911111111'), findsOneWidget);

    await tester.enterText(find.text('سالم علي'), 'سالم علي المسماري');
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();

    expect(repository.updatedCustomerId, 7);
    expect(repository.updatedCustomerDraft?.fullName, 'سالم علي المسماري');
    expect(repository.updatedCustomerDraft?.phone, '0911111111');
    expect(repository.claimedAutoCreated, isFalse);
    expect(edited?.fullName, 'سالم علي المسماري');
  });

  testWidgets('editing an auto-created placeholder also claims it', (
    tester,
  ) async {
    final repository = _FakeContactRepository();
    await _pumpHost(
      tester,
      onOpen: (context) async {
        await showEditCustomerSheet(
          context: context,
          repository: repository,
          customer: const Customer(
            id: 9,
            customerNumber: 'C-0009',
            fullName: 'بطاقة 1234',
            phone: '',
            email: '',
            gender: CustomerGender.unspecified,
            marketingConsent: false,
            notes: '',
            isActive: true,
            isAutoCreated: true,
          ),
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();

    expect(repository.updatedCustomerId, 9);
    expect(repository.claimedAutoCreated, isTrue);
  });

  testWidgets('supplier edit sheet prefills, patches, and returns the '
      'updated supplier', (tester) async {
    final repository = _FakeContactRepository();
    SupplierContact? edited;
    await _pumpHost(
      tester,
      onOpen: (context) async {
        edited = await showEditSupplierSheet(
          context: context,
          repository: repository,
          supplier: _supplier,
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.text('تعديل بيانات المورد'), findsOneWidget);
    expect(find.text('شركة الحسن'), findsOneWidget);

    await tester.enterText(find.text('0922222222'), '0923333333');
    await tester.tap(find.text('حفظ المورد'));
    await tester.pumpAndSettle();

    expect(repository.updatedSupplierId, 12);
    expect(repository.updatedSupplierDraft?.name, 'شركة الحسن');
    expect(repository.updatedSupplierDraft?.phone, '0923333333');
    expect(edited?.phone, '0923333333');
  });

  testWidgets('a failed update shows the edit error and keeps the sheet '
      'open', (tester) async {
    final repository = _FakeContactRepository(failUpdates: true);
    await _pumpHost(
      tester,
      onOpen: (context) async {
        await showEditCustomerSheet(
          context: context,
          repository: repository,
          customer: _customer,
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();

    expect(
      find.text('تعذر حفظ بيانات الزبون. تحقق من الاتصال وحاول مجددًا.'),
      findsOneWidget,
    );
    expect(find.text('تعديل بيانات الزبون'), findsOneWidget); // still open
  });
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onOpen,
}) async {
  // A large window so the form opens as a desktop dialog that fits without a
  // scroll viewport clipping the save button below the fold.
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository({this.failUpdates = false}) : super(PosApiService());

  final bool failUpdates;
  int? updatedCustomerId;
  CustomerDraft? updatedCustomerDraft;
  bool claimedAutoCreated = false;
  int? updatedSupplierId;
  SupplierDraft? updatedSupplierDraft;

  @override
  Future<Result<Customer>> updateCustomer(
    int customerId,
    CustomerDraft draft, {
    bool claimAutoCreated = false,
  }) async {
    if (failUpdates) {
      return Error(Exception('update failed'));
    }
    updatedCustomerId = customerId;
    updatedCustomerDraft = draft;
    claimedAutoCreated = claimAutoCreated;
    return Ok(
      Customer(
        id: customerId,
        customerNumber: 'C-000$customerId',
        fullName: draft.fullName,
        phone: draft.phone,
        email: draft.email,
        gender: draft.gender,
        marketingConsent: draft.marketingConsent,
        notes: draft.notes,
        isActive: draft.isActive,
      ),
    );
  }

  @override
  Future<Result<SupplierContact>> updateSupplier(
    int supplierId,
    SupplierDraft draft,
  ) async {
    if (failUpdates) {
      return Error(Exception('update failed'));
    }
    updatedSupplierId = supplierId;
    updatedSupplierDraft = draft;
    return Ok(
      SupplierContact(
        id: supplierId,
        name: draft.name,
        contactName: draft.contactName,
        phone: draft.phone,
        email: draft.email,
        address: draft.address,
        notes: draft.notes,
        isActive: draft.isActive,
      ),
    );
  }
}
