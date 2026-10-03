import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchasing_shortcuts_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../support/shortcut_sheet_reading.dart';

/// Purchasing's cheat sheet, on the shared one. Its quantity keys are the
/// ones a joiner can garble: "+" is itself a key, and digits come before
/// Enter rather than with it.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  testWidgets('each pair of alternatives reads as either/or', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPurchasingShortcutsSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(l10n.purchasingShortcutsTitle), findsOneWidget);
    expect(shortcutKeysBeside(tester, l10n.purchasingShortcutStepQuantity), [
      '+',
      '/',
      '−',
    ]);
    expect(shortcutKeysBeside(tester, l10n.purchasingShortcutCycleUnitArrows), [
      '↑',
      '/',
      '↓',
    ]);
    expect(shortcutKeysBeside(tester, l10n.purchasingShortcutTypeQuantity), [
      '0-9',
    ]);
    expect(shortcutKeysBeside(tester, l10n.purchasingShortcutSubmit), [
      'Ctrl',
      '+',
      'Enter',
    ]);
  });
}
