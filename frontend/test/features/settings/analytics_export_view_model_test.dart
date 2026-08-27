import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_export.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';

/// An export of a month of telemetry runs for minutes, so the view model owes
/// the screen two things a plain spinner cannot give: how far along it is, and
/// a way out. These pin both.
void main() {
  const query = AnalyticsExportQuery();

  AnalyticsExportFile file() => AnalyticsExportFile.inMemory(
    bytes: Uint8List(4),
    filename: 'export.zip',
    contentType: 'application/zip',
    sizeBytes: 4,
  );

  test('progress from the download is published to the screen', () async {
    final repo = _FakeRepo();
    final vm = ShopSettingsViewModel(repo);
    final export = vm.exportAnalyticsEvents(query);

    await repo.started.future;
    repo.emitProgress(
      const AnalyticsExportProgress(
        receivedBytes: 5 * 1024 * 1024,
        elapsed: Duration(seconds: 2),
        expectedEventCount: 12000000,
      ),
    );

    expect(vm.isExportingAnalytics, isTrue);
    expect(vm.analyticsExportProgress?.receivedBytes, 5 * 1024 * 1024);
    expect(vm.analyticsExportProgress?.expectedEventCount, 12000000);
    expect(
      vm.analyticsExportProgress!.bytesPerSecond,
      closeTo(2.5 * 1024 * 1024, 1),
    );

    repo.complete(Ok(file()));
    await export;
    expect(vm.analyticsExportProgress, isNull, reason: 'cleared when finished');
  });

  test(
    'cancelling stops the export without reporting it as a failure',
    () async {
      final repo = _FakeRepo();
      final vm = ShopSettingsViewModel(repo);
      final export = vm.exportAnalyticsEvents(query);

      await repo.started.future;
      expect(vm.canCancelAnalyticsExport, isTrue);

      vm.cancelAnalyticsExport();
      expect(repo.cancellation!.isCanceled, isTrue);

      // The receiver turns a cancelled stream into this exception.
      repo.complete(Error(const AnalyticsExportCanceledException()));
      final result = await export;

      expect(result, isNull);
      expect(vm.isExportingAnalytics, isFalse);
      expect(
        vm.hasAnalyticsExportError,
        isFalse,
        reason: 'the user asked for this; it is not an error to show them',
      );
      expect(vm.canCancelAnalyticsExport, isFalse);
    },
  );

  test('a real failure is still reported as one', () async {
    final repo = _FakeRepo();
    final vm = ShopSettingsViewModel(repo);
    final export = vm.exportAnalyticsEvents(query);

    await repo.started.future;
    repo.complete(Error(Exception('backend fell over')));

    expect(await export, isNull);
    expect(vm.hasAnalyticsExportError, isTrue);
  });
}

class _FakeRepo extends ShopSettingsRepository {
  _FakeRepo() : super(PosApiService());

  final started = Completer<void>();
  final _result = Completer<Result<AnalyticsExportFile>>();
  void Function(AnalyticsExportProgress)? _onProgress;
  AnalyticsExportCancellation? cancellation;

  void emitProgress(AnalyticsExportProgress progress) =>
      _onProgress?.call(progress);

  void complete(Result<AnalyticsExportFile> result) => _result.complete(result);

  @override
  Future<Result<AnalyticsExportFile>> exportAnalyticsEvents(
    AnalyticsExportQuery query, {
    void Function(AnalyticsExportProgress progress)? onProgress,
    AnalyticsExportCancellation? cancellation,
  }) {
    _onProgress = onProgress;
    this.cancellation = cancellation;
    if (!started.isCompleted) {
      started.complete();
    }
    return _result.future;
  }

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
