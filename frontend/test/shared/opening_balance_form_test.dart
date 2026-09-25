import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/balance_entry.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/contact_picker_sheet.dart';

void main() {
  testWidgets('a new customer can arrive with what they already owe', (
    tester,
  ) async {
    final repository = _FakeCreateRepository();
    await _pumpHost(
      tester,
      onOpen: (context) => showCreateCustomerSheet(
        context: context,
        repository: repository,
        allowOpeningBalance: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'سالم علي');
    // Off until asked for: the ordinary create stays as short as it was.
    expect(find.byKey(const ValueKey('opening_balance_amount')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('opening_balance_toggle')));
    await tester.pumpAndSettle();

    // Asked for, the amount is required.
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();
    expect(find.text('أدخل مبلغًا أكبر من صفر.'), findsOneWidget);
    expect(repository.customerDraft, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('opening_balance_amount')),
      '320',
    );
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();

    final opening = repository.customerDraft?.openingBalance;
    expect(opening?.direction, BalanceDirection.theyOweUs);
    expect(opening?.amount, 320);
  });

  testWidgets('a new supplier the shop owes: "له علينا"', (tester) async {
    final repository = _FakeCreateRepository();
    await _pumpHost(
      tester,
      onOpen: (context) => showCreateSupplierSheet(
        context: context,
        repository: repository,
        allowOpeningBalance: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'شركة الحسن');
    await tester.tap(find.byKey(const ValueKey('opening_balance_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('له علينا'));
    await tester.enterText(
      find.byKey(const ValueKey('opening_balance_amount')),
      '1500',
    );
    await tester.tap(find.text('حفظ المورد'));
    await tester.pumpAndSettle();

    final opening = repository.supplierDraft?.openingBalance;
    expect(opening?.direction, BalanceDirection.weOweThem);
    expect(opening?.amount, 1500);
  });

  testWidgets('without the permission the form offers no opening balance', (
    tester,
  ) async {
    final repository = _FakeCreateRepository();
    await _pumpHost(
      tester,
      onOpen: (context) =>
          showCreateCustomerSheet(context: context, repository: repository),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('opening_balance_toggle')), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'سالم علي');
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();
    expect(repository.customerDraft?.openingBalance, isNull);
  });

  testWidgets('a refused opening balance is named, not a generic failure', (
    tester,
  ) async {
    final repository = _FakeCreateRepository(
      failure: PosApiException(
        message: 'refused',
        statusCode: 400,
        responseBody: jsonEncode({
          'opening_balance': {
            'effective_date': ['in the future'],
          },
        }),
      ),
    );
    await _pumpHost(
      tester,
      onOpen: (context) => showCreateCustomerSheet(
        context: context,
        repository: repository,
        allowOpeningBalance: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'سالم علي');
    await tester.tap(find.byKey(const ValueKey('opening_balance_toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('opening_balance_amount')),
      '10',
    );
    await tester.tap(find.text('حفظ العميل'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.balanceEntryFutureDateError), findsOneWidget);
  });
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onOpen,
}) async {
  tester.view.physicalSize = const Size(1400, 2000);
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

class _FakeCreateRepository extends ContactRepository {
  _FakeCreateRepository({this.failure}) : super(PosApiService());

  final Exception? failure;
  CustomerDraft? customerDraft;
  SupplierDraft? supplierDraft;

  @override
  Future<Result<Customer>> createCustomer(CustomerDraft draft) async {
    if (failure != null) {
      return Error(failure!);
    }
    customerDraft = draft;
    return Ok(
      Customer(
        id: 1,
        customerNumber: 'C-0001',
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
  Future<Result<SupplierContact>> createSupplier(SupplierDraft draft) async {
    if (failure != null) {
      return Error(failure!);
    }
    supplierDraft = draft;
    return Ok(
      SupplierContact(
        id: 2,
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
