import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/messaging_status.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_settings_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The texts that go out by themselves each have a switch on the SMS page,
/// and every text is listed under its family with what its example costs.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  Future<_AutoRepo> pump(WidgetTester tester, {bool refuse = false}) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final repo = _AutoRepo(refuse: refuse);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: MessagingSettingsPage(
          viewModel: MessagingSettingsViewModel(repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('each automatic text has its switch, saved at once', (
    tester,
  ) async {
    final repo = await pump(tester);
    expect(find.text(l10n.messagingAutoTitle), findsOneWidget);
    final ready = find.byKey(const ValueKey('messaging_auto_job_ready'));
    final received = find.byKey(const ValueKey('messaging_auto_job_received'));
    expect(ready, findsOneWidget);
    expect(tester.widget<SwitchListTile>(ready).value, isTrue);
    expect(tester.widget<SwitchListTile>(received).value, isFalse);
    // A text sent from a button has no switch.
    expect(find.byKey(const ValueKey('messaging_auto_invoice')), findsNothing);

    await tester.ensureVisible(received);
    await tester.tap(received);
    await tester.pumpAndSettle();
    expect(repo.switches, [('job_received', true)]);
    expect(tester.widget<SwitchListTile>(received).value, isTrue);
  });

  testWidgets('a switch the backend refuses moves back and says so', (
    tester,
  ) async {
    await pump(tester, refuse: true);
    final ready = find.byKey(const ValueKey('messaging_auto_job_ready'));
    await tester.ensureVisible(ready);
    await tester.tap(ready);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(ready).value, isTrue);
    expect(find.text(l10n.messagingAutoSaveFailed), findsOneWidget);
  });

  testWidgets('every text sits under its family with what it costs', (
    tester,
  ) async {
    await pump(tester);
    expect(
      find.byKey(const ValueKey('messaging_template_group_jobs')),
      findsOneWidget,
    );
    expect(find.text('الصيانة والطلبات'), findsOneWidget);
    expect(
      find.text(
        l10n.messagingTemplateExampleCost(
          l10n.messagingTemplateParts(2),
          '0.30 د.ل',
        ),
      ),
      findsWidgets,
    );
    expect(find.text(l10n.messagingTemplateAutoOn), findsWidgets);
    expect(find.text(l10n.messagingTemplateAutoOff), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

class _AutoRepo extends MessagingRepository {
  _AutoRepo({this.refuse = false}) : super(PosApiService());

  final bool refuse;
  final List<(String, bool)> switches = [];

  static const _gateway = MessagingGateway(
    id: 1,
    name: 'رسائل دفتر',
    isDefault: true,
  );

  @override
  Future<Result<MessagingServiceStatus>> loadStatus() async {
    return Ok(
      MessagingServiceStatus(
        entitled: true,
        available: true,
        gateway: _gateway,
        smsWallet: const SmsWallet(balance: 4.5, price: 0.15, messagesLeft: 30),
        usage: const MessagingUsage(used: 3, limit: 0, remaining: -1),
        templateGroups: const [
          MessagingTemplateGroup(key: 'sales', title: 'المبيعات والفواتير'),
          MessagingTemplateGroup(key: 'jobs', title: 'الصيانة والطلبات'),
        ],
        templates: const [
          MessagingTemplateInfo(
            kind: 'invoice',
            title: 'فاتورة بيع',
            example: 'محل النور: فاتورتك…',
            group: 'sales',
            exampleParts: 2,
            examplePrice: 0.3,
          ),
          MessagingTemplateInfo(
            kind: 'job_ready',
            title: 'جاهز للاستلام',
            example: 'محل النور: طلبكم (هاتف) جاهز للاستلام.',
            group: 'jobs',
            automatic: true,
            autoEnabled: true,
            autoLabel: 'حين يصل الطلب إلى مرحلة «جاهز للاستلام».',
            examplePrice: 0.15,
          ),
          MessagingTemplateInfo(
            kind: 'job_received',
            title: 'استلام طلب',
            example: 'محل النور: استلمنا هاتف، رقم طلبكم REP-1.',
            group: 'jobs',
            automatic: true,
            autoEnabled: false,
            examplePrice: 0.15,
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<MessagingGateway>> setAutoMessage(
    int id, {
    required String kind,
    required bool enabled,
  }) async {
    if (refuse) {
      return Error(Exception('refused'));
    }
    switches.add((kind, enabled));
    return Ok(
      MessagingGateway(
        id: _gateway.id,
        name: _gateway.name,
        isDefault: true,
        autoMessages: {'job_ready': true, kind: enabled},
      ),
    );
  }
}
