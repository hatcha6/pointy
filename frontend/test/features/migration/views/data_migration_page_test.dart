import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';
import 'package:pointy_frontend/src/features/migration/views/data_migration_page.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../migration_fakes.dart';

Widget _wrap(MigrationViewModel viewModel) {
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
    builder: (context, child) => PointyNavigationRailScope(
      isActive: false,
      controller: PointyNavigationRailController(),
      child: child ?? const SizedBox.shrink(),
    ),
    home: DataMigrationPage(viewModel: viewModel),
  );
}

void main() {
  Map<String, Object?> source({String state = 'ready', String error = ''}) => {
    'id': 1,
    'name': 'db.mdb',
    'original_filename': 'db.mdb',
    'declared_size_bytes': 1610612736,
    'received_bytes': 1610612736,
    'upload_state': state,
    'error_message': error,
    'system_key': 'fahd',
    'detected_version': 'fahd-mdb-recon-1',
    'detection': const {
      'matched': true,
      'system_key': 'fahd',
      'display_name': 'برنامج فهد',
      'detected_version': 'fahd-mdb-recon-1',
    },
    'supported_entities': const ['product', 'sale'],
    'analysis': const {
      'entities': {
        'product': {'count': 34112},
        'sale': {'count': 892441},
      },
      'history_from': '2019-03-14',
      'history_to': '2026-08-29',
    },
    'stages': const [
      {
        'key': 'identify',
        'label': 'التعرف على الملف',
        'status': 'done',
        'percent': 100,
        'detail': 'قاعدة بيانات Microsoft Access',
      },
      {
        'key': 'convert',
        'label': 'تحويل قاعدة البيانات',
        'status': 'running',
        'percent': 56,
        'detail': 'الجدول 34 من 61 · control',
      },
      {
        'key': 'detect',
        'label': 'التعرف على النظام',
        'status': 'pending',
        'percent': 0,
      },
    ],
  };

  /// Pumps the page and lets its first load resolve.
  ///
  /// Deliberately not `pumpAndSettle`: a running stage carries an indeterminate
  /// spinner and a preparing source polls on a timer, so nothing ever settles
  /// — which is correct behaviour and would otherwise be untestable.
  Future<MigrationViewModel> pump(
    WidgetTester tester,
    FakeMigrationRepository repository,
  ) async {
    final viewModel = MigrationViewModel(repository);
    await tester.pumpWidget(_wrap(viewModel));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return viewModel;
  }

  testWidgets('the first screen asks for a file and nothing else', (
    tester,
  ) async {
    final viewModel = await pump(tester, FakeMigrationRepository());

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationChooseTitle), findsOneWidget);
    expect(find.text(l10n.migrationPickFileButton), findsOneWidget);
    // No trace of the connection console this replaced.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    viewModel.dispose();
  });

  testWidgets('preparation names the stage it is on and what comes after', (
    tester,
  ) async {
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(sources: [source(state: 'preparing')]),
    );

    expect(find.byType(PointyStageTimeline), findsOneWidget);
    expect(find.text('تحويل قاعدة البيانات'), findsOneWidget);
    // The live detail line is the whole point: at twenty minutes, a bare
    // percentage is indistinguishable from a hang.
    expect(find.text('الجدول 34 من 61 · control'), findsOneWidget);
    expect(find.text('التعرف على النظام'), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('a file we cannot read says so in the hero and at the stage', (
    tester,
  ) async {
    const message = 'هذا ملف مضغوط (ZIP) — نحتاج ملف قاعدة البيانات نفسه.';
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(
        sources: [source(state: 'failed', error: message)],
      ),
    );

    expect(find.text(message), findsWidgets);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationPreparationFailedTitle), findsOneWidget);
    expect(find.text(l10n.migrationTryAnotherFileButton), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('an upload in progress offers a way out, not only a pause', (
    tester,
  ) async {
    // Cancelling the transfer leaves the file on the server, so the wizard
    // returns to this same step offering to resume it. For a file that is the
    // wrong one — or one the server keeps refusing — there was nothing else on
    // the screen and no way back to the picker.
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(sources: [source(state: 'uploading')]),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationResumeUploadButton), findsOneWidget);
    expect(find.text(l10n.migrationTryAnotherFileButton), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('preparation can be abandoned', (tester) async {
    // Conversion can run for minutes, and a file it will never read looks
    // exactly like one it is halfway through.
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(sources: [source(state: 'preparing')]),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationTryAnotherFileButton), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('abandoning asks first, then deletes the file', (tester) async {
    final repository = FakeMigrationRepository(
      sources: [source(state: 'preparing')],
    );
    final viewModel = await pump(tester, repository);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.migrationTryAnotherFileButton));
    await tester.pump();
    expect(find.text(l10n.migrationDiscardFileConfirm), findsOneWidget);

    // Backing out of the question changes nothing.
    await tester.tap(find.text(l10n.cancelButton));
    await tester.pump();
    expect(repository.discarded, isEmpty);

    await tester.tap(find.text(l10n.migrationTryAnotherFileButton));
    await tester.pump();
    await tester.tap(find.text(l10n.deleteButton));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(repository.discarded, [1]);
    expect(find.text(l10n.migrationChooseTitle), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('the review step leads with real counts, separated', (
    tester,
  ) async {
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(sources: [source()]),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationFoundTitle), findsOneWidget);
    expect(find.text('برنامج فهد'), findsOneWidget);
    expect(find.text('34,112'), findsOneWidget);
    expect(find.text('892,441'), findsOneWidget);
    // Import stays gated until a dry run has passed.
    expect(find.text(l10n.migrationPreviewButton), findsOneWidget);
    expect(find.text(l10n.migrationImportButton), findsNothing);
    viewModel.dispose();
  });

  testWidgets('a clean dry run unlocks the import', (tester) async {
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(
        sources: [source()],
        runs: const [
          {
            'id': 7,
            'source': 1,
            'mode': 'dry_run',
            'status': 'succeeded',
            'summary': {
              'product': {
                'created': 34112,
                'updated': 0,
                'skipped': 0,
                'failed': 0,
              },
            },
          },
        ],
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationDryRunCleanTitle), findsOneWidget);
    expect(find.text(l10n.migrationImportButton), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('finishing says the file was deleted', (tester) async {
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(
        sources: [source(state: 'purged')],
        runs: const [
          {
            'id': 8,
            'source': 1,
            'mode': 'import',
            'status': 'succeeded',
            'progress_message': 'اكتمل النقل.',
            'summary': {
              'product': {
                'created': 34112,
                'updated': 0,
                'skipped': 0,
                'failed': 0,
              },
            },
          },
        ],
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationDoneTitle), findsOneWidget);
    // The promise the first screen made, kept out loud.
    expect(find.text(l10n.migrationFileDeletedNotice), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('the step rail tracks where the work actually is', (
    tester,
  ) async {
    final viewModel = await pump(
      tester,
      FakeMigrationRepository(sources: [source(state: 'preparing')]),
    );

    final rail = tester.widget<PointyStepRail>(find.byType(PointyStepRail));
    expect(rail.currentIndex, 2);
    expect(rail.steps, hasLength(5));
    viewModel.dispose();
  });
}
