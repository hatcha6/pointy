import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/campaign.dart';
import 'package:pointy_frontend/src/data/repositories/crm_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/crm/view_models/campaigns_view_model.dart';
import 'package:pointy_frontend/src/features/crm/views/campaigns_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _draft = Campaign(
  id: 3,
  name: 'عروض نهاية الأسبوع',
  bodyTemplate: 'مرحبًا، لدينا عروض جديدة.',
  status: CampaignStatus.draft,
  totalRecipients: 40,
);

const _preview = CampaignPreview(
  audienceTotal: 40,
  sendableEstimate: 37,
  skippedEstimate: 3,
  segments: 1,
  estimatedMinutes: 4,
  sampleMessage: 'مرحبًا علي، لدينا عروض جديدة.',
);

class _FakeCrmRepository extends CrmRepository {
  _FakeCrmRepository() : super(PosApiService());

  int sendCalls = 0;

  @override
  Future<Result<CampaignPreview>> previewCampaign(int id) async {
    return const Ok(_preview);
  }

  @override
  Future<Result<Campaign>> sendCampaign(int id) async {
    sendCalls++;
    return const Ok(
      Campaign(
        id: 3,
        name: 'عروض نهاية الأسبوع',
        bodyTemplate: 'مرحبًا، لدينا عروض جديدة.',
        status: CampaignStatus.sending,
      ),
    );
  }
}

Future<CampaignEditorViewModel> _pumpEditor(
  WidgetTester tester,
  _FakeCrmRepository repository,
) async {
  final viewModel = CampaignEditorViewModel(repository, _draft);
  await viewModel.loadPreview();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: CampaignEditorScreen(viewModel: viewModel, canSend: true),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

void main() {
  testWidgets(
    'tapping send asks for confirmation and names the recipient count',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final repository = _FakeCrmRepository();
      await _pumpEditor(tester, repository);

      await tester.tap(find.text('موافقة وإرسال'));
      await tester.pumpAndSettle();

      expect(find.text('تأكيد إرسال الحملة'), findsOneWidget);
      expect(
        find.textContaining('سيتم إرسال 37 رسالة نصية'),
        findsOneWidget,
        reason:
            'the dialog must state how many customers are about to be texted',
      );
      expect(
        repository.sendCalls,
        0,
        reason: 'nothing may go out before confirming',
      );
    },
  );

  testWidgets('cancelling the confirmation sends nothing', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repository = _FakeCrmRepository();
    await _pumpEditor(tester, repository);

    await tester.tap(find.text('موافقة وإرسال'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(find.text('تأكيد إرسال الحملة'), findsNothing);
    expect(repository.sendCalls, 0);
  });

  testWidgets('confirming sends the campaign once', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repository = _FakeCrmRepository();
    await _pumpEditor(tester, repository);

    await tester.tap(find.text('موافقة وإرسال'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرسال الآن'));
    await tester.pumpAndSettle();

    expect(repository.sendCalls, 1);
  });
}
