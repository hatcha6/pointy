// Renders the voucher menu under a typed search and the airtime summary with
// its read-back to PNG, headlessly. Skipped in an ordinary run; capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/services_v3_capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/airtime_flow_sheet.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_service_shelves.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_menu.dart';

import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/dev/voucher_menu_fixtures.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';

import '../support/services_testing.dart';
import '../support/test_fonts.dart';
import '../support/voucher_search_testing.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';
final String _outDir =
    Platform.environment['POINTY_CAPTURE_DIR'] ??
    '/private/tmp/claude-501/-Users-hatem-Develop-pointy/'
        '9d48eb8d-a142-48de-bcfa-af051c11dc17/scratchpad/services_ui';

void main() {
  setUpAll(() async {
    if (!_capture) return;
    PointyProductImageFrame.debugImageOverride = voucherPreviewArtResolver;
    await loadAppFonts();
    final iconFont = File(
      '${Platform.environment['FLUTTER_ROOT'] ?? Directory(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path}'
      '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
    Directory(_outDir).createSync(recursive: true);
  });

  Future<void> play(WidgetTester tester, [int tenths = 12]) async {
    for (var i = 0; i < tenths; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> save(WidgetTester tester, GlobalKey key, String file) async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    File('$_outDir/$file.png').writeAsBytesSync(bytes!);
  }

  Finder key(String name) => find.byKey(ValueKey(name));

  testWidgets('search on the voucher menu', (tester) async {
    debugDisableShadows = false;
    useWindow(tester, const Size(1100, 700));
    final shelves = PosServiceShelves(repository: PreviewServicesRepository());
    addTearDown(shelves.dispose);
    final search = ValueNotifier('');
    final shot = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: servicesApp(
          ValueListenableBuilder<String>(
            valueListenable: search,
            builder: (context, text, _) => PosVoucherMenuView(
              menu: searchMenu(),
              animateSkeleton: false,
              shelves: shelves,
              onBrandSelected: (_) {},
              search: text,
              onClearSearch: () => search.value = '',
            ),
          ),
        ),
      ),
    );
    await play(tester, 10);
    for (final (query, file) in [
      ('visa', 'v3_search_visa'),
      ('apple', 'v3_search_apple'),
      ('كهرباء', 'v3_search_electricity'),
      ('قهوة', 'v3_search_empty'),
    ]) {
      search.value = query;
      await play(tester, 10);
      await save(tester, shot, file);
    }
    debugDisableShadows = true;
  }, skip: !_capture);

  testWidgets('airtime summary read-back', (tester) async {
    debugDisableShadows = false;
    useWindow(tester, const Size(560, 860));
    final harness = AirtimeHarness(repository: PreviewServicesRepository());
    final shot = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: servicesApp(
          Center(
            child: SizedBox(
              width: 520,
              child: AirtimeFlowSheet(
                viewModel: harness.viewModel,
                onAdd: harness.accept,
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await play(tester, 20);
    await tester.tap(key('service_country_popular_ML'));
    await play(tester);
    await tester.enterText(key('service_phone_field'), '70123456');
    await play(tester, 15);
    await tester.tap(key('airtime_next'));
    await play(tester);
    await tester.tap(key('service_amount_5000'));
    await play(tester, 15);
    await tester.tap(key('airtime_next'));
    await play(tester, 15);
    await save(tester, shot, 'v3_airtime_summary');
    debugDisableShadows = true;
  }, skip: !_capture);
}
