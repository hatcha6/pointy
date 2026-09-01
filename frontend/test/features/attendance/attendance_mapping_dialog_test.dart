import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/attendance.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/attendance/views/attendance_settings_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Editing an employee's BioTime code, and — more importantly — walking away
/// from the edit.
///
/// The field's controller used to live in the calling method and be disposed
/// the moment `showDialog` returned, which is *before* the dialog's exit
/// animation has finished with it: the next frame rebuilt the field against a
/// disposed controller and took the settings page down with it.
void main() {
  const profile = AttendanceProfileLink(
    id: 3,
    employeeId: 9,
    employeeName: 'خالد',
    employeeNumber: 'EMP-9',
    bioTimeEmpCode: '1042',
    bioTimeFullName: 'Khaled',
    isTracked: true,
  );

  testWidgets('cancelling changes nothing and leaves the page standing', (
    tester,
  ) async {
    final repo = _FakeAttendanceRepository(profile);
    await _pumpSettings(tester, repo);
    final l10n = _l10n(tester);

    await _openMappingDialog(tester, profile);
    // The dialog opens on the code already mapped, not on a blank field.
    expect(find.text(profile.bioTimeEmpCode), findsWidgets);

    await tester.tap(find.text(l10n.cancelButton));
    await tester.pumpAndSettle();

    expect(repo.savedCode, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming saves the typed code', (tester) async {
    final repo = _FakeAttendanceRepository(profile);
    await _pumpSettings(tester, repo);
    final l10n = _l10n(tester);

    await _openMappingDialog(tester, profile);
    await tester.enterText(_dialogField, '  2077  ');
    await tester.tap(find.text(l10n.confirmButton));
    await tester.pumpAndSettle();

    expect(repo.savedCode, '2077');
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing the code is a save, not a cancellation', (
    tester,
  ) async {
    final repo = _FakeAttendanceRepository(profile);
    await _pumpSettings(tester, repo);
    final l10n = _l10n(tester);

    await _openMappingDialog(tester, profile);
    await tester.enterText(_dialogField, '');
    await tester.tap(find.text(l10n.confirmButton));
    await tester.pumpAndSettle();

    // Emptying the field unmaps the employee — a real instruction, and one the
    // page must not confuse with backing out.
    expect(repo.savedCode, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening and cancelling it twice is clean', (tester) async {
    final repo = _FakeAttendanceRepository(profile);
    await _pumpSettings(tester, repo);
    final l10n = _l10n(tester);

    for (var i = 0; i < 2; i += 1) {
      await _openMappingDialog(tester, profile);
      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
  });
}

/// The field inside the dialog — the page behind it is all fields.
final Finder _dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _openMappingDialog(
  WidgetTester tester,
  AttendanceProfileLink profile,
) async {
  final trigger = find.ancestor(
    of: find.text(profile.employeeName),
    matching: find.byType(ListTile),
  );
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: trigger, matching: find.byIcon(Icons.edit_outlined)),
  );
  await tester.pumpAndSettle();
}

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
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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

class _FakeAttendanceRepository extends AttendanceRepository {
  _FakeAttendanceRepository(this.profile) : super(PosApiService());

  final AttendanceProfileLink profile;
  String? savedCode;

  @override
  Future<Result<AttendanceConfig>> loadConfig() async => Ok(_config());

  @override
  Future<Result<void>> ensureProfiles() async => const Ok(null);

  @override
  Future<Result<AttendanceProfilePage>> loadProfiles({int page = 1}) async =>
      Ok(AttendanceProfilePage(profiles: [profile], hasMore: false));

  @override
  Future<Result<AttendanceProfileLink>> updateProfile(
    int profileId, {
    String? bioTimeEmpCode,
    bool? isTracked,
  }) async {
    savedCode = bioTimeEmpCode ?? savedCode;
    return Ok(profile);
  }
}
