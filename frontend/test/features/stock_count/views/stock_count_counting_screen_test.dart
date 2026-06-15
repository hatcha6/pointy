import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_counting_screen.dart';

void main() {
  testWidgets('counting keypad does not overflow on a wide POS screen', (
    WidgetTester tester,
  ) async {
    // A wide-but-short surface: an unbounded 3-column keypad would be ~950px
    // tall here and overflow. The width cap keeps it within the column.
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final session = StockCount(
      id: 1,
      countNumber: 'SC-1',
      status: StockCountStatus.inProgress,
      scope: StockCountScope.full,
      expectedLineCount: 25,
      countedLineCount: 0,
      varianceLineCount: 0,
    );
    final capabilities = AuthorizationCapabilities.forUser(
      PosUser.fromJson({
        'id': 1,
        'username': 'manager',
        'role': 'manager',
        'permissions': const <String>[],
      }),
    );

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
        home: StockCountCountingScreen(
          session: session,
          stockCountRepository: StockCountRepository(PosApiService()),
          catalogRepository: _StubCatalogRepository(
            const ProductVariant(
              id: 5,
              productId: 1,
              sku: 'SKU-5',
              displayName: 'صنف تجريبي',
              unitPrice: 1,
            ),
          ),
          capabilities: capabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Simulate a hardware-wedge scan to select an item, which reveals the keypad.
    for (final key in const [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // The keypad is now visible (item selected) and laid out without overflow.
    expect(
      find.byKey(const ValueKey('payment_keypad_digit_5')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository(this._variant) : super(PosApiService());

  final ProductVariant _variant;

  @override
  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    return Ok(_variant);
  }
}
