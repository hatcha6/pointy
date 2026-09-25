import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/catalog/quick_access_category_strip.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _drinks = ProductCategory(id: 1, name: 'مشروبات', isQuickAccess: true);
const _cards = ProductCategory(
  id: 2,
  name: 'كروت قريب',
  isQuickAccess: true,
  displayOrder: 1,
  isSystem: true,
);

/// The provider's shelf is pinned for the till, where its cards are sold. The
/// purchasing catalog never lists a provider's cards, so there the same chip
/// would open onto an empty grid.
void main() {
  testWidgets('the till offers the provider shelf beside the shop chips', (
    tester,
  ) async {
    await _pumpStrip(tester, includeSystemCategories: true);

    expect(find.text(_drinks.name), findsOneWidget);
    expect(find.text(_cards.name), findsOneWidget);
  });

  testWidgets('purchasing leaves the provider shelf out', (tester) async {
    await _pumpStrip(tester, includeSystemCategories: false);

    expect(find.text(_drinks.name), findsOneWidget);
    expect(find.text(_cards.name), findsNothing);
  });
}

Future<void> _pumpStrip(
  WidgetTester tester, {
  required bool includeSystemCategories,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Scaffold(
        body: QuickAccessCategoryStrip(
          catalogRepository: _StubCatalogRepository(const [_drinks, _cards]),
          selectedCategories: const [],
          allLabel: 'الكل',
          onSelectAll: () {},
          onSelectCategory: (_) {},
          includeSystemCategories: includeSystemCategories,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository(this._pinned)
    : super(
        PosApiService(
          baseUrl: 'http://pointy.test/api',
          client: MockClient((_) async => http.Response('', 500)),
        ),
      );

  final List<ProductCategory> _pinned;

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      Ok(_pinned);
}
