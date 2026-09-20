import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';

/// One provider names itself; several collapse into a menu. The point is that
/// the header does not grow a button every time a provider is added, and that
/// a cashier can see which account they are about to spend before they tap.
void main() {
  Widget harness(Widget child) {
    return MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    );
  }

  testWidgets('a single provider gets its own name on the button', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      harness(
        PosRechargeButton(
          providers: const ['hdbox'],
          onSelected: (key) => chosen = key,
        ),
      ),
    );

    expect(find.text('شحن HD Box'), findsOneWidget);
    await tester.tap(find.text('شحن HD Box'));
    await tester.pumpAndSettle();
    // Straight through — no menu to wade past when there is only one.
    expect(chosen, 'hdbox');
  });

  testWidgets('several providers collapse into one menu', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      harness(
        PosRechargeButton(
          providers: const ['hdbox', 'lnet'],
          onSelected: (key) => chosen = key,
        ),
      ),
    );

    // One generic trigger, not a button per provider.
    expect(find.text('شحن اشتراك'), findsOneWidget);
    expect(find.text('شحن HD Box'), findsNothing);

    await tester.tap(find.text('شحن اشتراك'));
    await tester.pumpAndSettle();

    // Each provider named in the menu, so the cashier picks the account.
    expect(find.text('HD Box'), findsOneWidget);
    expect(find.text('LNET'), findsOneWidget);

    await tester.tap(find.text('LNET'));
    await tester.pumpAndSettle();
    expect(chosen, 'lnet');
  });

  testWidgets('no providers draws nothing at all', (tester) async {
    // A grocer must not be able to tell this feature shipped.
    await tester.pumpWidget(
      harness(PosRechargeButton(providers: const [], onSelected: (_) {})),
    );
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });
}
