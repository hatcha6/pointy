// A three-step intake is the longest thing counter staff type into this app.
// An accidental back — a swipe, a hardware key — used to bin all of it without
// a word. These tests pin the guard that stops that, and just as importantly
// pin what does *not* count as work worth stopping for: a stray search query,
// and the warranty box that ships pre-filled.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_intake_wizard.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

final _template = WorkflowTemplate(
  id: 1,
  name: 'تصليح الأجهزة',
  jobType: OperationsJobType.repair,
  isActive: true,
  isSystem: true,
  jobCount: 0,
  stages: const [],
);

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());
}

Widget _app() {
  final repository = _FakeOperationsRepository();
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: JobIntakeWizard(
      template: _template,
      boardViewModel: JobsBoardViewModel(repository),
      contactRepository: _FakeContactRepository(),
      operationsRepository: repository,
    ),
  );
}

/// Simulate the system back gesture, which is what the guard intercepts —
/// an explicit `Navigator.pop` from the save handler deliberately bypasses it.
Future<void> _pressBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

/// Start a new customer and type a name — the cheapest genuinely-unsaved edit
/// reachable on step 1.
Future<void> _enterCustomerName(WidgetTester tester, String name) async {
  final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  await tester.tap(find.text(l10n.intakeNewCustomerButton));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, l10n.intakeCustomerNameLabel),
    name,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an untouched intake leaves without prompting', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byType(JobIntakeWizard), findsOneWidget);
    await _pressBack(tester);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
  });

  testWidgets('a typed-in intake prompts before it is thrown away', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _enterCustomerName(tester, 'زبون جديد');
    await _pressBack(tester);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.unsavedChangesTitle), findsOneWidget);
  });

  testWidgets('keeping editing leaves the typed work exactly where it was', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _enterCustomerName(tester, 'زبون جديد');
    await _pressBack(tester);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.keepEditingButton));
    await tester.pumpAndSettle();

    // The dialog is gone, the wizard is not, and the name survived it.
    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(JobIntakeWizard), findsOneWidget);
    expect(find.text('زبون جديد'), findsOneWidget);
  });

  testWidgets('a stray search query is not work worth stopping for', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    // The search box is deliberately excluded from the dirty check: typing a
    // name to look someone up is not an edit the clerk would mourn.
    await tester.enterText(
      find.widgetWithText(TextField, l10n.intakeSelectCustomerHint),
      'أحمد',
    );
    await tester.pumpAndSettle();

    await _pressBack(tester);
    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
  });
}
