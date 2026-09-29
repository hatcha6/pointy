import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/search_miss.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/search_misses_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/search_misses_screen.dart';
import 'package:pointy_frontend/src/shared/authorization_denied_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';
import '../search_miss_test_support.dart';

final _now = DateTime(2026, 9, 29, 12);
final _l10n = lookupAppLocalizations(const Locale('ar'));

PosUser _user(String role) {
  return PosUser.fromJson({
    'id': 1,
    'username': role,
    'display_name': role,
    'email': '',
    'role': role,
    'permissions': <String>[],
    'is_active': true,
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeSearchMissRepository repository,
  Size size = const Size(1200, 900),
  String role = 'manager',
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final viewModel = SearchMissesViewModel(repository);
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: SearchMissesScreen(
        viewModel: viewModel,
        catalogRepository: _FakeCatalogRepository(),
        navigation: FakeAppNavigation(currentUser: _user(role)),
        now: _now,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists each word with how often, when and where, right to left', (
    tester,
  ) async {
    await _pump(
      tester,
      repository: FakeSearchMissRepository([
        miss(1, 'ارز', count: 3, surface: SearchMissSurface.purchasing),
        miss(
          2,
          'كاتشب575',
          count: 12,
          lastSeenAt: DateTime(2026, 9, 28, 18, 5),
        ),
      ]),
    );

    expect(find.text(_l10n.searchMissesTitle), findsOneWidget);
    expect(find.text(_l10n.searchMissesHint), findsOneWidget);
    final ketchup = find.text('كاتشب575');
    expect(ketchup, findsOneWidget);
    expect(Directionality.of(tester.element(ketchup)), TextDirection.rtl);
    expect(
      find.text('بُحث عنها 12 مرة · آخرها أمس 18:05 · في شاشة البيع'),
      findsOneWidget,
    );
    expect(
      find.text('بُحث عنها 3 مرات · آخرها اليوم 09:59 · في المشتريات'),
      findsOneWidget,
    );
    // Most typed first.
    expect(
      tester.getTopLeft(ketchup).dy,
      lessThan(tester.getTopLeft(find.text('ارز')).dy),
    );
    expect(find.text(_l10n.searchMissResolveButton), findsNWidgets(2));
    expect(find.text(_l10n.searchMissDismissButton), findsNWidgets(2));
  });

  test('counts read as Arabic does', () {
    expect(_l10n.searchMissCount(1), 'بُحث عنها مرة واحدة');
    expect(_l10n.searchMissCount(2), 'بُحث عنها مرتين');
    expect(_l10n.searchMissCount(7), 'بُحث عنها 7 مرات');
    expect(_l10n.searchMissCount(12), 'بُحث عنها 12 مرة');
    expect(_l10n.searchMissCount(100), 'بُحث عنها 100 مرة');
  });

  testWidgets('choosing the product teaches the word and takes the row off', (
    tester,
  ) async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 3),
      miss(2, 'كاتشب575', count: 12),
    ]);
    await _pump(tester, repository: repository, size: const Size(400, 860));

    await tester.tap(find.text(_l10n.searchMissResolveButton).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('ما المنتج الذي قصده'), findsOneWidget);

    await tester.tap(find.text('كاتشب هاينز - 575 غ'));
    await tester.pumpAndSettle();

    expect(repository.actions, ['resolve 2 -> 42']);
    expect(find.text('كاتشب575'), findsNothing);
    expect(find.text('ارز'), findsOneWidget);
    final snack = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(Text),
    );
    final message = tester.widget<Text>(snack.first).data!;
    expect(message, contains('كاتشب575'));
    expect(message, contains('كاتشب هاينز'));
    expect(message, startsWith('سيجد البحث عن'));
  });

  testWidgets('a refused product keeps the row and says why', (tester) async {
    final repository = FakeSearchMissRepository([miss(2, 'كاتشب575')])
      ..actionError = const PosApiException(
        message: 'Search miss resolve failed 400',
        statusCode: 400,
        responseBody: '{"product": ["A product a feature owns."]}',
      );
    await _pump(tester, repository: repository);

    await tester.tap(find.text(_l10n.searchMissResolveButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('كاتشب هاينز - 575 غ'));
    await tester.pumpAndSettle();

    expect(find.text('كاتشب575'), findsOneWidget);
    expect(find.text(_l10n.searchMissProductRefused), findsOneWidget);
  });

  testWidgets('dismissing takes the row away, and undo brings it back', (
    tester,
  ) async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 3),
      miss(2, 'كاتشب575', count: 12),
    ]);
    await _pump(tester, repository: repository);

    await tester.tap(find.text(_l10n.searchMissDismissButton).first);
    await tester.pumpAndSettle();

    expect(find.text('كاتشب575'), findsNothing);
    expect(find.textContaining('تم تجاهل'), findsOneWidget);

    await tester.tap(find.text(_l10n.undoButton));
    await tester.pumpAndSettle();

    expect(repository.actions, ['dismiss 2', 'reopen 2']);
    expect(find.text('كاتشب575'), findsOneWidget);
  });

  testWidgets('a failed dismissal keeps the row', (tester) async {
    final repository = FakeSearchMissRepository([miss(1, 'ارز')])
      ..actionError = Exception('offline');
    await _pump(tester, repository: repository);

    await tester.tap(find.text(_l10n.searchMissDismissButton));
    await tester.pumpAndSettle();

    expect(find.text('ارز'), findsOneWidget);
    expect(find.text(_l10n.searchMissActionError), findsOneWidget);
  });

  testWidgets('the linked words show their product and can be reopened', (
    tester,
  ) async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز'),
      miss(
        2,
        'كاتشب575',
        status: SearchMissStatus.resolved,
        productId: 42,
        productName: 'كاتشب هاينز',
      ),
    ]);
    await _pump(tester, repository: repository);

    await tester.tap(find.text(_l10n.searchMissesFilterResolved));
    await tester.pumpAndSettle();

    expect(find.text('ارز'), findsNothing);
    expect(find.text(_l10n.searchMissLinkedTo('كاتشب هاينز')), findsOneWidget);

    await tester.tap(find.text(_l10n.searchMissReopenButton));
    await tester.pumpAndSettle();

    expect(repository.actions, ['reopen 2']);
    expect(find.text('كاتشب575'), findsNothing);
    expect(find.text(_l10n.searchMissesEmptyResolved), findsOneWidget);
  });

  testWidgets('an empty list says how it fills', (tester) async {
    await _pump(tester, repository: FakeSearchMissRepository(const []));

    expect(find.text(_l10n.searchMissesEmptyTitle), findsOneWidget);
    expect(find.text(_l10n.searchMissesEmptyMessage), findsOneWidget);
    expect(find.text(_l10n.searchMissesHint), findsNothing);
  });

  testWidgets('a failed load offers a retry', (tester) async {
    final repository = FakeSearchMissRepository([miss(1, 'ارز')])
      ..failingPages.add(1);
    await _pump(tester, repository: repository);

    expect(find.text(_l10n.searchMissesLoadError), findsOneWidget);

    repository.failingPages.clear();
    await tester.tap(find.text(_l10n.retryButton));
    await tester.pumpAndSettle();

    expect(find.text('ارز'), findsOneWidget);
  });

  testWidgets('someone who may not change products is turned away', (
    tester,
  ) async {
    await _pump(
      tester,
      repository: FakeSearchMissRepository([miss(1, 'ارز')]),
      role: 'cashier',
    );

    expect(find.byType(AuthorizationDeniedView), findsOneWidget);
    expect(find.text('ارز'), findsNothing);
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository()
    : super(PosApiService(baseUrl: 'http://pointy.test/api'));

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    return const Ok(
      ProductVariantPage(
        variants: [
          ProductVariant(
            id: 5,
            productId: 42,
            productName: 'كاتشب هاينز',
            name: '575 غ',
            sku: 'KT-575',
            unitPrice: 12.5,
          ),
        ],
        hasMore: false,
      ),
    );
  }
}
