import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/attendance.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/attendance/views/attendance_settings_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Saving and testing the BioTime connection share one `isMutating` flag, so
/// pressing either greys out both. These pin that the button the manager
/// pressed says it is working — a connection test reaches an external server
/// and can hang for a while, and a silent grey row reads as a dead screen.
void main() {
  const saveKey = ValueKey('attendance_save_button');
  const testKey = ValueKey('attendance_test_button');

  testWidgets(
    'the test button reports itself as running, and says so in Arabic',
    (tester) async {
      final repo = _FakeAttendanceRepository();
      await _pumpSettings(tester, repo);
      final l10n = _l10n(tester);

      // Resting state: both actions offer themselves, neither claims to be busy.
      expect(find.text(l10n.attendanceTestConnectionButton), findsOneWidget);
      expect(find.text(l10n.attendanceTestInProgressButton), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.byKey(testKey));
      await tester.pump();

      // In flight: the pressed button carries the spinner and the Arabic
      // in-progress label, so the greyed-out neighbour is explained.
      expect(find.text(l10n.attendanceTestInProgressButton), findsOneWidget);
      expect(find.text(l10n.attendanceTestConnectionButton), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(testKey),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // The save button goes inert but must not impersonate the running action.
      expect(_button<FilledButton>(tester, saveKey).onPressed, isNull);
      expect(find.text(l10n.attendanceSaveInProgressButton), findsNothing);

      repo.completeTest(const Ok(42));
      await tester.pumpAndSettle();

      // Settled: the label and the spinner both stand down.
      expect(find.text(l10n.attendanceTestConnectionButton), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_button<OutlinedButton>(tester, testKey).onPressed, isNotNull);
    },
  );

  testWidgets('the save button reports itself as running', (tester) async {
    final repo = _FakeAttendanceRepository();
    await _pumpSettings(tester, repo);
    final l10n = _l10n(tester);

    await tester.tap(find.byKey(saveKey));
    await tester.pump();

    expect(find.text(l10n.attendanceSaveInProgressButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(saveKey),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    // The neighbour stays quiet — only one action is actually running.
    expect(find.text(l10n.attendanceTestInProgressButton), findsNothing);
    expect(_button<OutlinedButton>(tester, testKey).onPressed, isNull);

    repo.completeSave(Ok(_config()));
    await tester.pumpAndSettle();

    expect(find.text(l10n.attendanceSaveInProgressButton), findsNothing);
    expect(_button<FilledButton>(tester, saveKey).onPressed, isNotNull);
  });

  testWidgets('a failed test still clears the running state', (tester) async {
    final repo = _FakeAttendanceRepository();
    await _pumpSettings(tester, repo);
    final l10n = _l10n(tester);

    await tester.tap(find.byKey(testKey));
    await tester.pump();
    expect(find.text(l10n.attendanceTestInProgressButton), findsOneWidget);

    repo.completeTest(Error(Exception('unreachable')));
    await tester.pumpAndSettle();

    // A dead BioTime box must not leave the row permanently spinning.
    expect(find.text(l10n.attendanceTestConnectionButton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(_button<OutlinedButton>(tester, testKey).onPressed, isNotNull);
    expect(_button<FilledButton>(tester, saveKey).onPressed, isNotNull);
  });
}

T _button<T extends Widget>(WidgetTester tester, Key key) =>
    tester.widget<T>(find.byKey(key));

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(AttendanceSettingsPage)))!;

AttendanceConfig _config() => const AttendanceConfig(
  baseUrl: 'http://192.168.1.20',
  username: 'admin',
  hasPassword: true,
  isEnabled: true,
  workdays: [0, 1, 2, 3, 4],
  shiftStart: '09:00:00',
  shiftEnd: '17:00:00',
  graceMinutes: 15,
);

Future<void> _pumpSettings(
  WidgetTester tester,
  _FakeAttendanceRepository repo,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: AttendanceSettingsPage(viewModel: AttendanceViewModel(repo)),
      ),
    ),
  );
  // The page loads its config in a post-frame callback.
  await tester.pumpAndSettle();
}

/// Holds `testConnection` / `updateConfig` open so the in-flight frame can be
/// inspected, which is the only moment the pending affordance exists.
class _FakeAttendanceRepository extends AttendanceRepository {
  _FakeAttendanceRepository() : super(PosApiService());

  final _test = Completer<Result<int>>();
  final _save = Completer<Result<AttendanceConfig>>();

  void completeTest(Result<int> result) => _test.complete(result);
  void completeSave(Result<AttendanceConfig> result) => _save.complete(result);

  @override
  Future<Result<AttendanceConfig>> loadConfig() async => Ok(_config());

  @override
  Future<Result<void>> ensureProfiles() async => const Ok(null);

  @override
  Future<Result<AttendanceProfilePage>> loadProfiles({int page = 1}) async =>
      const Ok(AttendanceProfilePage(profiles: [], hasMore: false));

  @override
  Future<Result<int>> testConnection() => _test.future;

  @override
  Future<Result<AttendanceConfig>> updateConfig(AttendanceConfigDraft draft) =>
      _save.future;
}
