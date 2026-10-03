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

/// A campaign pays for every recipient's message per SMS it goes out as, so
/// the preview says what it will cost and warns when the SMS balance runs out
/// first.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  Future<void> pump(WidgetTester tester, CampaignPreview preview) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final viewModel = CampaignEditorViewModel(
      _PreviewRepository(preview),
      _draft,
    );
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
  }

  testWidgets('the preview names what the campaign costs', (tester) async {
    await pump(tester, _preview(cost: '11.100', balance: '20.000'));
    expect(find.text(l10n.campaignPreviewCostLabel), findsOneWidget);
    expect(find.text('≈ 11.10 د.ل'), findsOneWidget);
    expect(find.byKey(const ValueKey('campaign_balance_short')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a balance that runs out first is a warning before sending', (
    tester,
  ) async {
    await pump(tester, _preview(cost: '11.100', balance: '4.500'));
    expect(
      find.byKey(const ValueKey('campaign_balance_short')),
      findsOneWidget,
    );
    expect(find.text(l10n.campaignPreviewBalanceShortTitle), findsOneWidget);
    expect(
      find.text(
        l10n.campaignPreviewBalanceShortMessage('4.50 د.ل', '11.10 د.ل'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no SMS balance, no cost row', (tester) async {
    await pump(tester, _preview(cost: '', balance: ''));
    expect(find.text(l10n.campaignPreviewCostLabel), findsNothing);
    expect(find.byKey(const ValueKey('campaign_balance_short')), findsNothing);
  });

  test('the preview reads the cost and the balance', () {
    final preview = _preview(cost: '0.900', balance: '0.450');
    expect(preview.estimatedCost, 0.9);
    expect(preview.smsBalance, 0.45);
    expect(preview.balanceFallsShort, isTrue);
    expect(_preview(cost: '', balance: '').balanceFallsShort, isFalse);
  });
}

const _draft = Campaign(
  id: 3,
  name: 'عروض نهاية الأسبوع',
  bodyTemplate: 'مرحبًا، لدينا عروض جديدة.',
  status: CampaignStatus.draft,
  totalRecipients: 37,
);

CampaignPreview _preview({required String cost, required String balance}) {
  return CampaignPreview.fromJson({
    'audience_total': 40,
    'sendable_estimate': 37,
    'skipped_estimate': 3,
    'segments': 2,
    'estimated_minutes': 4,
    'sample_message': 'عرض من محل النور: مرحبًا علي، لدينا عروض جديدة.',
    'estimated_cost': cost,
    'sms_balance': balance,
    'sms_price': '0.150',
  });
}

class _PreviewRepository extends CrmRepository {
  _PreviewRepository(this.preview) : super(PosApiService());

  final CampaignPreview preview;

  @override
  Future<Result<CampaignPreview>> previewCampaign(int id) async => Ok(preview);
}
