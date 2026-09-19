import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';

import '../migration_fakes.dart';

/// The wizard's step is *derived* from server state rather than stored, so that
/// closing the page during a twenty-minute conversion and coming back lands on
/// the work rather than restarting it. These lock that mapping down — it is the
/// one piece of logic that decides what the owner sees.
void main() {
  Map<String, Object?> sourceJson({
    String state = 'ready',
    String systemKey = 'fahd',
    String error = '',
  }) => {
    'id': 1,
    'name': 'db.mdb',
    'original_filename': 'db.mdb',
    'declared_size_bytes': 1000,
    'received_bytes': state == 'uploading' ? 400 : 1000,
    'upload_percent': state == 'uploading' ? 40 : 100,
    'upload_state': state,
    'error_message': error,
    'system_key': systemKey,
    'supported_entities': const ['product', 'sale'],
    'analysis': const {
      'entities': {
        'product': {'count': 34112},
        'sale': {'count': 892441, 'from': '2019-03-14', 'to': '2026-08-29'},
      },
      'history_from': '2019-03-14',
      'history_to': '2026-08-29',
    },
    'stages': const [
      {'key': 'identify', 'label': 'التعرف', 'status': 'done', 'percent': 100},
    ],
  };

  Map<String, Object?> runJson({
    String mode = 'dry_run',
    String status = 'succeeded',
    int failed = 0,
  }) => {
    'id': 7,
    'source': 1,
    'mode': mode,
    'status': status,
    'summary': {
      'product': {
        'created': 34112,
        'updated': 0,
        'skipped': 0,
        'failed': failed,
      },
    },
  };

  Future<MigrationViewModel> loaded(FakeMigrationRepository repository) async {
    final viewModel = MigrationViewModel(repository);
    await viewModel.load();
    return viewModel;
  }

  test('no source at all means step one', () async {
    final viewModel = await loaded(FakeMigrationRepository());
    expect(viewModel.step, MigrationStep.choose);
  });

  test('a half-received upload resumes rather than restarting', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(sources: [sourceJson(state: 'uploading')]),
    );
    expect(viewModel.step, MigrationStep.uploading);
    expect(viewModel.source!.receivedBytes, 400);
    expect(viewModel.source!.uploadPercent, 40);
  });

  test('preparation in flight shows the stage timeline', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(sources: [sourceJson(state: 'preparing')]),
    );
    expect(viewModel.step, MigrationStep.preparing);
    expect(viewModel.stages, isNotEmpty);
  });

  test('a file we could not read explains itself', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(
        sources: [sourceJson(state: 'failed', error: 'هذا ملف مضغوط (ZIP)')],
      ),
    );
    expect(viewModel.step, MigrationStep.failed);
    expect(viewModel.source!.errorMessage, contains('ZIP'));
  });

  test('a prepared file lands on review with its counts', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(sources: [sourceJson()]),
    );
    expect(viewModel.step, MigrationStep.review);
    expect(viewModel.analysis.countFor('product'), 34112);
    expect(viewModel.analysis.historyFrom, '2019-03-14');
    // Everything the connector supports is on by default.
    expect(viewModel.selectedEntities, {'product', 'sale'});
  });

  test('a finished import shows its result, not the file picker', () async {
    // The regression this guards: a purged source used to skip run adoption, so
    // a successful migration dropped the owner back to "pick a file".
    final viewModel = await loaded(
      FakeMigrationRepository(
        sources: [sourceJson(state: 'purged')],
        runs: [runJson(mode: 'import')],
      ),
    );
    expect(viewModel.step, MigrationStep.done);
    expect(viewModel.source!.isPurged, isTrue);
    expect(viewModel.lastRun!.totalCreated, 34112);
  });

  test('import is gated on a clean dry run', () async {
    final dirty = await loaded(
      FakeMigrationRepository(
        sources: [sourceJson()],
        runs: [runJson(failed: 3, status: 'partial')],
      ),
    );
    expect(dirty.canImport, isFalse);

    final clean = await loaded(
      FakeMigrationRepository(sources: [sourceJson()], runs: [runJson()]),
    );
    expect(clean.canImport, isTrue);
  });

  test('an import that has not been previewed cannot be run', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(sources: [sourceJson()]),
    );
    expect(viewModel.canImport, isFalse);
  });

  test('a purged source with no import is not treated as finished', () async {
    // Discarding a file leaves a purged source and no run; that is "start over",
    // not "you are done".
    final viewModel = await loaded(
      FakeMigrationRepository(sources: [sourceJson(state: 'purged')]),
    );
    expect(viewModel.step, MigrationStep.choose);
  });

  test('a live upload wins over an already-purged one', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(
        sources: [
          sourceJson(state: 'purged'),
          sourceJson(state: 'ready'),
        ],
      ),
    );
    expect(viewModel.source!.isReady, isTrue);
  });
}
