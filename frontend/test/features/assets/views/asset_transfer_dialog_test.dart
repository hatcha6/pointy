import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/customer_asset.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/assets/view_models/asset_details_view_model.dart';
import 'package:pointy_frontend/src/features/assets/views/asset_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Handing an item to its next owner, and — more importantly — NOT handing it
/// over.
///
/// The note field's controller used to live in the calling method and be
/// disposed the moment `showDialog` returned, which is *before* the dialog's
/// exit animation has finished with it: the next frame rebuilt the field
/// against a disposed controller and took the asset screen down with it.
void main() {
  const manager = PosUser(
    id: 1,
    username: 'manager',
    displayName: 'مدير',
    role: UserRole.manager,
    isActive: true,
  );

  const buyer = Customer(
    id: 42,
    customerNumber: 'C-42',
    fullName: 'سالم المشتري',
    phone: '0910000000',
    email: '',
    gender: CustomerGender.unspecified,
    marketingConsent: false,
    notes: '',
    isActive: true,
  );

  testWidgets('backing out transfers nothing and leaves the screen standing', (
    tester,
  ) async {
    final repository = _FakeOperationsRepository();
    await _pumpAsset(tester, repository: repository, user: manager);
    final l10n = _l10n(tester);

    await _openTransferDialog(tester, buyer, l10n);
    expect(find.text(l10n.assetTransferDialogTitle), findsOneWidget);
    // The dialog names who the item would go to, so nobody confirms blind.
    expect(find.text(buyer.fullName), findsWidgets);

    await tester.tap(find.text(l10n.cancelButton));
    await tester.pumpAndSettle();

    expect(repository.transferredTo, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming carries the typed note through', (tester) async {
    final repository = _FakeOperationsRepository();
    await _pumpAsset(tester, repository: repository, user: manager);
    final l10n = _l10n(tester);

    await _openTransferDialog(tester, buyer, l10n);
    await tester.enterText(_dialogField, 'بيع مستعمل');
    await tester.tap(find.text(l10n.assetTransferConfirm));
    await tester.pumpAndSettle();

    expect(repository.transferredTo, buyer.id);
    expect(repository.transferNote, 'بيع مستعمل');
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming without a note is still a transfer', (tester) async {
    final repository = _FakeOperationsRepository();
    await _pumpAsset(tester, repository: repository, user: manager);
    final l10n = _l10n(tester);

    await _openTransferDialog(tester, buyer, l10n);
    await tester.tap(find.text(l10n.assetTransferConfirm));
    await tester.pumpAndSettle();

    // An empty note is an answer — "yes, hand it over, nothing to add" — and
    // must not read as a cancellation.
    expect(repository.transferredTo, buyer.id);
    expect(repository.transferNote, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening and cancelling it twice is clean', (tester) async {
    await _pumpAsset(tester, user: manager);
    final l10n = _l10n(tester);

    for (var i = 0; i < 2; i += 1) {
      await _openTransferDialog(tester, buyer, l10n);
      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
  });
}

/// The field inside the dialog — the screen behind it has its own.
final Finder _dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _openTransferDialog(
  WidgetTester tester,
  Customer buyer,
  AppLocalizations l10n,
) async {
  final trigger = find.text(l10n.assetTransferButton);
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  // Choosing the new owner comes first; that is what opens the note dialog.
  await tester.tap(find.text(buyer.fullName).last);
  await tester.pumpAndSettle();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(AssetDetailsScreen)))!;

CustomerAssetDetail _detail() {
  return CustomerAssetDetail.fromJson({
    'id': 7,
    'customer': 3,
    'customer_name': 'مالك',
    'asset_type': 1,
    'asset_type_name': 'هاتف',
    'brand': 'Nokia',
    'model_name': '3310',
    'display_name': 'Nokia 3310',
    'is_active': true,
    'ownerships': [
      {
        'id': 1,
        'customer': 3,
        'customer_name': 'مالك',
        'is_current': true,
        'note': '',
      },
    ],
    'jobs': const <Object?>[],
  });
}

Future<void> _pumpAsset(
  WidgetTester tester, {
  required PosUser user,
  _FakeOperationsRepository? repository,
}) async {
  final repo = repository ?? _FakeOperationsRepository();
  final viewModel = AssetDetailsViewModel(repo, assetId: 7);
  addTearDown(viewModel.dispose);

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
      theme: PointyTheme.light(),
      home: AssetDetailsScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(user),
        contactRepository: _FakeContactRepository(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository() : super(PosApiService());

  int? transferredTo;
  String? transferNote;

  @override
  Future<Result<CustomerAssetDetail>> loadCustomerAsset(int assetId) async =>
      Ok(_detail());

  @override
  Future<Result<CustomerAsset>> transferCustomerAsset(
    int assetId, {
    required int customer,
    String note = '',
  }) async {
    transferredTo = customer;
    transferNote = note;
    return Ok(_detail().asset);
  }
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());

  @override
  Future<Result<CustomerPage>> loadCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    return const Ok(
      CustomerPage(
        customers: [
          Customer(
            id: 42,
            customerNumber: 'C-42',
            fullName: 'سالم المشتري',
            phone: '0910000000',
            email: '',
            gender: CustomerGender.unspecified,
            marketingConsent: false,
            notes: '',
            isActive: true,
          ),
        ],
        hasMore: false,
      ),
    );
  }
}
