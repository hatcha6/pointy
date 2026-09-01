import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/attendance.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';

/// A BioTime backfill runs on a worker and takes minutes, so starting one no
/// longer blocks the request. These pin that the view model follows the run to
/// completion instead of declaring victory the moment the job is queued — and
/// that it still works on a shop with no worker at all.
void main() {
  setUp(() {
    AttendanceViewModel.syncPollInterval = const Duration(milliseconds: 1);
    AttendanceViewModel.syncPollTimeout = const Duration(seconds: 5);
  });

  test('a queued sync is followed until the server stops reporting a run', () async {
    // Two polls still running, then done.
    final repo = _FakeRepo(
      start: const Ok(
        AttendanceSyncStart(queued: true, alreadyRunning: false),
      ),
      configs: [
        _config(isSyncing: true, progress: 4000),
        _config(isSyncing: true, progress: 11000),
        _config(isSyncing: false, progress: 20203),
      ],
    );
    final viewModel = AttendanceViewModel(repo);

    await viewModel.sync();

    // It kept polling rather than returning on the 202.
    expect(repo.configCalls, greaterThanOrEqualTo(3));
    expect(viewModel.isSyncing, isFalse);
    expect(viewModel.config!.isSyncing, isFalse);
  });

  test('progress is published while the sync is still running', () async {
    final seen = <int>[];
    final repo = _FakeRepo(
      start: const Ok(
        AttendanceSyncStart(queued: true, alreadyRunning: false),
      ),
      configs: [
        _config(isSyncing: true, progress: 5000),
        _config(isSyncing: true, progress: 15000),
        _config(isSyncing: false, progress: 20203),
      ],
    );
    final viewModel = AttendanceViewModel(repo);
    viewModel.addListener(() {
      final config = viewModel.config;
      if (config != null && config.syncProgressPunches > 0) {
        seen.add(config.syncProgressPunches);
      }
    });

    await viewModel.sync();

    // The settings screen can show a backfill advancing, not just a spinner.
    expect(seen, containsAll(<int>[5000, 15000]));
  });

  test('a shop with no worker still syncs inline', () async {
    final repo = _FakeRepo(
      start: const Ok(
        AttendanceSyncStart(
          queued: false,
          alreadyRunning: false,
          result: AttendanceSyncResult(
            matchedEmployees: 44,
            unmatchedBioTime: [],
            punchesImported: 20203,
            daysRebuilt: 8469,
          ),
        ),
      ),
      configs: [_config(isSyncing: false, progress: 0)],
    );
    final viewModel = AttendanceViewModel(repo);

    final result = await viewModel.sync();

    expect(result, isNotNull);
    expect(result!.punchesImported, 20203);
    // Nothing to poll: the work was already done when the call returned.
    expect(repo.configCalls, 1);
  });

  test('polling gives up rather than spinning forever on a dead worker', () async {
    AttendanceViewModel.syncPollTimeout = const Duration(milliseconds: 30);
    final repo = _FakeRepo(
      start: const Ok(
        AttendanceSyncStart(queued: true, alreadyRunning: false),
      ),
      // Never stops claiming to be running.
      configs: [_config(isSyncing: true, progress: 100)],
      repeatLastConfig: true,
    );
    final viewModel = AttendanceViewModel(repo);

    await viewModel.sync().timeout(const Duration(seconds: 5));

    expect(viewModel.isSyncing, isFalse);
  });
}

AttendanceConfig _config({required bool isSyncing, required int progress}) =>
    AttendanceConfig(
      baseUrl: 'http://192.168.1.101:8085',
      username: 'admin',
      hasPassword: true,
      isEnabled: true,
      workdays: const [0, 1, 2, 3, 6],
      shiftStart: '09:00:00',
      shiftEnd: '17:00:00',
      graceMinutes: 15,
      isSyncing: isSyncing,
      syncProgressPunches: progress,
    );

class _FakeRepo extends AttendanceRepository {
  _FakeRepo({
    required this.start,
    required this.configs,
    this.repeatLastConfig = false,
  }) : super(PosApiService());

  final Result<AttendanceSyncStart> start;
  final List<AttendanceConfig> configs;
  final bool repeatLastConfig;
  int configCalls = 0;

  @override
  Future<Result<AttendanceSyncStart>> sync() async => start;

  @override
  Future<Result<AttendanceConfig>> loadConfig() async {
    final index = configCalls;
    configCalls += 1;
    if (index < configs.length) {
      return Ok(configs[index]);
    }
    return Ok(repeatLastConfig ? configs.last : configs.last);
  }

  @override
  Future<Result<void>> ensureProfiles() async => const Ok(null);

  @override
  Future<Result<AttendanceProfilePage>> loadProfiles({int page = 1}) async =>
      const Ok(AttendanceProfilePage(profiles: [], hasMore: false));
}
