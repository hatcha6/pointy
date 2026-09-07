import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/recorder_discovery.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_settings_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/views/camera_settings_page.dart';

/// The setup path for someone who has never typed an IP address.
///
/// The whole reason the sweep exists is that "what is my DVR's address" is a
/// question most of these shops cannot answer, so the test that matters is that
/// picking a device off the list leaves a form they can just finish.
class _FakeRepository extends SurveillanceRepository {
  _FakeRepository() : super(PosApiService());

  @override
  Future<Result<List<Recorder>>> loadRecorders() async => const Ok([]);

  @override
  Future<Result<List<Camera>>> loadCameras({bool enabledOnly = false}) async {
    return const Ok([]);
  }

  @override
  Future<Result<SurveillanceStatus>> loadStatus() async {
    return const Ok(SurveillanceStatus());
  }
}

void main() {
  Future<void> pumpForm(
    WidgetTester tester, {
    required List<DiscoveredRecorder> found,
    RecorderDraft initial = const RecorderDraft(),
  }) async {
    final viewModel = CameraSettingsViewModel(
      _FakeRepository(),
      sweep: () async => found,
    );
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
        home: RecorderFormPage(viewModel: viewModel, initial: initial),
      ),
    );
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester, String label) {
    final field = tester.widget<TextField>(
      find
          .ancestor(of: find.text(label), matching: find.byType(TextField))
          .first,
    );
    return field.controller?.text ?? '';
  }

  const hikvision = DiscoveredRecorder(
    host: '192.168.1.64',
    port: 80,
    brand: RecorderBrand.hikvision,
    model: 'DS-7216HGHI-K1',
  );

  testWidgets('a new recorder form sweeps the network on its own', (
    tester,
  ) async {
    await pumpForm(tester, found: const [hikvision]);
    expect(find.text('192.168.1.64'), findsOneWidget);
  });

  testWidgets('picking a device fills in the address for them', (tester) async {
    await pumpForm(tester, found: const [hikvision]);
    await tester.tap(find.text('192.168.1.64'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(fieldText(tester, l10n.recorderHostLabel), '192.168.1.64');
    expect(fieldText(tester, l10n.recorderPortLabel), '80');
    // Both brands ship as `admin`, and a shop that never changed it would
    // otherwise be asked a question it cannot answer.
    expect(fieldText(tester, l10n.recorderUsernameLabel), 'admin');
    // The password is theirs; we never guess it.
    expect(fieldText(tester, l10n.recorderPasswordLabel), '');
  });

  testWidgets('an unidentified device is still offered', (tester) async {
    // The address is the useful half. The backend settles the brand once it has
    // a password, so refusing to suggest it would help nobody.
    await pumpForm(
      tester,
      found: const [DiscoveredRecorder(host: '192.168.1.201', port: 8080)],
    );
    expect(find.text('192.168.1.201:8080'), findsOneWidget);
  });

  testWidgets('a network with no recorder says so and offers the fields', (
    tester,
  ) async {
    await pumpForm(tester, found: const []);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.textContaining(l10n.recorderScanEmptyTitle), findsOneWidget);
    expect(find.text(l10n.recorderHostLabel), findsOneWidget);
  });

  testWidgets('editing an existing recorder does not sweep the network', (
    tester,
  ) async {
    // Re-opening a working recorder to change its password has no use for a
    // scan of the whole subnet.
    var swept = false;
    final viewModel = CameraSettingsViewModel(
      _FakeRepository(),
      sweep: () async {
        swept = true;
        return const [];
      },
    );
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
        home: RecorderFormPage(
          viewModel: viewModel,
          initial: const RecorderDraft(id: 3, host: '192.168.1.64'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(swept, isFalse);
  });
}
