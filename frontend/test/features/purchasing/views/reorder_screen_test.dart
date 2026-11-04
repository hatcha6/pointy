import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/reorder_queue.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/reorder_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/reorder_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/reorder_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../../../shared/fake_app_navigation.dart';

const _row = ReorderRow(
  variantId: 1,
  productId: 1,
  productName: 'حليب',
  variantName: 'كامل الدسم',
  status: ReorderStatus.approaching,
  onHand: 30,
  threshold: 5,
  daysLeft: 5,
  inDraft: 6,
  lastSupplierName: 'مورد أ',
  orderQuantity: 8,
);

class _Repository extends ReorderRepository {
  _Repository({this.rows = const [_row]}) : super(PosApiService());

  final List<ReorderRow> rows;
  List<ReorderOrderLine>? sentLines;

  @override
  Future<Result<ReorderQueue>> loadQueue({
    int? supplierId,
    required bool includeApproaching,
  }) async => Ok(ReorderQueue(rows: rows, totalCount: rows.length));

  @override
  Future<Result<PurchaseOrder>> createOrder({
    required int supplierId,
    required List<ReorderOrderLine> lines,
    String? idempotencyKey,
  }) async {
    sentLines = lines;
    return Error(Exception('refused'));
  }
}

class _Preference extends ReorderApproachingPreference {
  const _Preference();

  @override
  Future<bool> read() async => true;

  @override
  Future<void> write(bool value) async {}
}

const _user = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  Future<ReorderViewModel> pump(
    WidgetTester tester,
    _Repository repository, {
    Size size = const Size(1200, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = ReorderViewModel(
      repository,
      preference: const _Preference(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        builder: (context, child) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: child!,
        ),
        home: ReorderScreen(
          viewModel: viewModel,
          contactRepository: ContactRepository(PosApiService()),
          navigation: FakeAppNavigation(currentUser: _user),
          onOpenPurchaseOrder: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  test('the route asks what drafting a purchase order asks', () {
    expect(
      appNavigationDestinationCapability(AppNavigationDestination.reorder),
      AppCapability.createPurchaseOrder,
    );
  });

  ButtonStyleButton orderButton(WidgetTester tester) {
    return tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('reorder_create_order')),
    );
  }

  testWidgets('without a supplier the order button is off and says why', (
    tester,
  ) async {
    await pump(tester, _Repository());

    await tester.tap(find.byKey(const ValueKey('reorder_row_1')));
    await tester.pump();

    expect(find.text(l10n.reorderSupplierRequiredHint), findsOneWidget);
    expect(orderButton(tester).onPressed, isNull);
  });

  testWidgets('a supplier and a ticked row turn the order button on', (
    tester,
  ) async {
    final viewModel = await pump(tester, _Repository());
    await viewModel.setSupplier(id: 7, name: 'مورد أ');
    await tester.pumpAndSettle();

    expect(orderButton(tester).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('reorder_row_1')));
    await tester.pump();

    expect(orderButton(tester).onPressed, isNotNull);
  });

  testWidgets('a quantity typed with the cursor still in the field is sent', (
    tester,
  ) async {
    final repository = _Repository();
    final viewModel = await pump(tester, repository);
    await viewModel.setSupplier(id: 7, name: 'مورد أ');
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('reorder_quantity_1')),
        matching: find.byType(TextField),
      ),
      '15',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reorder_create_order')));
    await tester.pumpAndSettle();

    expect(repository.sentLines?.single.quantity, 15);
  });

  testWidgets('a refused order says so and stays on the queue', (tester) async {
    final viewModel = await pump(tester, _Repository());
    await viewModel.setSupplier(id: 7, name: 'مورد أ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reorder_row_1')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('reorder_create_order')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.reorderCreateOrderError), findsOneWidget);
    expect(viewModel.isSelected(_row), isTrue);
  });

  testWidgets('the row explains itself', (tester) async {
    await pump(tester, _Repository());

    expect(find.text('حليب — كامل الدسم'), findsOneWidget);
    expect(find.textContaining(l10n.reorderDaysLeft(5)), findsOneWidget);
    expect(
      find.textContaining(l10n.reorderLastSupplier('مورد أ')),
      findsOneWidget,
    );
    expect(find.text(l10n.reorderStatusApproaching), findsOneWidget);
  });

  testWidgets('an empty queue says where rows come from', (tester) async {
    await pump(tester, _Repository(rows: const []));

    expect(find.text(l10n.reorderEmptyTitle), findsOneWidget);
    expect(find.text(l10n.reorderEmptyMessage), findsOneWidget);
  });

  testWidgets('a phone-width screen lays out without overflow', (tester) async {
    await pump(tester, _Repository(), size: const Size(390, 800));

    expect(tester.takeException(), isNull);
    expect(find.text(l10n.reorderColumnStatus), findsNothing);
  });
}
