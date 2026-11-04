import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_expiry_reminder_section.dart';

import 'bulk_price_test_support.dart';

class _Repository extends CatalogRepository {
  _Repository() : super(PosApiService());

  final List<DateTime?> saved = [];
  bool fail = false;

  @override
  Future<Result<ProductVariant>> setVariantExpiryReminder(
    int variantId,
    DateTime? date,
  ) async {
    saved.add(date);
    if (fail) return Error(Exception('offline'));
    return Ok(
      ProductVariant(
        id: variantId,
        productId: 1,
        sku: 'A',
        unitPrice: 1,
        expiryReminderDate: date,
      ),
    );
  }
}

AuthorizationCapabilities _manager() => AuthorizationCapabilities.forUser(
  PosUser.fromJson(const {
    'id': 1,
    'username': 'm',
    'display_name': 'م',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  }),
);

Product _product({
  DateTime? reminder,
  bool isService = false,
  TrackingMode mode = TrackingMode.quantity,
}) => Product(
  id: 1,
  name: 'حليب',
  quantityOnHand: 3,
  isService: isService,
  trackingMode: mode,
  defaultVariant: ProductVariant(
    id: 7,
    productId: 1,
    sku: 'A',
    unitPrice: 1,
    expiryReminderDate: reminder,
  ),
);

void main() {
  Future<_Repository> pump(WidgetTester tester, Product product) async {
    await setSurface(tester, const Size(700, 900));
    final repository = _Repository();
    await tester.pumpWidget(
      bulkPriceApp(
        Scaffold(
          body: ProductExpiryReminderSection(
            product: product,
            capabilities: _manager(),
            catalogRepository: repository,
          ),
        ),
      ),
    );
    return repository;
  }

  testWidgets('sets a reminder typed as month/year, saved as month end', (
    tester,
  ) async {
    final repository = await pump(tester, _product());
    expect(find.text('لم يُحدَّد'), findsOneWidget);
    expect(find.byKey(const ValueKey('expiry_reminder_clear')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('expiry_reminder_edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('expiry_reminder_field')),
        matching: find.byType(EditableText),
      ),
      '12/27',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('expiry_reminder_save')));
    await tester.pumpAndSettle();

    expect(repository.saved, [DateTime(2027, 12, 31)]);
    expect(find.text('لم يُحدَّد'), findsNothing);
    expect(find.byKey(const ValueKey('expiry_reminder_clear')), findsOneWidget);
  });

  testWidgets('clearing sends an explicit null', (tester) async {
    final repository = await pump(
      tester,
      _product(reminder: DateTime(2027, 3, 31)),
    );
    expect(find.text('لم يُحدَّد'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('expiry_reminder_clear')));
    await tester.pumpAndSettle();

    expect(repository.saved, [null]);
    expect(find.text('لم يُحدَّد'), findsOneWidget);
  });

  testWidgets('a failed save keeps the old date and says so', (tester) async {
    final repository = await pump(
      tester,
      _product(reminder: DateTime(2027, 3, 31)),
    );
    repository.fail = true;

    await tester.tap(find.byKey(const ValueKey('expiry_reminder_clear')));
    await tester.pumpAndSettle();

    expect(find.text('تعذّر حفظ التذكير. حاول مجددًا.'), findsOneWidget);
    expect(find.text('لم يُحدَّد'), findsNothing);
  });

  testWidgets('hidden for services and serial products', (tester) async {
    await pump(tester, _product(isService: true));
    expect(find.byType(Card), findsNothing);
    expect(find.text('تذكير انتهاء الصلاحية'), findsNothing);

    await pump(tester, _product(mode: TrackingMode.serial));
    await tester.pump();
    expect(find.text('تذكير انتهاء الصلاحية'), findsNothing);
  });
}
