// Dev-only preview harness for the SMS settings page (Shop Settings).
//
// Renders the relay-hosted SMS status page full-viewport, backed by an
// in-memory fake repository (no backend). Pick the scenario with a `?screen=`
// query param and resize the browser to test responsiveness. Run with:
//
//   make frontend-messaging-preview
//
// Scenarios: active | not_subscribed | disabled | limit_reached | unreachable
//            | test_fail | test_ok | prepaid | prepaid_empty | prepaid_owing
//
// The prepaid_* scenarios are SMS paid per SMS part from the SMS balance: a
// funded one, an empty one with the transfer from the wallet on the page, and
// one below zero after a message went out longer than it was held for.
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
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/repositories/wallet_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_settings_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  final scenario = _screen();
  final wallet = _FakeWalletRepository();
  final viewModel = MessagingSettingsViewModel(
    _FakeMessagingRepository(scenario, wallet),
    wallet: scenario.startsWith('prepaid') ? WalletViewModel(wallet) : null,
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
  _FakeMessagingRepository(this.scenario, this.wallet) : super(PosApiService());

  final String scenario;

  /// Where the prepaid scenarios keep the SMS balance, so a transfer shows.
  final _FakeWalletRepository wallet;
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
    final prepaid = scenario.startsWith('prepaid');
    final entitled = prepaid
        ? wallet.sms >= 0.15
        : scenario != 'not_subscribed';
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
        smsWallet: prepaid ? wallet.smsWallet : null,
        usage: prepaid
            ? const MessagingUsage(used: 37, limit: 0, remaining: -1)
            : usage,
        usageError: switch (scenario) {
          'not_subscribed' => 'not_entitled',
          'unreachable' => 'relay_unreachable',
          _ => '',
        },
        templateGroups: _templateGroups,
        templates: _templates(
          configured: entitled && scenario != 'unreachable',
          autoMessages: gateway.autoMessages,
          partPrice: prepaid ? 0.15 : null,
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
      autoMessages: current.autoMessages,
    );
    return Ok(_saved!);
  }

  @override
  Future<Result<MessagingGateway>> setAutoMessage(
    int id, {
    required String kind,
    required bool enabled,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final current = _gateway;
    _saved = MessagingGateway(
      id: current.id,
      name: current.name,
      isDefault: true,
      isActive: current.isActive,
      maxMessagesPerMinute: current.maxMessagesPerMinute,
      dailyCap: current.dailyCap,
      quietHoursStart: current.quietHoursStart,
      quietHoursEnd: current.quietHoursEnd,
      lastSeenAt: current.lastSeenAt,
      autoMessages: {...current.autoMessages, kind: enabled},
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

/// The catalogue as the backend describes it (apps.messaging.sms_templates),
/// copied from the Django specs. [configured] false is "the relay could not be
/// asked" (null on every row); true leaves the kinds marked pending unapproved,
/// the way a relay looks before the operator has registered them. [partPrice]
/// prices each example the way a prepaid shop pays: per SMS part.
List<MessagingTemplateInfo> _templates({
  required bool configured,
  required Map<String, bool> autoMessages,
  double? partPrice,
}) {
  return [
    for (final t in _catalog)
      MessagingTemplateInfo(
        kind: t.kind,
        title: t.title,
        description: t.description,
        example: t.example,
        group: t.group,
        consentClass: t.marketing ? 'marketing' : 'transactional',
        configured: configured ? !t.pending : null,
        automatic: t.auto != null,
        autoEnabled: t.auto == null ? null : autoMessages[t.kind] ?? t.auto,
        autoLabel: t.autoLabel,
        exampleParts: t.parts,
        examplePrice: partPrice == null ? null : partPrice * t.parts,
      ),
  ];
}

/// One row of the catalogue: [auto] is where its switch starts, null for a
/// text sent from a button.
class _T {
  const _T(
    this.kind,
    this.title,
    this.group,
    this.description,
    this.example, {
    required this.parts,
    this.auto,
    this.autoLabel = '',
    this.marketing = false,
    this.pending = false,
  });

  final String kind;
  final String title;
  final String group;
  final String description;
  final String example;
  final int parts;
  final bool? auto;
  final String autoLabel;
  final bool marketing;
  final bool pending;
}

const _templateGroups = [
  MessagingTemplateGroup(key: 'sales', title: 'المبيعات والفواتير'),
  MessagingTemplateGroup(key: 'debts', title: 'الديون والتحصيل'),
  MessagingTemplateGroup(key: 'jobs', title: 'الصيانة والطلبات'),
  MessagingTemplateGroup(key: 'consignment', title: 'الأمانات'),
  MessagingTemplateGroup(key: 'stock', title: 'المخزون'),
  MessagingTemplateGroup(key: 'staff', title: 'الموظفون'),
  MessagingTemplateGroup(key: 'owner', title: 'تقارير المالك'),
  MessagingTemplateGroup(key: 'other', title: 'رسائل أخرى'),
  MessagingTemplateGroup(key: 'marketing', title: 'التسويق'),
];

const _catalog = <_T>[
  _T(
    'test',
    'رسالة تجريبية',
    'other',
    'تُرسل من صفحة إعدادات الرسائل للتأكد من أن الخدمة تعمل.',
    'رسالة تجريبية من محل النور عبر دفتر: خدمة الرسائل تعمل بنجاح.',
    parts: 1,
  ),
  _T(
    'invoice',
    'فاتورة بيع',
    'sales',
    'تُرسل للعميل عند الضغط على «إرسال كرسالة» في تفاصيل الفاتورة، حين لا يتوفر رابط لعرض الفاتورة.',
    'شكرًا لتسوقك من محل النور. فاتورتك رقم R20261002000123 بقيمة 125.00 د.ل.',
    parts: 2,
  ),
  _T(
    'invoice_link',
    'فاتورة بيع مع رابط',
    'sales',
    'مثل فاتورة البيع، ومعها رابط يعرض الفاتورة كاملة.',
    'شكرًا لتسوقك من محل النور. فاتورتك رقم R20261002000123 بقيمة 125.00 د.ل. لعرضها: https://daftar.example/invoices/7Kq2mX',
    parts: 2,
  ),
  _T(
    'debt_reminder',
    'تذكير بدين',
    'debts',
    'تذكير للعميل بمبلغ مستحق عليه: يدويًا، أو يوميًا إذا فُعّل التذكير التلقائي.',
    'تذكير من محل النور: لديك مبلغ مستحق قدره 80.00 د.ل على الفاتورة رقم R20261002000123. نرجو المبادرة بالسداد.',
    parts: 2,
    auto: false,
    autoLabel:
        'كل يوم في العاشرة صباحًا لكل فاتورة آجلة حلّ موعدها ولم تُسدَّد.',
  ),
  _T(
    'debt_reminder_link',
    'تذكير بدين مع رابط',
    'debts',
    'مثل التذكير بالدين، ومعه رابط يعرض الفاتورة.',
    'تذكير من محل النور: لديك مبلغ مستحق قدره 80.00 د.ل على الفاتورة رقم R20261002000123. التفاصيل: https://daftar.example/invoices/7Kq2mX',
    parts: 2,
  ),
  _T(
    'consignment_sale',
    'بيع أمانة',
    'consignment',
    'تُرسل لصاحب الأمانة عند بيع قطعته، إذا فُعّلت رسائل الأمانات في إعدادات الأمانات.',
    'مرحبًا أحمد، تم بيع أمانتكم هاتف سامسونج A54 (رقم U-0042) لدى محل النور. صافي المستحق لكم 900.00 د.ل، نرجو زيارتنا لاستلامه.',
    parts: 2,
  ),
  _T(
    'consignment_payout',
    'تسليم مستحقات أمانة',
    'consignment',
    'تُرسل لصاحب الأمانة عند صرف مستحقاته، إذا فُعّلت رسائل الأمانات في إعدادات الأمانات.',
    'محل النور: تم تسليمكم مبلغ 900.00 د.ل بموجب السند رقم PAY-0007 مقابل بيع هاتف سامسونج A54. شكرًا لتعاملكم معنا.',
    parts: 2,
  ),
  _T(
    'consignment_claim',
    'تسوية حادث أمانة',
    'consignment',
    'تُرسل لصاحب الأمانة عند صرف تعويض عن قطعة تضررت أو فُقدت، إذا فُعّلت رسائل الأمانات في إعدادات الأمانات.',
    'محل النور: تم تسليمكم مبلغ 450.00 د.ل تسويةً عن هاتف سامسونج A54 بموجب المحضر INC-0003، سند الصرف رقم PAY-0008.',
    parts: 2,
  ),
  _T(
    'batch_recall',
    'استدعاء دفعة',
    'stock',
    'تُرسل لكل عميل اشترى من دفعة تم استدعاؤها.',
    'تنبيه هام من محل النور: يرجى التوقف عن استخدام شراب سعال 100 مل (دفعة رقم LOT-2291) ومراجعتنا فورًا لإرجاعه واسترداد قيمته كاملة. للاستفسار: 0912345678',
    parts: 3,
  ),
  _T(
    'month_end_report',
    'ملخص إقفال الشهر',
    'owner',
    'تُرسل لهاتف المالك يوم الإقفال الشهري إذا ضُبط رقم لتقرير الإقفال.',
    'محل النور - إقفال 2026/08: المبيعات 48,200.00 د.ل، الربح الإجمالي 9,650.00 د.ل، صافي الربح 6,120.00 د.ل، النقدية 12,400.00 د.ل، ذمم العملاء 3,300.00 د.ل. التقرير الكامل في التطبيق.',
    parts: 3,
  ),
  _T(
    'direct',
    'رسالة مباشرة',
    'other',
    'رسالة يكتبها الموظف لعميل من شاشة المحادثات.',
    'رسالة من محل النور: طلبك جاهز للاستلام.',
    parts: 1,
    pending: true,
  ),
  _T(
    'marketing',
    'عرض ترويجي',
    'marketing',
    'نص الحملات التسويقية، ولا يُرسل إلا بعد موافقة المدير.',
    'عرض من محل النور: خصم 20% على العطور حتى نهاية الأسبوع! (لإيقاف العروض أبلغ المحل)',
    parts: 2,
    marketing: true,
    pending: true,
  ),
  _T(
    'quotation',
    'عرض سعر',
    'sales',
    'تُرسل للعميل عند الضغط على «إرسال كرسالة» في عرض سعر، حين لا يتوفر رابط لعرضه.',
    'محل النور: عرض السعر R20261002000124 بقيمة 1,250.00 د.ل، ساري حتى 2026/10/20.',
    parts: 2,
  ),
  _T(
    'quotation_link',
    'عرض سعر مع رابط',
    'sales',
    'مثل عرض السعر، ومعه رابط يعرضه كاملًا.',
    'محل النور: عرض السعر R20261002000124 بقيمة 1,250.00 د.ل، ساري حتى 2026/10/20. لعرضه: https://daftar.example/invoices/7Kq2mX',
    parts: 2,
  ),
  _T(
    'refund_issued',
    'تسجيل مرتجع',
    'sales',
    'تُرسل للعميل حين يُسجَّل مرتجع على فاتورته، فيعرف بكل ما يُرجع باسمه.',
    'محل النور: سُجّل مرتجع بقيمة 45.00 د.ل على فاتورتكم رقم R20261002000123.',
    parts: 2,
    auto: false,
    autoLabel: 'عند تسجيل مرتجع على فاتورة عميل له رقم هاتف.',
  ),
  _T(
    'warranty_registered',
    'تسجيل ضمان',
    'sales',
    'تُرسل للعميل عند بيعه قطعة بضمان، وفيها رقمها التسلسلي ونهاية ضمانها.',
    'محل النور: ضمان آيفون 15 برو (356789104512347) حتى 2027/10/02.',
    parts: 1,
    auto: false,
    autoLabel: 'عند بيع قطعة بضمان (برقم تسلسلي أو IMEI) لعميل له رقم هاتف.',
    pending: true,
  ),
  _T(
    'credit_invoice',
    'فاتورة آجلة',
    'debts',
    'تُرسل للعميل عند البيع له بالآجل: ما بقي عليه من الفاتورة، ومتى يستحق.',
    'محل النور: عليكم 80.00 د.ل من الفاتورة R20261002000123، تستحق في 2026/10/15.',
    parts: 2,
    auto: true,
    autoLabel: 'عند كل بيع آجل لعميل له رقم هاتف.',
  ),
  _T(
    'payment_received',
    'استلام دفعة',
    'debts',
    'إيصال للعميل بما دفعه من دينه، وبما بقي على حسابه بعدها.',
    'محل النور: استلمنا منكم 50.00 د.ل، والمتبقي على حسابكم 30.00 د.ل.',
    parts: 1,
    auto: true,
    autoLabel: 'عند تسجيل دفعة من عميل على حسابه أو على فاتورة آجلة.',
  ),
  _T(
    'account_balance',
    'رصيد الحساب',
    'debts',
    'تُرسل للعميل عند الضغط على «إرسال الرصيد برسالة» في صفحته: كل ما عليه حتى اليوم.',
    'محل النور: المستحق على حسابكم حتى 2026/10/02 هو 130.00 د.ل.',
    parts: 1,
  ),
  _T(
    'due_date_changed',
    'تغيير موعد الاستحقاق',
    'debts',
    'تُرسل للعميل حين يتغير موعد استحقاق فاتورته الآجلة.',
    'محل النور: استحقاق فاتورتكم R20261002000123 أصبح 2026/11/15، المتبقي 80.00 د.ل.',
    parts: 2,
    auto: false,
    autoLabel: 'عند تغيير موعد استحقاق فاتورة آجلة.',
  ),
  _T(
    'job_received',
    'استلام طلب',
    'jobs',
    'تأكيد للعميل باستلام جهازه أو مركبته، ومعه رقم الطلب.',
    'محل النور: استلمنا هاتف سامسونج A54، رقم طلبكم REP-20260926-000036.',
    parts: 1,
    auto: false,
    autoLabel: 'عند فتح طلب صيانة أو أمر عمل لعميل له رقم هاتف.',
  ),
  _T(
    'job_estimate',
    'تكلفة الطلب بانتظار الموافقة',
    'jobs',
    'تُرسل للعميل بالتكلفة المقدّرة ليوافق قبل بدء العمل.',
    'محل النور: تكلفة طلبكم (هاتف سامسونج A54) 85.00 د.ل، ننتظر موافقتكم.',
    parts: 1,
    auto: true,
    autoLabel: 'حين يصل الطلب إلى مرحلة موافقة الزبون وفيه تكلفة مقدّرة.',
  ),
  _T(
    'job_ready',
    'جاهز للاستلام',
    'jobs',
    'تُرسل للعميل حين يصبح جهازه أو مركبته جاهزًا للاستلام.',
    'محل النور: طلبكم (هاتف سامسونج A54) جاهز للاستلام.',
    parts: 1,
    auto: true,
    autoLabel:
        'حين يصل الطلب إلى مرحلة «جاهز للاستلام» (تُحدَّد في مراحل سير العمل)، ومعه المتبقي إن كان على الطلب مبلغ.',
  ),
  _T(
    'job_ready_due',
    'جاهز للاستلام مع المتبقي',
    'jobs',
    'مثل «جاهز للاستلام»، حين يكون الطلب مفوترًا وعليه مبلغ لم يُدفع.',
    'محل النور: طلبكم (هاتف سامسونج A54) جاهز للاستلام، المتبقي 85.00 د.ل.',
    parts: 1,
  ),
  _T(
    'job_returned',
    'جاهز للاستلام دون إصلاح',
    'jobs',
    'تُرسل للعميل حين يُغلق طلبه دون إصلاح ويمكنه استلام قطعته.',
    'محل النور: طلبكم (هاتف سامسونج A54) جاهز للاستلام دون إصلاح.',
    parts: 1,
    auto: true,
    autoLabel: 'حين يُغلق الطلب دون إصلاح (رفض أو تعذّر) وينتظر الاستلام.',
  ),
  _T(
    'job_pickup_reminder',
    'تذكير بالاستلام',
    'jobs',
    'تذكير للعميل بطلب جاهز لم يستلمه بعد.',
    'محل النور: طلبكم (هاتف سامسونج A54) بانتظار استلامكم منذ 3 أيام.',
    parts: 1,
    auto: true,
    autoLabel:
        'بعد 3 أيام من الجاهزية، ثم بعد 10 أيام، ثم بعد 30 يومًا إن لم يُستلم.',
  ),
  _T(
    'job_delivered',
    'التسليم والضمان',
    'jobs',
    'شكر للعميل عند تسليمه طلبه، ومعه نهاية ضمان الإصلاح.',
    'محل النور: شكرًا لكم، ضمان (هاتف سامسونج A54) ساري حتى 2026/12/31.',
    parts: 1,
    auto: false,
    autoLabel: 'عند تسليم طلب عليه ضمان إصلاح.',
  ),
  _T(
    'payroll_paid',
    'صرف الراتب',
    'staff',
    'تُرسل لكل موظف له رقم هاتف عند صرف رواتب الشهر.',
    'محل النور: صُرف راتبكم عن 2026/09، والصافي 1,450.00 د.ل.',
    parts: 1,
    auto: false,
    autoLabel: 'عند تسجيل صرف الرواتب، لكل موظف له رقم هاتف.',
  ),
];

/// The wallet behind the prepaid scenarios: 120 dinars in the main wallet
/// and whatever the SMS balance was given ("prepaid_empty" starts at zero,
/// "prepaid_owing" below it).
class _FakeWalletRepository extends WalletRepository {
  _FakeWalletRepository() : super(PosApiService());

  double balance = 120;
  double sms = switch (_screen()) {
    'prepaid_empty' => 0,
    'prepaid_owing' => -0.3,
    _ => 6.75,
  };

  SmsWallet get smsWallet => SmsWallet(
    balance: sms,
    price: 0.15,
    messagesLeft: sms <= 0 ? 0 : (sms * 1000).round() ~/ 150,
  );

  @override
  Future<Result<WalletOverview>> loadWallet() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return Ok(
      WalletOverview(
        available: true,
        balance: balance,
        currency: 'LYD',
        testMode: false,
        topUpOptions: null,
        recentTopUps: const [],
        recentEntries: const [],
        settings: const WalletSettings(recordTopUpsAsExpenses: true),
        sms: smsWallet,
      ),
    );
  }

  @override
  Future<Result<WalletSmsAllocation>> allocateToSms({
    required String amount,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final value = double.parse(amount);
    balance -= value;
    sms += value;
    return Ok(
      WalletSmsAllocation(balance: balance, sms: smsWallet, replayed: false),
    );
  }
}
