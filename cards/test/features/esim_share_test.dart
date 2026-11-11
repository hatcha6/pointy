import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/esim/esim_destination_page.dart';
import 'package:pointy_cards/src/features/esim/esim_store_page.dart';

const _share = MethodChannel('dev.fluttercommunity.plus/share');

void main() {
  late List<Uri> shared;

  setUp(() {
    shared = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_share, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>;
          shared.add(Uri.parse(arguments['uri']! as String));
          return 'dev.fluttercommunity.plus/share/success';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_share, null);
  });

  Future<void> open(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CardsApp(dependencies: fixtureDependencies(esim: true), home: page),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the eSIM shelf shares itself as it is filtered', (tester) async {
    await open(
      tester,
      const EsimStorePage(
        filter: EsimShelfFilter(minDays: 30, minMb: 5120, offersOnly: true),
      ),
    );
    await tester.tap(find.byTooltip('مشاركة'));
    await tester.pumpAndSettle();
    expect(shared.single.host, 'cards.dftr.ly');
    expect(shared.single.path, '/esim');
    expect(shared.single.queryParameters, {
      'days': '30',
      'gb': '5',
      'offers': '1',
    });
  });

  testWidgets('a destination shares its link, and a plan its own', (
    tester,
  ) async {
    await open(
      tester,
      const EsimDestinationPage(destination: 'turkey', name: 'تركيا'),
    );
    await tester.tap(find.byTooltip('مشاركة'));
    await tester.pumpAndSettle();
    expect(shared.single.path, '/esim/turkey');

    // The plan's sheet has its own button, beside the one that buys.
    await tester.tap(find.textContaining('66.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('مشاركة').last);
    await tester.pumpAndSettle();
    expect(shared.last.path, '/esim/turkey/merhaba-30days-3gb');
  });
}
