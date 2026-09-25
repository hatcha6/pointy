import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_category_query.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/category_management_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/category_management_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

const _drinks = ProductCategory(id: 1, name: 'مشروبات');
const _cards = ProductCategory(
  id: 2,
  name: 'كروت قريب',
  isQuickAccess: true,
  isSystem: true,
);

/// The category a provider's shelf keeps is marked as automatic and cannot be
/// deleted from the screen — the next sync would only make it again. Editing
/// and pinning stay, because the shop arranges it like any other.
void main() {
  testWidgets('the shelf category is marked automatic and offers no delete', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final l10n = lookupAppLocalizations(const Locale('ar'));
    final viewModel = CategoryManagementViewModel(_StubCatalogRepository());
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: CategoryManagementScreen(
          viewModel: viewModel,
          navigation: FakeAppNavigation(
            currentUser: PosUser.fromJson(const {
              'id': 1,
              'username': 'manager',
              'display_name': 'مدير النظام',
              'email': '',
              'role': 'manager',
              'permissions': <String>[],
              'is_active': true,
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One badge: the shelf's row. The shop's own category carries none.
    expect(find.text(l10n.categorySystemBadge), findsOneWidget);
    expect(find.byTooltip(l10n.categorySystemTooltip), findsOneWidget);

    // Rows come in the order the stub lists them: the shop's, then the shelf's.
    final menus = find.byTooltip(l10n.categoryActionsTooltip);
    expect(menus, findsNWidgets(2));

    await tester.tap(menus.last);
    await tester.pumpAndSettle();
    expect(find.text(l10n.editButton), findsOneWidget);
    expect(find.text(l10n.addSubcategoryAction), findsOneWidget);
    expect(find.text(l10n.deleteButton), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(menus.first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.deleteButton), findsOneWidget);
  });
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository()
    : super(
        PosApiService(
          baseUrl: 'http://pointy.test/api',
          client: MockClient((_) async => http.Response('', 500)),
        ),
      );

  @override
  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async => const Ok(
    ProductCategoryPage(categories: [_drinks, _cards], hasMore: false),
  );

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      const Ok([]);
}
