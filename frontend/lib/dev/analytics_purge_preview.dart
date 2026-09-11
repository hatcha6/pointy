// Dev-only preview for the "clear the telemetry" section of the export page.
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/analytics_purge_preview.dart
//
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/analytics_purge_section.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

void main() => runApp(const _PurgePreviewApp());

class _PurgePreviewApp extends StatelessWidget {
  const _PurgePreviewApp();

  @override
  Widget build(BuildContext context) {
    final viewModel = ShopSettingsViewModel(_OfflineRepo());
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context)!;
          final spacing = AdaptiveSpacing.of(context);
          return Scaffold(
            appBar: AppBar(title: Text(l10n.analyticsExportTitle)),
            body: ListenableBuilder(
              listenable: viewModel,
              builder: (context, _) => ListView(
                padding: spacing.pagePadding,
                children: [
                  AdaptiveMaxWidth(
                    width: AppContentWidth.form,
                    child: PointyDetailSection(
                      icon: Icons.file_download_outlined,
                      title: l10n.analyticsExportFiltersSectionTitle,
                      child: Text(l10n.analyticsExportAllEventsSummary),
                    ),
                  ),
                  SizedBox(height: spacing.lg),
                  AdaptiveMaxWidth(
                    width: AppContentWidth.form,
                    child: AnalyticsPurgeSection(viewModel: viewModel),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OfflineRepo extends ShopSettingsRepository {
  _OfflineRepo() : super(PosApiService());

  @override
  Future<Result<int>> purgeAnalyticsEvents() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    return const Ok(417361);
  }

  @override
  Future<Result<ShopSettings>> loadSettings() async => Error(Exception('n/a'));

  @override
  Future<Result<BackupOperationsStatus>> loadBackupOperationsStatus() async =>
      Error(Exception('n/a'));

  @override
  Future<Result<List<BackupDestination>>> loadBackupDestinations() async =>
      Error(Exception('n/a'));
}
