import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_export.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/analytics_purge_section.dart';

/// The dialog is the safety mechanism, so it is the thing worth pinning.
///
/// This button deletes a shop's entire event history with no undo and no copy
/// in the backups. If a tap ever reached the server without passing through a
/// confirmation — or if "cancel" ever counted as consent — the feature would be
/// a data-loss bug wearing a settings row.
void main() {
  Widget harness(ShopSettingsViewModel viewModel) {
    return MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) => AnalyticsPurgeSection(viewModel: viewModel),
        ),
      ),
    );
  }

  final button = find.byKey(const ValueKey('analytics_purge_button'));

  testWidgets('tapping the button asks before it deletes anything', (
    tester,
  ) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(harness(ShopSettingsViewModel(repo)));

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(
      find.byType(PointyDestructiveConfirmationDialog),
      findsOneWidget,
      reason: 'the tap must not be the decision',
    );
    expect(repo.purgeCalls, 0, reason: 'nothing has been confirmed yet');
  });

  testWidgets('backing out of the dialog deletes nothing', (tester) async {
    final repo = _FakeRepo();
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.pumpWidget(harness(ShopSettingsViewModel(repo)));

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.cancelButton));
    await tester.pumpAndSettle();

    expect(find.byType(PointyDestructiveConfirmationDialog), findsNothing);
    expect(repo.purgeCalls, 0, reason: 'cancel is not consent');
  });

  testWidgets('confirming clears the history and reports the count', (
    tester,
  ) async {
    final repo = _FakeRepo(result: const Ok(417361));
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.pumpWidget(harness(ShopSettingsViewModel(repo)));

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.analyticsPurgeDialogConfirm));
    await tester.pumpAndSettle();

    expect(repo.purgeCalls, 1);
    expect(find.text(l10n.analyticsPurgeDoneMessage(417361)), findsOneWidget);
  });

  testWidgets('a refusal is reported rather than silently swallowed', (
    tester,
  ) async {
    final repo = _FakeRepo(result: Error(Exception('403')));
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.pumpWidget(harness(ShopSettingsViewModel(repo)));

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.analyticsPurgeDialogConfirm));
    await tester.pumpAndSettle();

    expect(find.text(l10n.analyticsPurgeFailedMessage), findsOneWidget);
  });

  testWidgets('the button is dead while an export is still downloading', (
    tester,
  ) async {
    // Clearing the table out from under a running export would hand the user a
    // half-written copy of the history they were trying to preserve.
    final repo = _FakeRepo();
    final viewModel = ShopSettingsViewModel(repo);
    await tester.pumpWidget(harness(viewModel));

    unawaitedExport(viewModel);
    await tester.pump();

    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });
}

void unawaitedExport(ShopSettingsViewModel viewModel) {
  viewModel.exportAnalyticsEvents(const AnalyticsExportQuery());
}

class _FakeRepo extends ShopSettingsRepository {
  _FakeRepo({this.result = const Ok(0)}) : super(PosApiService());

  final Result<int> result;
  int purgeCalls = 0;

  @override
  Future<Result<int>> purgeAnalyticsEvents() async {
    purgeCalls++;
    return result;
  }

  /// Never completes: the point is to hold the view model in "exporting" so the
  /// purge button can be observed while a download is in flight.
  @override
  Future<Result<AnalyticsExportFile>> exportAnalyticsEvents(
    AnalyticsExportQuery query, {
    void Function(AnalyticsExportProgress progress)? onProgress,
    AnalyticsExportCancellation? cancellation,
  }) => Completer<Result<AnalyticsExportFile>>().future;

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
