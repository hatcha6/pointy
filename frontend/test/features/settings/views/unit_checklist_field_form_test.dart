import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/features/settings/view_models/unit_checklist_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/unit_checklist_field_form.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../unit_checklist_fakes.dart';

/// The editor for one checklist field. The two promises it keeps for the
/// server: a list field always has options, and a saved field's kind of
/// answer is never offered for change — the units' recorded values depend on
/// it.
void main() {
  late AppLocalizations l10n;
  late List<UnitAttributeDefinition> sent;
  late UnitAttributeDefinition? result;
  late UnitChecklistSaveOutcome Function(UnitAttributeDefinition) answer;

  Future<void> open(
    WidgetTester tester, {
    UnitAttributeDefinition? initial,
    Size size = const Size(1366, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sent = [];
    result = null;
    answer = UnitChecklistSaveOutcome.saved;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: PointyTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context)!;
              return FilledButton(
                onPressed: () async {
                  result = await showUnitChecklistFieldEditor(
                    context,
                    assetTypeId: 7,
                    kindName: 'هاتف',
                    initial: initial,
                    onSave: (draft) async {
                      sent.add(draft);
                      return answer(draft);
                    },
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> pickType(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('unit-checklist-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('unit-checklist-save')));
    await tester.pumpAndSettle();
  }

  DropdownButton<String> typeDropdown(WidgetTester tester) =>
      tester.widget(find.byType(DropdownButton<String>));

  testWidgets('a nameless field is refused before the server is asked', (
    tester,
  ) async {
    await open(tester);

    await save(tester);

    expect(find.text(l10n.unitChecklistLabelRequired), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('a list field needs at least one option', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-label')),
      'لون الهيكل',
    );
    await pickType(tester, l10n.unitChecklistTypeChoice);

    await save(tester);

    expect(find.text(l10n.unitChecklistChoicesRequired), findsOneWidget);
    expect(sent, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-choice-0')),
      'أسود',
    );
    await tester.tap(find.byKey(const ValueKey('unit-checklist-add-choice')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-choice-1')),
      ' ذهبي ',
    );
    await save(tester);

    final draft = sent.single;
    expect(draft.dataType, UnitAttributeType.choice);
    expect(draft.assetTypeId, 7);
    expect(
      [for (final choice in draft.choices) choice.label],
      ['أسود', 'ذهبي'],
    );
    // New options carry no value: the server mints one.
    expect(draft.choices.every((choice) => choice.value.isEmpty), isTrue);
    expect(result?.label, 'لون الهيكل');
  });

  testWidgets('the same option twice is refused', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-label')),
      'اللون',
    );
    await pickType(tester, l10n.unitChecklistTypeChoice);
    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-choice-0')),
      'أسود',
    );
    await tester.tap(find.byKey(const ValueKey('unit-checklist-add-choice')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-choice-1')),
      'أسود',
    );

    await save(tester);

    expect(
      find.text(l10n.unitChecklistChoiceDuplicate('أسود')),
      findsOneWidget,
    );
    expect(sent, isEmpty);
  });

  testWidgets('a unit is asked for numbers only', (tester) async {
    await open(tester);

    expect(find.byKey(const ValueKey('unit-checklist-suffix')), findsNothing);
    await pickType(tester, l10n.unitChecklistTypeNumber);
    expect(find.byKey(const ValueKey('unit-checklist-suffix')), findsOneWidget);
  });

  testWidgets('editing locks the kind of answer and says why', (tester) async {
    final grade = phoneChecklist()[1];
    await open(tester, initial: grade);

    expect(typeDropdown(tester).onChanged, isNull);
    expect(find.text(l10n.unitChecklistTypeLocked), findsOneWidget);
    expect(find.text(l10n.unitChecklistTypeChoice), findsOneWidget);
    // The stored options are there to rename, with their values kept.
    expect(find.text('ممتاز +'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-choice-0')),
      'ممتاز جدًا',
    );
    await save(tester);

    final draft = sent.single;
    expect(draft.id, grade.id);
    expect(draft.choices.first.value, 'a_plus');
    expect(draft.choices.first.label, 'ممتاز جدًا');
    expect(draft.isRequired, isTrue);
    expect(draft.showOnLabel, isTrue);
  });

  testWidgets('the server refusal sits under the field it names', (
    tester,
  ) async {
    await open(tester, initial: phoneChecklist().first);
    answer = (_) => const UnitChecklistSaveOutcome.refused(
      fieldErrors: {'label': 'اسم الحقل لا يتجاوز 80 حرفًا.'},
    );

    await save(tester);

    expect(find.text('اسم الحقل لا يتجاوز 80 حرفًا.'), findsOneWidget);
    // Still open, so the owner can fix it.
    expect(find.byKey(const ValueKey('unit-checklist-save')), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('a refusal naming nothing is shown as one sentence', (
    tester,
  ) async {
    await open(tester, size: const Size(390, 844));
    answer = (_) =>
        UnitChecklistSaveOutcome.refused(error: badRequest({'detail': 'x'}));
    await tester.enterText(
      find.byKey(const ValueKey('unit-checklist-label')),
      'Face ID',
    );

    await save(tester);

    expect(find.text(l10n.errorUnexpectedMessage), findsOneWidget);
  });
}
