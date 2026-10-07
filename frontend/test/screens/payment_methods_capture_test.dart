// Renders the till's payment sheet to PNG, headlessly, so the method tiles
// and the confirm button that names the method can be looked at instead of
// described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/payment_methods_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';

ThemeData _withButtonFont(ThemeData theme) {
  ButtonStyle patch(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = style?.textStyle?.resolve(states);
        return (resolved ?? const TextStyle()).copyWith(
          fontFamily: PointyTypography.fontFamily,
        );
      }),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: patch(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patch(theme.textButtonTheme.style),
    ),
  );
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    // Arabic needs the app's font, and button labels resolve to Roboto, which
    // has no Arabic: point both at IBM Plex Sans Arabic.
    for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final iconFont = File(
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  });

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    bool dark = false,
    String? tap,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
        home: Scaffold(
          body: PaymentSheet(
            total: 47.5,
            enableCashPayments: true,
            enableCardPayments: true,
            enableTransferPayments: true,
            requireCardReceipt: false,
            trustedCardTerminalIds: const [],
            showPrintInvoiceToggle: true,
            printInvoiceAfterPayment: true,
            onPrintInvoiceChanged: (_) {},
            showShareInvoiceToggle: false,
            shareInvoiceAfterPayment: false,
            onShareInvoiceChanged: (_) {},
            hasCustomer: false,
            requireCustomerForCredit: false,
            onSubmit: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.byKey(ValueKey(tap)));
      await tester.pumpAndSettle();
    }
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/payment_methods_$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  // The 1024 x 768 till, the most common counter screen.
  const till = Size(1024, 768);
  const phone = Size(390, 844);

  testWidgets('cash, till', (tester) async {
    await shoot(tester, name: 'cash_till', size: till);
  }, skip: !_capture);

  testWidgets('card, till', (tester) async {
    await shoot(
      tester,
      name: 'card_till',
      size: till,
      tap: 'payment_method_card',
    );
  }, skip: !_capture);

  testWidgets('transfer, till, dark', (tester) async {
    await shoot(
      tester,
      name: 'transfer_till_dark',
      size: till,
      dark: true,
      tap: 'payment_method_transfer',
    );
  }, skip: !_capture);

  testWidgets('cash, phone', (tester) async {
    await shoot(tester, name: 'cash_phone', size: phone);
  }, skip: !_capture);
}
