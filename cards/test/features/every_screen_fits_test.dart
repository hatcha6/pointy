import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/dev/cards_preview.dart';
import 'package:pointy_cards/src/app.dart';

/// Every screen on the smallest phones and at the largest text, in the app's
/// real font: the test font's square letters overflow where Arabic does not,
/// and miss what Arabic does. An overflow fails its test.
void main() {
  setUpAll(() async {
    final font = FontLoader('packages/pointy_brand/IBMPlexSansArabic');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(
        rootBundle.load(
          'packages/pointy_brand/assets/fonts/IBMPlexSansArabic-$weight.ttf',
        ),
      );
    }
    await font.load();
  });

  const screens = [
    'home',
    'my-cards',
    'account',
    'brand',
    'brand-itunes',
    'topup-saved',
    'topup-zone',
    'topup-server',
    'topup-telegram',
    'topup-steam',
    'topup-gift',
    'topup-checkout',
    'topup-preparing',
    'topup-done',
    'topup-receipt',
    'topup-refunded',
    'sign-in',
    'sign-in-code',
    'checkout',
    'wallet-code',
    'preparing',
    'preparing-slow',
    'refunded',
    'reveal',
    'card-pay',
    'about',
    'onboarding',
    'onboarding-question',
    'heard-from',
    'sign-in-heard-from',
    'reward',
    'creator',
    'referral',
    'privacy',
    'terms',
  ];

  for (final (size, text) in const [
    (Size(320, 568), 1.0),
    (Size(320, 844), 1.3),
    (Size(320, 844), 2.0),
    (Size(390, 844), 2.0),
  ]) {
    group('${size.width.toInt()}x${size.height.toInt()}, text x$text', () {
      for (final screen in screens) {
        testWidgets(screen, (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = text;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            CardsApp(
              dependencies: fixtureDependencies(),
              home: PreviewSurface(screen: screen),
            ),
          );
          // Sheets open after the first frame and take a moment to rise.
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpWidget(const SizedBox());
          // What the screen left running, like a resend countdown, ends.
          await tester.pump(const Duration(seconds: 15));
        });
      }
    });
  }
}
