// Renders the direct top-up dialog (each step) and «أسعار كروت دفتر» (both
// tabs) to PNG, headlessly. Skipped in an ordinary run; capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/services_v2_capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/airtime_flow_sheet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/voucher_pricing_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/voucher_pricing_screen.dart';

import 'package:pointy_frontend/dev/services_fake_repository.dart';

import '../support/pricing_testing.dart';
import '../support/services_testing.dart';
import '../support/test_fonts.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';
final String _outDir =
    Platform.environment['POINTY_CAPTURE_DIR'] ??
    '/private/tmp/claude-501/-Users-hatem-Develop-pointy/'
        '9d48eb8d-a142-48de-bcfa-af051c11dc17/scratchpad/services_ui';

void main() {
  setUpAll(() async {
    if (!_capture) return;
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

  testWidgets('airtime dialog steps', (tester) async {
    debugDisableShadows = false;
    useWindow(tester, const Size(560, 760));
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
    await save(tester, shot, 'v2_airtime_1_country');

    await tester.tap(key('service_country_popular_ML'));
    await play(tester);
    await tester.enterText(key('service_phone_field'), '70123456');
    await play(tester, 15);
    await save(tester, shot, 'v2_airtime_2_number');

    await tester.tap(key('airtime_next'));
    await play(tester);
    await save(tester, shot, 'v2_airtime_3_amount');

    await tester.tap(key('service_amount_5000'));
    await play(tester, 15);
    await tester.tap(key('airtime_next'));
    await play(tester, 15);
    await save(tester, shot, 'v2_airtime_4_summary');
    debugDisableShadows = true;
  }, skip: !_capture);

  testWidgets('pricing cards under cost', (tester) async {
    debugDisableShadows = false;
    useWindow(tester, const Size(900, 760));
    final vm = VoucherPricingViewModel(FakePricingRepository());
    addTearDown(vm.dispose);
    final shot = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: servicesApp(
          Builder(
            builder: (_) => VoucherPricingScreen(viewModel: vm, initialTab: 1),
          ),
        ),
      ),
    );
    await play(tester, 15);
    await save(tester, shot, 'v4_below_cost');
    debugDisableShadows = true;
  }, skip: !_capture);

  for (final (name, tab) in [('services', 0), ('cards', 1)]) {
    testWidgets('pricing $name', (tester) async {
      debugDisableShadows = false;
      useWindow(tester, const Size(900, 760));
      final vm = VoucherPricingViewModel(FakePricingRepository());
      addTearDown(vm.dispose);
      final shot = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: shot,
          child: servicesApp(
            Builder(
              builder: (_) =>
                  VoucherPricingScreen(viewModel: vm, initialTab: tab),
            ),
          ),
        ),
      );
      await play(tester, 15);
      await save(tester, shot, 'v2_pricing_$name');
      debugDisableShadows = true;
    }, skip: !_capture);
  }
}
