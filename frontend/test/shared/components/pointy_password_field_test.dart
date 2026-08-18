import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('toggles obscuring and relabels the icon-only button', (
    tester,
  ) async {
    await _pumpField(tester);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(PointyPasswordField)),
    )!;

    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));
    IconButton toggle() => tester.widget<IconButton>(find.byType(IconButton));

    expect(field().obscureText, isTrue);
    expect(toggle().tooltip, l10n.showPasswordTooltip);

    await tester.tap(find.byType(IconButton));
    await tester.pump();

    expect(field().obscureText, isFalse);
    // The tooltip is also the screen-reader label, so it must track the state.
    expect(toggle().tooltip, l10n.hidePasswordTooltip);
  });

  testWidgets('disables the toggle while the field is disabled', (
    tester,
  ) async {
    await _pumpField(tester, enabled: false);

    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
  });
}

Future<void> _pumpField(WidgetTester tester, {bool enabled = true}) async {
  final controller = TextEditingController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: PointyPasswordField(
            controller: controller,
            labelText: 'كلمة المرور',
            enabled: enabled,
          ),
        ),
      ),
    ),
  );
}
