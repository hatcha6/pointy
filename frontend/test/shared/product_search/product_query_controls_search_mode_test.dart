import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/product_query_controls.dart';
import 'package:pointy_frontend/src/shared/product_search/product_search_mode_controller.dart';

/// The product search on the till, purchasing and the catalog, with and
/// without the search-mode picker a device can turn on in its settings.
void main() {
  const pickerKey = ValueKey('product_search_mode_picker');
  const fieldKey = ValueKey('lookup');

  testWidgets('a device that never turned it on keeps the plain search', (
    tester,
  ) async {
    final host = _Host();
    await host.pump(tester);

    expect(find.byKey(pickerKey), findsNothing);
    expect(find.text('ابحث عن منتج أو امسح الباركود'), findsOneWidget);

    // Nor does a scope with the switch off draw one.
    await host.pump(tester, controller: ProductSearchModeController());
    expect(find.byKey(pickerKey), findsNothing);
  });

  testWidgets('the picker narrows the search and the hint follows it', (
    tester,
  ) async {
    final host = _Host();
    await host.pump(
      tester,
      controller: ProductSearchModeController(pickerEnabled: true),
    );

    expect(find.byKey(pickerKey), findsOneWidget);
    expect(_pickerText('الكل'), findsOneWidget);
    // The ordinary search keeps the screen's own hint.
    expect(find.text('ابحث عن منتج أو امسح الباركود'), findsOneWidget);

    await _pick(tester, ProductSearchMode.name);

    expect(host.changes.single.searchMode, ProductSearchMode.name);
    expect(_pickerText('الاسم'), findsOneWidget);
    expect(find.text('ابحث باسم المنتج'), findsOneWidget);

    await _pick(tester, ProductSearchMode.code);

    expect(host.changes.last.searchMode, ProductSearchMode.code);
    expect(_pickerText('الرمز'), findsOneWidget);
    expect(find.text('ابحث بالباركود أو رمز المنتج'), findsOneWidget);

    // Choosing what is already chosen is not a change worth a reload.
    await _pick(tester, ProductSearchMode.code);
    expect(host.changes, hasLength(2));
  });

  testWidgets('the menu names what each mode reads', (tester) async {
    final host = _Host();
    await host.pump(
      tester,
      controller: ProductSearchModeController(pickerEnabled: true),
    );

    await tester.tap(find.byKey(pickerKey));
    await tester.pumpAndSettle();

    expect(find.text('الاسم والرمز والباركود معًا'), findsOneWidget);
    expect(find.text('الباركود أو رمز المنتج فقط'), findsOneWidget);
    expect(find.text('اسم المنتج فقط'), findsOneWidget);
  });

  testWidgets('picking a mode hands the keyboard back to the search field', (
    tester,
  ) async {
    // The till's search is where the scanner's keystrokes land; a picker that
    // kept focus would send the next scan nowhere.
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final host = _Host(focusNode: focusNode);
    await host.pump(
      tester,
      controller: ProductSearchModeController(pickerEnabled: true),
    );
    await tester.tap(find.byKey(fieldKey));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await _pick(tester, ProductSearchMode.name);

    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('switching the picker off puts a narrowed search back', (
    tester,
  ) async {
    final controller = ProductSearchModeController(pickerEnabled: true);
    final host = _Host(
      initial: const ProductQuery(
        search: '330',
        searchMode: ProductSearchMode.name,
      ),
    );
    await host.pump(tester, controller: controller);
    expect(host.changes, isEmpty);

    await controller.setPickerEnabled(false);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(pickerKey), findsNothing);
    expect(host.changes, hasLength(1));
    expect(host.changes.single.searchMode, ProductSearchMode.all);
    // Only the mode moves; what the cashier typed stays.
    expect(host.changes.single.search, '330');
  });

  testWidgets('a screen that opens with the picker off drops a stale mode', (
    tester,
  ) async {
    // The till keeps its query while the cashier visits device settings, so
    // the screen it returns to may still carry the mode from before.
    final host = _Host(
      initial: const ProductQuery(
        search: '330',
        searchMode: ProductSearchMode.code,
      ),
    );
    await host.pump(tester, controller: ProductSearchModeController());
    await tester.pump();

    expect(host.changes.single.searchMode, ProductSearchMode.all);
  });

  testWidgets('a narrow bar keeps the picker to its icon', (tester) async {
    final host = _Host();
    await host.pump(
      tester,
      controller: ProductSearchModeController(pickerEnabled: true),
      width: 420,
    );

    expect(find.byKey(pickerKey), findsOneWidget);
    expect(_pickerText('الكل'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(pickerKey),
        matching: find.byIcon(Icons.manage_search),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Finder _pickerText(String text) => find.descendant(
  of: find.byKey(const ValueKey('product_search_mode_picker')),
  matching: find.text(text),
);

Future<void> _pick(WidgetTester tester, ProductSearchMode mode) async {
  await tester.tap(find.byKey(const ValueKey('product_search_mode_picker')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('product_search_mode_${mode.name}')));
  await tester.pumpAndSettle();
}

/// Stands in for a screen's view model: holds the query, applies every change
/// the search bar asks for, and records them.
class _Host {
  _Host({ProductQuery initial = const ProductQuery(), this.focusNode})
    : query = ValueNotifier(initial);

  final ValueNotifier<ProductQuery> query;
  final FocusNode? focusNode;
  final changes = <ProductQuery>[];

  Future<void> pump(
    WidgetTester tester, {
    ProductSearchModeController? controller,
    double width = 800,
  }) async {
    if (controller != null) {
      addTearDown(controller.dispose);
    }
    Widget controls = ValueListenableBuilder<ProductQuery>(
      valueListenable: query,
      builder: (context, value, _) => ProductQueryControls(
        query: value,
        catalogRepository: CatalogRepository(PosApiService()),
        searchHint: 'ابحث عن منتج أو امسح الباركود',
        searchFieldKey: const ValueKey('lookup'),
        searchFocusNode: focusNode,
        onSearchChanged: (search) =>
            _apply(query.value.copyWith(search: search)),
        onQueryChanged: _apply,
      ),
    );
    if (controller != null) {
      controls = ProductSearchModeScope(
        controller: controller,
        child: controls,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: width, child: controls),
          ),
        ),
      ),
    );
  }

  void _apply(ProductQuery next) {
    changes.add(next);
    query.value = next;
  }
}
