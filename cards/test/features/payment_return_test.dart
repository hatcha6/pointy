import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/l10n/generated/app_localizations.dart';
import 'package:pointy_cards/src/features/card_payment/payment_page_view.dart';
import 'package:pointy_cards/src/shared/web_edges.dart';

void main() {
  test("the payment page's «المتابعة» goes to the relay's return page", () {
    expect(
      PaymentPageView.isReturn(
        Uri.parse('https://my.dftr.ly/v1/customers/payment-return'),
      ),
      isTrue,
    );
    for (final other in [
      'https://localbankcards.dafa.ly/o-1',
      'https://cards.dftr.ly/my-cards/o-1',
      'https://my.dftr.ly/v1/customers/card-return',
    ]) {
      expect(
        PaymentPageView.isReturn(Uri.parse(other)),
        isFalse,
        reason: other,
      );
    }
  });

  testWidgets('the payment page closes itself once the order is settled', (
    tester,
  ) async {
    final settled = ValueNotifier(false);
    PaymentPageResult? closedAs;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ar'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => PaymentPageView.open(
              context,
              url: Uri.parse('https://localbankcards.dafa.ly/o-1'),
              changes: settled,
              settled: () => settled.value,
            ).then((result) => closedAs = result),
            child: const Text('pay'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pay'));
    await tester.pumpAndSettle();
    expect(find.byType(PaymentPageView), findsOneWidget);
    // The address the payer would see in a browser.
    expect(find.text('localbankcards.dafa.ly'), findsOneWidget);

    settled.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(PaymentPageView), findsNothing);
    // Whoever opened it hears why it closed.
    expect(closedAs, PaymentPageResult.settled);
  });

  testWidgets('closing the payment page by hand tells whoever opened it', (
    tester,
  ) async {
    PaymentPageResult? closedAs;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ar'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => PaymentPageView.open(
              context,
              url: Uri.parse('https://localbankcards.dafa.ly/o-1'),
              changes: ValueNotifier(false),
              settled: () => false,
            ).then((result) => closedAs = result),
            child: const Text('pay'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pay'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(PaymentPageView), findsNothing);
    expect(find.text('pay'), findsOneWidget);
    expect(closedAs, PaymentPageResult.closed);
  });

  test(
    "Safari's strips: one colour, or the top above and the bottom below",
    () {
      expect(
        edgesCss(top: const Color(0xFF0B0F14), bottom: const Color(0xFF0B0F14)),
        '#0b0f14',
      );
      expect(
        edgesCss(top: const Color(0xFF0B0F14), bottom: const Color(0xFF151A21)),
        'linear-gradient(#0b0f14 50%, #151a21 50%)',
      );
    },
  );
}
