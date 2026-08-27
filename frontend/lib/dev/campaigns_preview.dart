// Dev-only preview harness for the campaign editor / approval screen (CRM).
//
// Run with: make frontend-campaigns-preview
// Scenarios: new | draft | sent
//
// The list screen needs the nav shell, so this previews the editor (self-
// contained). Not part of the shipping app.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/campaign.dart';
import 'package:pointy_frontend/src/data/repositories/crm_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/crm/view_models/campaigns_view_model.dart';
import 'package:pointy_frontend/src/features/crm/views/campaigns_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final scenario = _screen();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: CampaignEditorScreen(
        viewModel: CampaignEditorViewModel(
          _FakeCrmRepository(),
          _campaign(scenario),
        ),
        canSend: true,
      ),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) return direct;
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'draft';
}

Campaign? _campaign(String scenario) {
  return switch (scenario) {
    'new' => null,
    'sent' => const Campaign(
      id: 2,
      name: 'عرض نهاية الأسبوع',
      bodyTemplate: 'مرحبا {{first_name}}',
      status: CampaignStatus.sent,
      totalRecipients: 120,
      sentCount: 118,
      skippedOptoutCount: 2,
    ),
    _ => const Campaign(
      id: 1,
      name: 'عرض العيد',
      bodyTemplate: 'مرحبا {{first_name}}، عرض خاص من {{shop_name}} 🎉',
      status: CampaignStatus.draft,
      rfmSegments: ['champion', 'at_risk'],
    ),
  };
}

class _FakeCrmRepository extends CrmRepository {
  _FakeCrmRepository() : super(PosApiService());

  @override
  Future<Result<Campaign>> createCampaign(CampaignDraft draft) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return Ok(
      Campaign(
        id: 1,
        name: draft.name,
        bodyTemplate: draft.bodyTemplate,
        status: CampaignStatus.draft,
        rfmSegments: draft.rfmSegments,
      ),
    );
  }

  @override
  Future<Result<Campaign>> updateCampaign(int id, CampaignDraft draft) =>
      createCampaign(draft);

  @override
  Future<Result<CampaignPreview>> previewCampaign(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const Ok(
      CampaignPreview(
        audienceTotal: 142,
        sendableEstimate: 130,
        skippedEstimate: 12,
        segments: 2,
        estimatedMinutes: 22,
        sampleMessage: 'مرحبا علي، عرض خاص من متجري 🎉',
      ),
    );
  }

  @override
  Future<Result<Campaign>> sendCampaign(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const Ok(
      Campaign(
        id: 1,
        name: 'عرض العيد',
        bodyTemplate: '',
        status: CampaignStatus.sending,
      ),
    );
  }
}
