import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/services/repair_intake_printables.dart';
import 'package:pointy_frontend/src/features/settings/views/repair_ticket_settings_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The repair receipt's conditions are a list the owner builds, not a text box
/// they have to format: add one, fix one, drop one, put them in order. A shop
/// that never touched them prints the defaults; a shop that cleared them all
/// prints none — two different answers the editor must keep apart.
void main() {
  final defaults = const RepairTicketLabels.arabic().defaultTerms;

  Widget app(Widget child) => MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;

  /// Opens the editor over a button and returns what it hands back.
  Future<RepairTicketTermsEdit? Function()> openDialog(
    WidgetTester tester, {
    List<String>? initialTerms,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    RepairTicketTermsEdit? result;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showDialog<RepairTicketTermsEdit>(
                context: context,
                builder: (_) =>
                    RepairTicketTermsDialog(initialTerms: initialTerms),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('repair_ticket_terms_done_button')),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addTerm(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey('repair_ticket_term_field')),
      text,
    );
    await tester.tap(
      find.byKey(const ValueKey('add_repair_ticket_term_button')),
    );
    await tester.pumpAndSettle();
  }

  group('the settings card', () {
    testWidgets('an untouched shop sees the defaults it prints', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          RepairTicketTermsField(terms: null, enabled: true, onManage: () {}),
        ),
      );

      expect(
        find.text(l10n(tester).repairTicketTermsDefaultNotice),
        findsOneWidget,
      );
      expect(find.text(defaults.first), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('a shop\'s own list is shown in its order', (tester) async {
      await tester.pumpWidget(
        app(
          RepairTicketTermsField(
            terms: const ['الأول', 'الثاني'],
            enabled: true,
            onManage: () {},
          ),
        ),
      );

      expect(find.text('الأول'), findsOneWidget);
      expect(find.text('الثاني'), findsOneWidget);
      expect(
        find.text(l10n(tester).repairTicketTermsDefaultNotice),
        findsNothing,
      );
    });

    testWidgets('a cleared list says nothing will print', (tester) async {
      await tester.pumpWidget(
        app(
          RepairTicketTermsField(
            terms: const [],
            enabled: true,
            onManage: () {},
          ),
        ),
      );

      expect(
        find.text(l10n(tester).repairTicketTermsNoneMessage),
        findsOneWidget,
      );
    });
  });

  group('the editor', () {
    testWidgets('starts from the defaults and keeps them if nothing changes', (
      tester,
    ) async {
      final result = await openDialog(tester);

      expect(
        find.text(l10n(tester).repairTicketTermsEditingDefaultsNotice),
        findsOneWidget,
      );
      expect(find.text(defaults.first), findsOneWidget);
      await save(tester);

      // Still "print the defaults" — not a frozen copy of today's wording.
      expect(result()!.terms, isNull);
    });

    testWidgets('adding a term makes the list the shop\'s own', (tester) async {
      final result = await openDialog(tester, initialTerms: const ['الأول']);

      await addTerm(tester, '  لا يسلم الجهاز\nإلا لحامل الإيصال  ');
      await save(tester);

      expect(result()!.terms, ['الأول', 'لا يسلم الجهاز إلا لحامل الإيصال']);
    });

    testWidgets('an empty or repeated term is refused, with a reason', (
      tester,
    ) async {
      await openDialog(tester, initialTerms: const ['الأول']);

      await addTerm(tester, '   ');
      expect(
        find.text(l10n(tester).repairTicketTermRequiredError),
        findsOneWidget,
      );

      await addTerm(tester, 'الأول');
      expect(
        find.text(l10n(tester).repairTicketTermDuplicateError),
        findsOneWidget,
      );
    });

    testWidgets('removing a term drops it, and removing all prints none', (
      tester,
    ) async {
      final result = await openDialog(
        tester,
        initialTerms: const ['الأول', 'الثاني'],
      );

      await tester.tap(
        find.byKey(const ValueKey('remove_repair_ticket_term_0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('الأول'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('remove_repair_ticket_term_0')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10n(tester).repairTicketTermsNoneMessage),
        findsOneWidget,
      );
      await save(tester);

      expect(result()!.terms, isEmpty);
    });

    testWidgets('a term can be rewritten in place', (tester) async {
      final result = await openDialog(
        tester,
        initialTerms: const ['الأول', 'الثاني'],
      );

      await tester.tap(find.byKey(const ValueKey('edit_repair_ticket_term_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit_repair_ticket_term_field')),
        'الثاني بعد التعديل',
      );
      await tester.tap(find.text(l10n(tester).saveButton).last);
      await tester.pumpAndSettle();
      await save(tester);

      expect(result()!.terms, ['الأول', 'الثاني بعد التعديل']);
    });

    testWidgets('a rewrite that repeats another term is refused in place', (
      tester,
    ) async {
      final result = await openDialog(
        tester,
        initialTerms: const ['الأول', 'الثاني'],
      );

      await tester.tap(find.byKey(const ValueKey('edit_repair_ticket_term_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit_repair_ticket_term_field')),
        ' الأول ',
      );
      await tester.tap(find.text(l10n(tester).saveButton).last);
      await tester.pumpAndSettle();

      // Still open, saying why — not closed with the rewrite quietly dropped.
      expect(
        find.byKey(const ValueKey('edit_repair_ticket_term_field')),
        findsOneWidget,
      );
      expect(
        find.text(l10n(tester).repairTicketTermDuplicateError),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n(tester).cancelButton).last);
      await tester.pumpAndSettle();
      await save(tester);

      expect(result()!.terms, ['الأول', 'الثاني']);
    });

    testWidgets('dragging a term moves it', (tester) async {
      final result = await openDialog(
        tester,
        initialTerms: const ['الأول', 'الثاني', 'الثالث'],
      );

      final handle = find.byIcon(Icons.drag_indicator).first;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 50));
      for (var step = 0; step < 10; step++) {
        await gesture.moveBy(const Offset(0, 16));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      await save(tester);

      expect(result()!.terms!.first, 'الثاني');
      expect(result()!.terms!.toSet(), {'الأول', 'الثاني', 'الثالث'});
    });

    testWidgets('restoring the defaults hands the choice back to the app', (
      tester,
    ) async {
      final result = await openDialog(tester, initialTerms: const ['الأول']);

      await tester.tap(
        find.byKey(const ValueKey('restore_repair_ticket_terms_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text(defaults.first), findsOneWidget);
      await save(tester);

      expect(result()!.terms, isNull);
    });
  });

  testWidgets('saving from the section sends the list with everything else', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ShopSettingsDraft? sent;
    final settings = ShopSettings.fromJson(const {
      'shop_name': 'محل النور',
      'repair_diagnosis_fee': '10.00',
      'repair_ticket_terms': ['الأول'],
    });
    await tester.pumpWidget(
      app(
        RepairTicketSettingsSection(
          settings: settings,
          enabled: true,
          onSave: (draft) async {
            sent = draft;
            return true;
          },
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('manage_repair_ticket_terms_button')),
    );
    await tester.pumpAndSettle();
    await addTerm(tester, 'الثاني');
    await save(tester);

    expect(sent!.repairTicketTerms, ['الأول', 'الثاني']);
    // Nothing the terms editor does not show is reset by saving it.
    expect(sent!.repairDiagnosisFee, 10);
    expect(sent!.shopName, 'محل النور');
  });
}
