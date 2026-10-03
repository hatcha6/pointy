import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/components/pointy_shortcuts_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../support/shortcut_sheet_reading.dart';

/// The cheat sheet's keycaps have a grammar a cashier reads at a glance: "+"
/// joins keys pressed together, "/" joins keys that each work alone. The POS
/// sheet once drew "Ctrl / Enter", which reads as "either key checks out".
void main() {
  Future<void> pump(WidgetTester tester, Widget sheet) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Material(child: sheet),
        ),
      ),
    );
  }

  testWidgets('keys pressed together join with "+", alternatives with "/"', (
    tester,
  ) async {
    await pump(
      tester,
      const PointyShortcutsSheet(
        title: 'اختصارات لوحة المفاتيح',
        groups: [
          PointyShortcutGroup('الفواتير', [
            PointyShortcut(['Ctrl', 'Enter'], 'إتمام البيع'),
            PointyShortcut.either([
              'Page ↓',
              'Page ↑',
            ], 'التنقّل بين الفواتير المعلّقة'),
            PointyShortcut.either(['+', '−'], 'زيادة أو إنقاص واحد'),
          ]),
        ],
      ),
    );

    // Left to right inside the RTL sheet: never "Enter + Ctrl".
    expect(shortcutKeysBeside(tester, 'إتمام البيع'), ['Ctrl', '+', 'Enter']);
    expect(shortcutKeysBeside(tester, 'التنقّل بين الفواتير المعلّقة'), [
      'Page ↓',
      '/',
      'Page ↑',
    ]);
    // A "+" keycap is a key, not a joiner.
    expect(shortcutKeysBeside(tester, 'زيادة أو إنقاص واحد'), ['+', '/', '−']);
  });

  testWidgets('the subtitle sits under the title, the note under the keys', (
    tester,
  ) async {
    await pump(
      tester,
      const PointyShortcutsSheet(
        title: 'اختصارات لوحة المفاتيح',
        subtitle: 'تعمل من أي مكان في شاشة البيع',
        groups: [
          PointyShortcutGroup('الأصناف', [
            PointyShortcut(['F4'], 'حذف الصنف المحدد'),
          ]),
        ],
        note: 'المسح بالقارئ يعمل وأنت في أي حقل',
      ),
    );

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(
      top('تعمل من أي مكان في شاشة البيع'),
      greaterThan(top('اختصارات لوحة المفاتيح')),
    );
    expect(
      top('تعمل من أي مكان في شاشة البيع'),
      lessThan(top('حذف الصنف المحدد')),
    );
    expect(
      top('المسح بالقارئ يعمل وأنت في أي حقل'),
      greaterThan(top('حذف الصنف المحدد')),
    );
  });
}
