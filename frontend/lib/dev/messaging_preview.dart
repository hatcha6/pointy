// Dev-only preview harness for the SMS settings page (Shop Settings).
//
// Renders the relay-hosted SMS status page full-viewport, backed by an
// in-memory fake repository (no backend). Pick the scenario with a `?screen=`
// query param and resize the browser to test responsiveness. Run with:
//
//   make frontend-messaging-preview
//
// Scenarios: active | not_subscribed | disabled | limit_reached | unreachable
//            | test_fail | test_ok
//
// The two test_* scenarios fire the test send on load, so the result callout
// is on screen without a click (Flutter web paints to a canvas).
//
// See AGENTS.md ("UI Preview Harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  final scenario = _screen();
  final viewModel = MessagingSettingsViewModel(
    _FakeMessagingRepository(scenario),
  );
  if (scenario.startsWith('test_')) {
    // Fire the test once the page's own first load has landed.
    void fire() {
      if (viewModel.hasStatus && !viewModel.isBusy) {
        viewModel.removeListener(fire);
        unawaited(viewModel.sendTest('0912345678'));
      }
    }

    viewModel.addListener(fire);
  }
  runApp(_PreviewApp(viewModel: viewModel));
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp({required this.viewModel});

  final MessagingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
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
      home: MessagingSettingsPage(viewModel: viewModel),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'active';
}

/// In-memory stand-in for the backend: a canned status per scenario, a PATCH
/// that applies the edit, and a test send that succeeds or fails.
class _FakeMessagingRepository extends MessagingRepository {
  _FakeMessagingRepository(this.scenario) : super(PosApiService());

  final String scenario;
  MessagingGateway? _saved;

  MessagingGateway get _gateway =>
      _saved ??
      MessagingGateway(
        id: 1,
        name: 'رسائل دفتر',
        isDefault: true,
        isActive: scenario != 'disabled',
        maxMessagesPerMinute: 30,
        quietHoursStart: const ClockTime(22, 0),
        quietHoursEnd: const ClockTime(8, 0),
        lastSeenAt: DateTime(2026, 9, 27, 10, 15),
        lastError: switch (scenario) {
          'limit_reached' => 'monthly_limit: monthly SMS limit reached',
          'test_fail' =>
            'provider_credit: wallet must have at least 0.15 LYD to send an sms',
          _ => '',
        },
        lastErrorAt: scenario == 'limit_reached' || scenario == 'test_fail'
            ? DateTime(2026, 9, 27, 9, 41)
            : null,
      );

  @override
  Future<Result<MessagingServiceStatus>> loadStatus() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final entitled = scenario != 'not_subscribed';
    final gateway = _gateway;
    final usage = switch (scenario) {
      'not_subscribed' || 'unreachable' => null,
      'limit_reached' => _usage(used: 500),
      'disabled' => _usage(used: 42),
      _ => _usage(used: 137),
    };
    return Ok(
      MessagingServiceStatus(
        entitled: entitled,
        available: entitled && gateway.isActive,
        testMode: scenario == 'test_fail' || scenario == 'test_ok',
        gateway: gateway,
        usage: usage,
        usageError: switch (scenario) {
          'not_subscribed' => 'not_entitled',
          'unreachable' => 'relay_unreachable',
          _ => '',
        },
        templates: _templates(
          configured: entitled && scenario != 'unreachable',
        ),
      ),
    );
  }

  static MessagingUsage _usage({required int used}) {
    return MessagingUsage(
      used: used,
      limit: 500,
      remaining: 500 - used,
      periodStart: DateTime(2026, 9, 1),
      resetsAt: DateTime(2026, 10, 1),
    );
  }

  @override
  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayUpdate update,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final current = _gateway;
    _saved = MessagingGateway(
      id: current.id,
      name: current.name,
      isDefault: true,
      isActive: update.isActive,
      maxMessagesPerMinute: update.maxMessagesPerMinute,
      dailyCap: update.dailyCap,
      quietHoursStart: update.quietHoursStart,
      quietHoursEnd: update.quietHoursEnd,
      lastSeenAt: current.lastSeenAt,
    );
    return Ok(_saved!);
  }

  @override
  Future<Result<MessagingSendResult>> testSend({
    required int id,
    required String to,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (scenario == 'test_fail') {
      return const Ok(
        MessagingSendResult(
          status: 'failed',
          errorCode: 'invalid_phone',
          errorDetail: 'LY phones must be made of 9 numbers',
        ),
      );
    }
    return const Ok(
      MessagingSendResult(
        status: 'sent',
        body: 'رسالة تجريبية من محل النور عبر دفتر: خدمة الرسائل تعمل بنجاح.',
      ),
    );
  }
}

/// The catalogue as the backend describes it (apps.messaging.sms_templates).
/// [configured] false leaves the two free-text kinds unapproved, the way a
/// fresh relay looks; null is "the relay could not be asked".
List<MessagingTemplateInfo> _templates({required bool configured}) {
  MessagingTemplateInfo item(
    String kind,
    String title,
    String description,
    String example, {
    bool marketing = false,
    bool approved = true,
  }) {
    return MessagingTemplateInfo(
      kind: kind,
      title: title,
      description: description,
      example: example,
      consentClass: marketing ? 'marketing' : 'transactional',
      configured: configured ? approved : null,
    );
  }

  return [
    item(
      'test',
      'رسالة تجريبية',
      'تُرسل من صفحة إعدادات الرسائل للتأكد من أن الخدمة تعمل.',
      'رسالة تجريبية من محل النور عبر دفتر: خدمة الرسائل تعمل بنجاح.',
    ),
    item(
      'invoice_link',
      'فاتورة بيع مع رابط',
      'تُرسل للعميل عند الضغط على «إرسال كرسالة» في تفاصيل الفاتورة.',
      'شكرًا لتسوقك من محل النور. فاتورتك رقم 000123 بقيمة 125.00 د.ل. '
          'لعرضها: https://daftar.example/invoices/7Kq2mX',
    ),
    item(
      'debt_reminder',
      'تذكير بدين',
      'تذكير للعميل بمبلغ مستحق عليه: يدويًا، أو يوميًا إذا فُعّل التذكير '
          'التلقائي.',
      'تذكير من محل النور: لديك مبلغ مستحق قدره 80.00 د.ل على الفاتورة رقم '
          '000123. نرجو المبادرة بالسداد.',
    ),
    item(
      'batch_recall',
      'استدعاء دفعة',
      'تُرسل لكل عميل اشترى من دفعة تم استدعاؤها.',
      'تنبيه هام من محل النور: يرجى التوقف عن استخدام شراب سعال 100 مل '
          '(دفعة رقم LOT-2291) ومراجعتنا فورًا لإرجاعه واسترداد قيمته كاملة. '
          'للاستفسار: 0912345678',
    ),
    item(
      'direct',
      'رسالة مباشرة',
      'رسالة يكتبها الموظف لعميل من شاشة المحادثات.',
      'رسالة من محل النور: طلبك جاهز للاستلام.',
      approved: false,
    ),
    item(
      'marketing',
      'عرض ترويجي',
      'نص الحملات التسويقية، ولا يُرسل إلا بعد موافقة المدير.',
      'عرض من محل النور: خصم 20% على العطور حتى نهاية الأسبوع! '
          '(لإيقاف العروض أبلغ المحل)',
      marketing: true,
      approved: false,
    ),
  ];
}
