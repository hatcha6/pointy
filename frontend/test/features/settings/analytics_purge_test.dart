import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';

/// Clearing the shop's telemetry once it has been exported.
///
/// The server sweep is only half of it. Every device carries its own queue of
/// events it has not delivered yet — a till that has been offline can hold
/// weeks of them — so a purge that only emptied the table would watch this
/// device refill it on the next flush. These pin that the local backlog goes
/// too, and, just as importantly, that it does *not* go when the server refused
/// the purge: throwing away undelivered events on a failure would destroy
/// telemetry without clearing anything.
void main() {
  Future<AnalyticsEngine> engineHolding(int events) async {
    final storage = MemoryAnalyticsQueueStorage(installationId: 'install-1');
    final engine = AnalyticsEngine(
      _SilentSink(),
      storage: storage,
      flushInterval: const Duration(hours: 1),
    );
    for (var i = 0; i < events; i++) {
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
    }
    await engine.flushPendingWrites();
    return engine;
  }

  test('a cleared history takes this device\'s backlog with it', () async {
    final engine = await engineHolding(3);
    expect(engine.pendingEventCount, greaterThan(0));

    final repo = _FakeRepo(Ok(417361));
    final viewModel = ShopSettingsViewModel(repo, analyticsEngine: engine);

    final deleted = await viewModel.purgeAnalyticsEvents();

    expect(deleted, 417361, reason: 'the screen reports the server count');
    expect(viewModel.isPurgingAnalytics, isFalse);
    expect(viewModel.hasAnalyticsPurgeError, isFalse);
    expect(
      engine.pendingEventCount,
      0,
      reason:
          'otherwise the next flush refills the table that was just emptied',
    );
  });

  test('a refused purge leaves the undelivered events alone', () async {
    final engine = await engineHolding(3);
    final pendingBefore = engine.pendingEventCount;

    final repo = _FakeRepo(Error(Exception('403')));
    final viewModel = ShopSettingsViewModel(repo, analyticsEngine: engine);

    final deleted = await viewModel.purgeAnalyticsEvents();

    expect(deleted, isNull);
    expect(viewModel.hasAnalyticsPurgeError, isTrue);
    expect(
      engine.pendingEventCount,
      pendingBefore,
      reason: 'nothing was cleared server-side, so nothing is safe to drop',
    );
  });

  test('the screen is told while the purge is running', () async {
    final repo = _FakeRepo(Ok(0));
    final viewModel = ShopSettingsViewModel(repo);

    final running = viewModel.purgeAnalyticsEvents();
    expect(
      viewModel.isPurgingAnalytics,
      isTrue,
      reason: 'the button has to be able to disable itself',
    );

    await running;
    expect(viewModel.isPurgingAnalytics, isFalse);
  });

  test('a purge with nothing to delete is not an error', () async {
    final viewModel = ShopSettingsViewModel(_FakeRepo(Ok(0)));

    expect(await viewModel.purgeAnalyticsEvents(), 0);
    expect(viewModel.hasAnalyticsPurgeError, isFalse);
  });
}

class _SilentSink implements AnalyticsEventSink {
  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async => Error(Exception('offline'));
}

class _FakeRepo extends ShopSettingsRepository {
  _FakeRepo(this._result) : super(PosApiService());

  final Result<int> _result;

  @override
  Future<Result<int>> purgeAnalyticsEvents() async => _result;

  // The view model loads these on construction; keep them inert.
  @override
  Future<Result<ShopSettings>> loadSettings() async =>
      Error(Exception('not used'));

  @override
  Future<Result<BackupOperationsStatus>> loadBackupOperationsStatus() async =>
      Error(Exception('not used'));

  @override
  Future<Result<List<BackupDestination>>> loadBackupDestinations() async =>
      Error(Exception('not used'));
}
