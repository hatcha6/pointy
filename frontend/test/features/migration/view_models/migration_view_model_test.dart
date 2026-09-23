import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/migration.dart';
import 'package:pointy_frontend/src/data/services/migration_uploader.dart';
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
    'supported_entities': const [
      'category',
      'product',
      'customer',
      'party_balance',
      'sale',
      'stock',
      'money_account',
    ],
    'supports_stock_filter': true,
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
    // A prepared file opens on the "everything" scope, which is every entity
    // the connector supports — the default is unchanged, it is just named now.
    expect(viewModel.scopeKey, 'everything');
    expect(viewModel.selectedEntities, {
      'category',
      'product',
      'customer',
      'party_balance',
      'sale',
    });
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

  group('walking away from a file the server already has', () {
    test('starting over during an upload lands back on step one', () async {
      // The trap this closes: cancelling the *transfer* left the half-written
      // file on the server, so the wizard came right back to the upload step
      // offering to resume it. For a file the server will not accept, resume
      // was the only button on the screen.
      final repository = FakeMigrationRepository(
        sources: [sourceJson(state: 'uploading')],
      );
      final inFlight = Completer<Result<MigrationSource>>();
      repository.pendingUpload = inFlight;
      final viewModel = await loaded(repository);

      unawaited(viewModel.startUpload());
      expect(viewModel.step, MigrationStep.uploading);

      await viewModel.startOver();

      expect(viewModel.step, MigrationStep.choose);
      expect(viewModel.source, isNull);
      expect(repository.discarded, [1]);

      // The abandoned transfer settling afterwards must not drag the wizard
      // back, nor report the owner's own decision to them as an error.
      inFlight.complete(const Error(MigrationUploadCancelled()));
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.step, MigrationStep.choose);
      expect(viewModel.errorMessage, isNull);
    });

    test('starting over during preparation deletes the file', () async {
      final repository = FakeMigrationRepository(
        sources: [sourceJson(state: 'preparing')],
      );
      final viewModel = await loaded(repository);
      expect(viewModel.step, MigrationStep.preparing);

      await viewModel.startOver();

      expect(viewModel.step, MigrationStep.choose);
      expect(repository.discarded, [1]);
    });

    test('cancelling the transfer alone keeps the resumable file', () async {
      // The other half of the pair: cancel stops the bytes and nothing else,
      // which is what makes a gigabyte upload survive a shop's Wi-Fi.
      final repository = FakeMigrationRepository(
        sources: [sourceJson(state: 'uploading')],
      );
      repository.pendingUpload = Completer<Result<MigrationSource>>();
      final viewModel = await loaded(repository);

      unawaited(viewModel.startUpload());
      viewModel.cancelUpload();

      expect(viewModel.step, MigrationStep.uploading);
      expect(viewModel.source!.receivedBytes, 400);
      expect(repository.discarded, isEmpty);
    });
  });

  group('import scopes', () {
    // Taking part of a shop is not a filter: it changes what the numbers left
    // behind mean. These lock the two places that shows up in the UI — what
    // gets picked, and what the owner is told about the consequences.

    test(
      'a preset picks its entities and the options that go with them',
      () async {
        final viewModel = await loaded(
          FakeMigrationRepository(sources: [sourceJson()]),
        );

        viewModel.applyScope('opening_position');

        expect(viewModel.selectedEntities, {
          'category',
          'product',
          'customer',
          'party_balance',
        });
        // No quantities, but the costs: the two travel with the scope as two
        // separate answers, because as one they were confused in the field.
        expect(viewModel.stockSource, MigrationStockSource.none);
        expect(viewModel.carryCosts, isTrue);
      },
    );

    test('hand-editing the list stops claiming to be a preset', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );
      viewModel.applyScope('opening_position');

      viewModel.toggleEntity('sale', true);

      expect(viewModel.scopeKey, 'custom');
    });

    test('the scope travels with the run', () async {
      final repository = FakeMigrationRepository(sources: [sourceJson()]);
      final viewModel = await loaded(repository);
      viewModel.applyScope('opening_position');

      await viewModel.startRun(dryRun: true);

      expect(repository.startedRuns.single['scope'], 'opening_position');
    });

    test('a hand-made selection sends no scope at all', () async {
      final repository = FakeMigrationRepository(sources: [sourceJson()]);
      final viewModel = await loaded(repository);
      viewModel.toggleEntity('sale', false);

      await viewModel.startRun(dryRun: true);

      expect(repository.startedRuns.single['scope'], isNull);
    });

    test('what a selection drags in with it is named, not implied', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );
      viewModel.applyScope('custom');
      for (final entity in viewModel.selectedEntities.toList()) {
        viewModel.toggleEntity(entity, false);
      }

      viewModel.toggleEntity('sale', true);

      // Sales cannot resolve a line without products, or an owner without
      // customers; the screen says so before the run rather than after.
      expect(viewModel.impliedEntities, containsAll(['product', 'customer']));
    });

    test('leaving the history behind carries todays balances', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );

      viewModel.applyScope('opening_position');

      expect(viewModel.carriesCurrentBalances, isTrue);
    });

    test('bringing the history carries the opening ones instead', () async {
      // Same file, same parties, a different figure — and the difference is
      // every invoice counted twice if it goes the wrong way.
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );

      viewModel.applyScope('everything');

      expect(viewModel.carriesCurrentBalances, isFalse);
    });

    test('in-stock-only and the invoice history refuse to combine', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );
      viewModel.applyScope('everything');

      viewModel.setOnlyStockedProducts(true);

      expect(viewModel.stockFilterConflicts, contains('sale'));
      expect(viewModel.canStartRun, isFalse);
    });

    test('in-stock-only is fine without the history, and is sent', () async {
      final repository = FakeMigrationRepository(sources: [sourceJson()]);
      final viewModel = await loaded(repository);
      viewModel.applyScope('opening_position');

      viewModel.setOnlyStockedProducts(true);
      await viewModel.startRun(dryRun: true);

      expect(viewModel.canStartRun, isTrue);
      final options =
          repository.startedRuns.single['options']! as Map<String, Object?>;
      expect(options['only_stocked_products'], isTrue);
    });
  });

  group('costs and cash boxes', () {
    // The field report: products arrived without their costs, and a cash box
    // arrived with a figure nobody wanted. Both came from a hand-edited list.

    test('choosing no quantities does not switch the costs off', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );

      viewModel.setStockSource(MigrationStockSource.none);

      expect(viewModel.carryCosts, isTrue);
      expect(viewModel.canCarryCosts, isTrue);
    });

    test('the run says whether to carry costs, every time', () async {
      final repository = FakeMigrationRepository(sources: [sourceJson()]);
      final viewModel = await loaded(repository);
      viewModel.setStockSource(MigrationStockSource.none);
      viewModel.setCarryCosts(false);

      await viewModel.startRun(dryRun: true);

      final options =
          repository.startedRuns.single['options']! as Map<String, Object?>;
      expect(options['stock_source'], 'none');
      expect(options['carry_costs'], isFalse);
    });

    test('the old cost-only spelling reads as no quantities plus costs', () {
      expect(
        MigrationStockSource.fromWire('cost_only'),
        MigrationStockSource.none,
      );
    });

    test('a cash box without its history is refused, with a way out', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );
      viewModel.applyScope('opening_position');

      viewModel.toggleEntity('money_account', true);

      expect(viewModel.moneyAccountConflict, isTrue);
      expect(viewModel.canStartRun, isFalse);
      expect(viewModel.offersOpeningPosition, isTrue);

      viewModel.applyScope('opening_position');

      expect(viewModel.moneyAccountConflict, isFalse);
      expect(viewModel.selectedEntities, isNot(contains('money_account')));
    });

    test('a cash box alongside its history is fine', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );
      viewModel.applyScope('everything');

      viewModel.toggleEntity('money_account', true);

      expect(viewModel.moneyAccountConflict, isFalse);
    });
  });

  group('costs onto an existing catalogue', () {
    // A shop that went live without its costs uploads the file again. The
    // costs-only scope attaches to the products already there — so nothing
    // may be closed over, implied or offered that would import a catalogue.

    test('it walks the stock pass alone and implies nothing', () async {
      final viewModel = await loaded(
        FakeMigrationRepository(sources: [sourceJson()]),
      );

      viewModel.applyScope('costs_only');

      expect(viewModel.attachesToCatalogue, isTrue);
      expect(viewModel.selectedEntities, {'stock'});
      expect(viewModel.impliedEntities, isEmpty);
      expect(viewModel.canCarryCosts, isFalse);
    });

    test('it is sent as the scope, which is what the server keys on', () async {
      final repository = FakeMigrationRepository(sources: [sourceJson()]);
      final viewModel = await loaded(repository);
      viewModel.applyScope('costs_only');

      await viewModel.startRun(dryRun: true);

      expect(repository.startedRuns.single['scope'], 'costs_only');
    });
  });
}
