import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/migration.dart';
import 'package:pointy_frontend/src/data/repositories/migration_repository.dart';
import 'package:pointy_frontend/src/data/services/migration_uploader.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';
import 'package:pointy_frontend/src/features/migration/views/data_migration_page.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

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
    _FakeRepository repository,
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
    final viewModel = await pump(tester, _FakeRepository());

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
    final viewModel = await pump(      tester,
      _FakeRepository(sources: [source(state: 'preparing')]),
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
    final viewModel = await pump(      tester,
      _FakeRepository(sources: [source(state: 'failed', error: message)]),
    );

    expect(find.text(message), findsWidgets);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.migrationPreparationFailedTitle), findsOneWidget);
    expect(find.text(l10n.migrationTryAnotherFileButton), findsOneWidget);
    viewModel.dispose();
  });

  testWidgets('the review step leads with real counts, separated', (
    tester,
  ) async {
    final viewModel = await pump(tester, _FakeRepository(sources: [source()]));

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
    final viewModel = await pump(      tester,
      _FakeRepository(
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
    final viewModel = await pump(      tester,
      _FakeRepository(
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
    final viewModel = await pump(      tester,
      _FakeRepository(sources: [source(state: 'preparing')]),
    );

    final rail = tester.widget<PointyStepRail>(find.byType(PointyStepRail));
    expect(rail.currentIndex, 2);
    expect(rail.steps, hasLength(5));
    viewModel.dispose();
  });
}

class _FakeRepository implements MigrationRepository {
  _FakeRepository({this.sources = const [], this.runs = const []});

  final List<Map<String, Object?>> sources;
  final List<Map<String, Object?>> runs;

  @override
  Future<Result<MigrationCatalog>> loadCatalog() async => Ok(
    MigrationCatalog.fromJson(const {
      'systems': [
        {
          'system_key': 'fahd',
          'display_name': 'برنامج فهد',
          'supported_entities': ['product'],
          'versions': ['fahd-mdb-recon-1'],
          'implemented': true,
        },
      ],
      'entities': [
        {'entity_type': 'product', 'label': 'الأصناف', 'implemented': true},
        {'entity_type': 'sale', 'label': 'المبيعات', 'implemented': true},
      ],
      'upload': {'chunk_size': 1024, 'max_bytes': 8589934592},
    }),
  );

  @override
  Future<Result<List<MigrationSource>>> loadSources() async =>
      Ok(sources.map(MigrationSource.fromJson).toList());

  @override
  Future<Result<MigrationSource>> loadSource(int id) async =>
      Ok(MigrationSource.fromJson(sources.first));

  @override
  Future<Result<List<MigrationRun>>> loadRuns({int? sourceId}) async =>
      Ok(runs.map(MigrationRun.fromJson).toList());

  @override
  Future<Result<MigrationRun>> loadRun(int id) async =>
      Ok(MigrationRun.fromJson(runs.first));

  @override
  Future<Result<MigrationRun>> startRun({
    required int sourceId,
    required String mode,
    required List<String> entities,
    Map<String, Object?> options = const {},
  }) async => Ok(MigrationRun.fromJson(const {'id': 1, 'status': 'queued'}));

  @override
  Future<Result<MigrationIssuePage>> loadIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) async => const Ok(MigrationIssuePage(issues: [], hasMore: false));

  @override
  MigrationUploader newUploader() => throw UnimplementedError();

  @override
  Future<Result<MigrationSource>> uploadFile(
    PlatformFile file, {
    required MigrationUploader uploader,
    MigrationSource? resuming,
    void Function(MigrationUploadProgress)? onProgress,
  }) async => Ok(MigrationSource.fromJson(sources.first));

  @override
  Future<Result<MigrationSource>> completeUpload(int id) async =>
      Ok(MigrationSource.fromJson(sources.first));

  @override
  Future<Result<MigrationSource>> discardSource(int id) async =>
      Ok(MigrationSource.fromJson(sources.first));
}
