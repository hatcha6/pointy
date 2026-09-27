import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/clock_time.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/messaging_status.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_settings_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The SMS page is a status page now: whether the shop has the service, how
/// much of it is used, its own brakes, a test, and what its customers read.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  Future<void> pump(
    WidgetTester tester,
    _FakeRepo repo, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
  }

  testWidgets('a shop without SMS reads why, and gets no controls', (
    tester,
  ) async {
    await pump(tester, _FakeRepo(entitled: false));

    expect(find.text(l10n.messagingStatusNotSubscribed), findsOneWidget);
    expect(find.text(l10n.messagingNotSubscribedTitle), findsOneWidget);
    expect(find.text(l10n.messagingServiceSwitchLabel), findsNothing);
    expect(find.text(l10n.messagingTestSendButton), findsNothing);
    // What the add-on would send is still worth reading.
    expect(find.text(l10n.messagingTemplatesTitle), findsOneWidget);
  });

  testWidgets('a working service shows usage, dials and the texts sent', (
    tester,
  ) async {
    await pump(tester, _FakeRepo());

    expect(find.text(l10n.messagingStatusActive), findsOneWidget);
    expect(find.text(l10n.messagingUsageUsedOfLimit(137, 500)), findsOneWidget);
    expect(find.text(l10n.messagingServiceSwitchLabel), findsOneWidget);
    expect(find.text(l10n.messagingQuietHoursFrom('22:00')), findsOneWidget);
    expect(find.text(l10n.messagingTestSendButton), findsOneWidget);
    expect(find.text('فاتورة بيع'), findsOneWidget);
    // Only the kind the provider has not approved carries the badge.
    expect(find.text(l10n.messagingTemplateNotConfigured), findsOneWidget);
  });

  testWidgets('a spent allowance is called out', (tester) async {
    await pump(tester, _FakeRepo(used: 500));

    expect(find.text(l10n.messagingLimitReachedTitle), findsOneWidget);
  });

  testWidgets('switching the service off and saving sends the PATCH', (
    tester,
  ) async {
    final repo = _FakeRepo();
    await pump(tester, repo);

    final save = find.byKey(const ValueKey('messaging_save'));
    await tester.ensureVisible(save);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('messaging_service_switch')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messagingUnsavedBadge), findsOneWidget);

    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(repo.update?.isActive, isFalse);
    expect(find.text(l10n.messagingSavedMessage), findsOneWidget);
    expect(find.text(l10n.messagingStatusDisabled), findsOneWidget);
  });

  testWidgets('a failed test send is named in Arabic', (tester) async {
    await pump(
      tester,
      _FakeRepo(
        testResult: const MessagingSendResult(
          status: 'failed',
          errorCode: 'invalid_phone',
          errorDetail: 'LY phones must be made of 9 numbers',
        ),
      ),
    );

    final phone = find.byKey(const ValueKey('messaging_test_phone'));
    await tester.ensureVisible(phone);
    await tester.enterText(phone, '12345');
    await tester.pump();
    final send = find.byKey(const ValueKey('messaging_test_send'));
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(find.text(l10n.messagingTestFailedTitle), findsOneWidget);
    expect(find.text(l10n.messagingErrorInvalidPhone), findsOneWidget);
  });

  testWidgets('lays out on a wide screen too', (tester) async {
    await pump(tester, _FakeRepo(), size: const Size(1366, 900));

    expect(find.text(l10n.messagingUsageTitle), findsOneWidget);
  });
}

class _FakeRepo extends MessagingRepository {
  _FakeRepo({
    this.entitled = true,
    this.used = 137,
    this.testResult = const MessagingSendResult(status: 'sent'),
  }) : super(PosApiService());

  final bool entitled;
  final int used;
  final MessagingSendResult testResult;
  MessagingGatewayUpdate? update;
  MessagingGateway _gateway = const MessagingGateway(
    id: 1,
    name: 'رسائل دفتر',
    isDefault: true,
    quietHoursStart: ClockTime(22, 0),
    quietHoursEnd: ClockTime(8, 0),
  );

  @override
  Future<Result<MessagingServiceStatus>> loadStatus() async {
    return Ok(
      MessagingServiceStatus(
        entitled: entitled,
        available: entitled && _gateway.isActive,
        gateway: _gateway,
        usage: entitled
            ? MessagingUsage(
                used: used,
                limit: 500,
                remaining: 500 - used,
                resetsAt: DateTime(2026, 10, 1),
              )
            : null,
        usageError: entitled ? '' : 'not_entitled',
        templates: [
          MessagingTemplateInfo(
            kind: 'invoice',
            title: 'فاتورة بيع',
            description: 'تُرسل للعميل من تفاصيل الفاتورة.',
            example: 'شكرًا لتسوقك من محل النور. فاتورتك رقم 000123.',
            configured: entitled ? true : null,
          ),
          MessagingTemplateInfo(
            kind: 'marketing',
            title: 'عرض ترويجي',
            example: 'عرض من محل النور: خصم 20%',
            consentClass: 'marketing',
            configured: entitled ? false : null,
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayUpdate update,
  ) async {
    this.update = update;
    _gateway = MessagingGateway(
      id: id,
      name: _gateway.name,
      isDefault: true,
      isActive: update.isActive,
      maxMessagesPerMinute: update.maxMessagesPerMinute,
      dailyCap: update.dailyCap,
      quietHoursStart: update.quietHoursStart,
      quietHoursEnd: update.quietHoursEnd,
    );
    return Ok(_gateway);
  }

  @override
  Future<Result<MessagingSendResult>> testSend({
    required int id,
    required String to,
  }) async {
    return Ok(testResult);
  }
}
