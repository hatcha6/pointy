import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/features/pos/views/voucher_country_flag.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/flags/bundled_flags.dart';

/// Every country's flag ships with the app, so no screen downloads one.
void main() {
  test('every listed flag has its file, and every file is listed', () {
    final files = {
      for (final entry in Directory('assets/flags').listSync())
        if (entry.path.endsWith('.png'))
          entry.uri.pathSegments.last.replaceAll('.png', '').toUpperCase(),
    };
    expect(files, bundledFlagCodes);
    expect(bundledFlagCodes, containsAll(['LY', 'ML', 'NG', 'EU', 'WW']));
  });

  Future<void> pumpFlag(WidgetTester tester, VoucherCountry country) {
    return tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Center(child: VoucherCountryFlag(country: country)),
      ),
    );
  }

  testWidgets('draws the bundled flag, whatever the case of the code', (
    tester,
  ) async {
    await pumpFlag(tester, const VoucherCountry(code: 'ml'));

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(
      (provider.imageProvider as AssetImage).assetName,
      'assets/flags/ml.png',
    );
  });

  testWidgets('shows the code for a country the app has no flag for', (
    tester,
  ) async {
    await pumpFlag(tester, const VoucherCountry(code: 'ZZ'));

    expect(find.byType(Image), findsNothing);
    expect(find.text('ZZ'), findsOneWidget);
  });
}
