import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';

CardBrand brandAt(int index) => CardBrand.fromJson(
  (fixtureCatalog['brands'] as List)[index] as Map<String, dynamic>,
);

const _share = MethodChannel('dev.fluttercommunity.plus/share');

Future<void> phone(
  WidgetTester tester, {
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = FakeViewPadding(
    left: padding.left * 3,
    right: padding.right * 3,
  );
  addTearDown(tester.view.reset);
}

void main() {
  late List<Map<Object?, Object?>> shared;
  late String result;

  setUp(() {
    shared = [];
    result = 'dev.fluttercommunity.plus/share/success';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_share, (call) async {
          shared.add(call.arguments as Map<Object?, Object?>);
          return result;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_share, null);
  });

  testWidgets('a brand shares its link, on the card on show', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: BrandPage(brand: brandAt(0)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 دينار'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('مشاركة'));
    await tester.pumpAndSettle();
    expect(shared, hasLength(1));
    final link = Uri.parse(shared.single['uri']! as String);
    expect(link.host, 'cards.dftr.ly');
    expect(link.path, '/brand/${brandAt(0).key}');
    expect(link.queryParameters['item'], isNotEmpty);
  });

  testWidgets('no share sheet: the link is copied', (tester) async {
    await phone(tester);
    result = 'dev.fluttercommunity.plus/share/unavailable';
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: BrandPage(brand: brandAt(0)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('مشاركة'));
    await tester.pumpAndSettle();
    expect(copied, startsWith('https://cards.dftr.ly/brand/'));
    expect(find.text('تم نسخ الرابط'), findsOneWidget);
  });

  testWidgets('on the iPhone Duo it stands under the back button, in the '
      'column', (tester) async {
    await phone(tester, padding: const EdgeInsets.only(right: 100));
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: BrandPage(brand: brandAt(0)),
      ),
    );
    await tester.pumpAndSettle();
    final share = find.byTooltip('مشاركة');
    expect(share, findsOneWidget);
    final back = find.byTooltip('رجوع');
    final shareAt = tester.getCenter(share);
    final backAt = tester.getCenter(back.first);
    // The same column, right below.
    expect(shareAt.dx, closeTo(backAt.dx, 0.5));
    expect(shareAt.dy, greaterThan(backAt.dy));
    expect(shareAt.dx, greaterThan(390 - 100));

    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(shared, hasLength(1));
  });
}
