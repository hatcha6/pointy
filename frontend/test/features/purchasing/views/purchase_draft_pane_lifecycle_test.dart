import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Teardown, not happy paths.
///
/// The settings dialog is built with `TextEditingController`s and `FocusNode`s
/// owned by the PANE, not by the dialog — so the pane outliving (or not
/// outliving) the dialog is load-bearing. And the pane publishes closures onto
/// a `PurchaseSubmitController` the workspace above it holds, which must go
/// quiet when the pane goes away or the keyboard would drive a dead widget.
void main() {
  const variant = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'COF-1',
    productName: 'قهوة',
    unitPrice: 10,
  );

  PurchaseViewModel buildViewModel() =>
      PurchaseViewModel(_FakeCatalogRepository(), _FakePurchaseRepository());

  Future<void> pumpPane(
    WidgetTester tester,
    PurchaseViewModel viewModel, {
    PurchaseSubmitController? submitController,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: PurchaseDraftPane(
            viewModel: viewModel,
            contactRepository: _FakeContactRepository(),
            submitController: submitController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Replaces the pane while leaving the app shell (and its theme) in place —
  /// the way a real navigation does. Swapping the whole MaterialApp would also
  /// swap the Theme mid-animation, which throws a text-style interpolation
  /// error of its own and hides what this file is actually testing.
  Future<void> pumpEmpty(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the settings dialog opens, closes and reopens cleanly', (
    tester,
  ) async {
    final viewModel = buildViewModel();
    await pumpPane(tester, viewModel);

    for (var i = 0; i < 2; i += 1) {
      await tester.tap(
        find.byKey(const ValueKey('purchase_draft_settings_button')),
      );
      await tester.pumpAndSettle();
      // Its fields borrow the pane's controllers; a second open must not leave
      // two live fields attached to one controller.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
    viewModel.dispose();
  });

  testWidgets('the pane tears down while its settings dialog is open', (
    tester,
  ) async {
    final viewModel = buildViewModel();
    await pumpPane(tester, viewModel);
    await tester.tap(
      find.byKey(const ValueKey('purchase_draft_settings_button')),
    );
    await tester.pumpAndSettle();

    await pumpEmpty(tester);

    expect(tester.takeException(), isNull);
    viewModel.dispose();
  });

  testWidgets('a disposed pane leaves no live keyboard actions behind', (
    tester,
  ) async {
    final viewModel = buildViewModel();
    final submitController = PurchaseSubmitController();
    await pumpPane(tester, viewModel, submitController: submitController);
    expect(submitController.onSubmit, isNotNull);

    await pumpEmpty(tester);

    expect(
      submitController.onSubmit,
      isNull,
      reason: 'Ctrl+Enter must not reach a pane that is gone',
    );
    expect(submitController.onOpenSettings, isNull);
    expect(tester.takeException(), isNull);
    viewModel.dispose();
  });

  testWidgets('the keyboard submit action is safe to call after teardown', (
    tester,
  ) async {
    final viewModel = buildViewModel();
    final submitController = PurchaseSubmitController();
    await pumpPane(tester, viewModel, submitController: submitController);
    final submit = submitController.onSubmit!;

    await pumpEmpty(tester);
    // A key event already in flight when the pane went away still lands.
    submit();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    viewModel.dispose();
  });

  testWidgets('the pane tears down with lines in the draft', (tester) async {
    final viewModel = buildViewModel();
    await viewModel.addVariant(variant, quantity: 2);
    await pumpPane(tester, viewModel);
    expect(find.text('COF-1'), findsOneWidget);

    await pumpEmpty(tester);

    expect(tester.takeException(), isNull);
    viewModel.dispose();
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(2);
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());

  @override
  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async => const Ok(SupplierPage(suppliers: [], hasMore: false));
}
