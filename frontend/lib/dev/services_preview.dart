// Dev-only preview harness for «كروت دفتر»' direct services — airtime sent to a
// phone abroad, bills paid abroad.
//
// Renders the real catalog pane (with the «كروت دفتر» chip picked, so the menu
// stands in for the product grid) beside the real cart pane, on fake
// repositories — no backend, no auth, no register-session gate. The countries,
// networks, providers and flags are built in code (lib/dev/services_fixtures.dart),
// and the relay answers after a short, visible delay. Run with
// `make frontend-services-preview`, then pick a screen:
//
//   ?screen=strip                  «الكل»: the services strip above the brands
//   ?screen=airtime                the airtime tab, nothing chosen yet
//   ?screen=airtime-ready          Mali, a number, Orange Mali, 5,000: priced
//   ?screen=airtime-nigeria        a Nigerian number on MTN, a custom amount
//   ?screen=airtime-egypt          a network that sells fixed denominations
//   ?screen=airtime-ghana          a network whose amounts are approximate (≈)
//   ?screen=airtime-undetected     the relay cannot place the number
//   ?screen=airtime-detect-failed  the relay cannot be reached
//   ?screen=airtime-refused        the server refuses the quote
//   ?screen=airtime-dial-hint      digits that begin with the country's own code
//   ?screen=airtime-shared-code    a pasted +1: which country is it for?
//   ?screen=airtime-too-long       a number with too many digits
//   ?screen=airtime-invalid        the relay says it is not a number there
//   ?screen=airtime-mismatch       the server read the digits differently
//   ?screen=airtime-balance        the voucher balance cannot cover the price
//   ?screen=airtime-cart           the priced line in the cart
//   ?screen=dialog-delivered       the success dialog, with a long token
//   ?screen=dialog-refused         a charge the provider refused
//   ?screen=dialog-unknown         a charge whose answer never came
//   ?screen=dialog-requote         a held invoice whose price moved
//   ?screen=dialog-charging        the till while the provider is asked
//   ?screen=bills                  the bills tab: one card per type of bill
//   ?screen=bill:electricity       the electricity flow, step 1 (country)
//   ?screen=bill:electricity:ng    … step 2 (Nigeria's providers)
//   ?screen=bill:electricity:ng:account / :amount / :summary
//   ?screen=bill:tv:ml:amount      Canal+ Mali: fixed plans in Arabic
//   ?screen=bill:water             water: Senegal only, with the invoice number
//   ?screen=empty | error | loading   the services unavailable / unreadable / loading
//   add `-test` to any of them for the relay on its sandbox supplier
//   (`test_mode: true`: the «وضع تجريبي» banners, the «عملية تجريبية» marks),
//   `-dark` for the dark palette, and `&scale=1.3` for enlarged text
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/airtime_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/bill_flow_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_service_shelves.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/bill_flow_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_charge_issue_dialog.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_delivered_dialog.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_requote_dialog.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_provider_charge_overlay.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_cart_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'services_fake_repository.dart';
import 'services_fixtures.dart';
import 'voucher_menu_fixtures.dart';

void main() {
  PointyProductImageFrame.debugImageOverride = voucherPreviewArtResolver;
  runApp(ServicesPreviewApp(screen: _screen(), textScale: _textScale()));
}

/// `?scale=1.3`: the text size a cashier with enlarged text would see.
double _textScale() =>
    double.tryParse(Uri.base.queryParameters['scale'] ?? '') ?? 1;

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
  return parsed?.queryParameters['screen'] ?? 'strip';
}

/// Public so the capture test pumps exactly what the harness serves. The
/// caller sets `PointyProductImageFrame.debugImageOverride` to
/// [voucherPreviewArtResolver] so the brand art draws without a server.
class ServicesPreviewApp extends StatelessWidget {
  const ServicesPreviewApp({
    super.key,
    required this.screen,
    this.theme,
    this.instant = false,
    this.textScale = 1,
  });

  final String screen;

  /// The system's text scale: 1.3 is a common accessibility setting.
  final double textScale;

  /// Wins over the screen's own light/dark choice.
  final ThemeData? theme;

  /// Answer every fake read at once (the capture test); otherwise a short
  /// delay shows the loading states the way a real till would.
  final bool instant;

  @override
  Widget build(BuildContext context) {
    final dark = screen.endsWith('-dark');
    final undarkened = dark ? screen.substring(0, screen.length - 5) : screen;
    final testMode = undarkened.endsWith('-test');
    final name = testMode
        ? undarkened.substring(0, undarkened.length - 5)
        : undarkened;
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
      theme: theme ?? (dark ? PointyTheme.dark() : PointyTheme.light()),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: ServicesPreviewTill(
        scenario: name,
        instant: instant,
        testMode: testMode,
      ),
    );
  }
}

/// The till with the «كروت دفتر» chip picked and one scenario played on it.
class ServicesPreviewTill extends StatefulWidget {
  const ServicesPreviewTill({
    super.key,
    required this.scenario,
    this.instant = false,
    this.testMode = false,
    this.onReady,
  });

  final String scenario;
  final bool instant;

  /// The relay is on its sandbox supplier: the menu, the directory and every
  /// country say `test_mode: true`.
  final bool testMode;

  /// Called with the pieces a test wants to drive once the till is up.
  final void Function(ServicesPreviewHandle handle)? onReady;

  @override
  State<ServicesPreviewTill> createState() => _ServicesPreviewTillState();
}

/// What a test or a script can reach in the running preview.
class ServicesPreviewHandle {
  const ServicesPreviewHandle({
    required this.viewModel,
    required this.repository,
    required this.context,
  });

  final PosViewModel viewModel;
  final PreviewServicesRepository repository;

  /// A context under the till's navigator, for opening the bill flow.
  final BuildContext context;

  PosServiceShelves get shelves => viewModel.serviceShelves;
}

class _ServicesPreviewTillState extends State<ServicesPreviewTill> {
  late final PosViewModel _viewModel;
  late final PreviewServicesRepository _repository;

  @override
  void initState() {
    super.initState();
    final delay = widget.instant
        ? Duration.zero
        : const Duration(milliseconds: 350);
    final scenario = widget.scenario;
    final testMode = widget.testMode;
    final menu = VoucherMenu.fromJson({
      ...voucherPreviewMenuJson(),
      'services': servicesPreviewMenuServicesJson(testMode: testMode),
      if (testMode) 'test_mode': true,
    });
    _repository = PreviewServicesRepository(
      menu: menu,
      directoryDelay: delay,
      countryDelay: delay,
      detectDelay: widget.instant
          ? Duration.zero
          : const Duration(milliseconds: 900),
      quoteDelay: widget.instant
          ? Duration.zero
          : const Duration(milliseconds: 500),
    )..testMode = testMode;
    switch (scenario) {
      case 'error':
        _repository.failDirectory = true;
      case 'loading':
        _repository.holdDirectory = true;
      case 'empty':
        _repository.directory = ServicesDirectory.fromJson(const {
          'available': false,
          'error_code': 'switched_off',
          'countries': <Object?>[],
        });
      case 'airtime-first':
        _repository.noRecents = true;
      case 'airtime-detect-failed':
        _repository.failDetect = true;
      case 'airtime-refused':
        _repository.refuseQuote = 'invalid_phone';
      case 'airtime-mismatch':
        _repository.quoteSubscriberRef = '+22399999999';
      case 'airtime-balance':
        _repository.quoteExceedsFloat = true;
      case 'dialog-requote':
        _repository.quotePrice = 61.25;
    }
    _viewModel = PosViewModel(
      _PreviewCatalogRepository(),
      _PreviewRegisterSessionRepository(),
      _PreviewSaleRepository(),
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      integrationsRepository: _repository,
      sessionStorage: MemoryScopedJsonStorage(),
      // The requote scenario asks about a line the moment it is in the cart.
      serviceQuoteFreshFor: scenario == 'dialog-requote'
          ? Duration.zero
          : const Duration(minutes: 2),
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    await _viewModel.loadCurrentRegisterSession();
    await _viewModel.resumeRegisterSession();
    await _viewModel.applyQuery(
      _viewModel.query.copyWith(categories: const [_vouchersCategory]),
    );
    if (!mounted) {
      return;
    }
    final scenario = widget.scenario;
    final shelves = _viewModel.serviceShelves;
    if (scenario.startsWith('airtime') ||
        const {'empty', 'error', 'loading'}.contains(scenario)) {
      shelves.requestTab(ServiceKind.airtime);
    } else if (scenario == 'bills') {
      shelves.requestTab(ServiceKind.bill);
    }
    // After the first frame, so the menu is mounted when the scripts run.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      widget.onReady?.call(
        ServicesPreviewHandle(
          viewModel: _viewModel,
          repository: _repository,
          context: context,
        ),
      );
      if (widget.onReady == null) {
        await _play(scenario);
      }
    });
  }

  /// Plays a scenario on the till by driving the same view models the cashier's
  /// hands do.
  Future<void> _play(String scenario) async {
    final shelves = _viewModel.serviceShelves;
    final catalog = shelves.catalog!;
    await _viewModel.voucherMenu.ensureLoaded();
    await catalog.ensureLoaded();
    if (!mounted) {
      return;
    }
    if (scenario == 'airtime-cart') {
      final airtime = shelves.airtime!;
      await playAirtimeScenario(airtime, 'airtime-ready');
      // The price has to be in before the line can be: the button is off until.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_addReadyLine()) {
        airtime.afterAdded();
      }
    } else if (scenario.startsWith('airtime-')) {
      await playAirtimeScenario(shelves.airtime!, scenario);
    } else if (scenario.startsWith('bill:')) {
      await _playBill(scenario.split(':').skip(1).toList());
    } else if (scenario.startsWith('dialog-')) {
      await _playDialog(scenario);
    }
  }

  /// Puts the airtime line the form has priced in the cart, as the button does.
  bool _addReadyLine() {
    final quote = _viewModel.serviceShelves.airtime?.readyQuote;
    if (quote == null) {
      return false;
    }
    return _viewModel.addServiceLine(
      quote: quote,
      variantId: quote.serviceVariantId,
      title: 'شحن مباشر',
      testMode: widget.testMode,
    );
  }

  /// The dialogs a sale ends in, over the till, fed the answers a provider
  /// gives — the same objects the till builds from the server's JSON.
  Future<void> _playDialog(String scenario) async {
    switch (scenario) {
      case 'dialog-delivered':
        unawaited(
          showServiceDeliveredDialog(context, [
            _chargeResult(_airtimeCharged),
            _chargeResult(_electricityCharged),
          ], testMode: widget.testMode),
        );
      case 'dialog-refused':
        unawaited(
          showServiceChargeIssueDialog(context, [
            _chargeResult(_airtimeRefused),
          ], receiptNumber: 'R20261008000042'),
        );
      case 'dialog-unknown':
        unawaited(
          showServiceChargeIssueDialog(context, [
            _chargeResult(_electricityUnknown),
          ], receiptNumber: 'R20261008000042'),
        );
      case 'dialog-requote':
        final airtime = _viewModel.serviceShelves.airtime!;
        _repository.quotePrice = null;
        await playAirtimeScenario(airtime, 'airtime-ready');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        _addReadyLine();
        _repository.quotePrice = 61.25;
        final changes = await _viewModel.requoteServiceLines();
        if (mounted && changes.isNotEmpty) {
          unawaited(showServiceRequoteDialog(context, changes));
        }
    }
  }

  Future<void> _playBill(List<String> path) async {
    final shelves = _viewModel.serviceShelves;
    final type = billTypeFromJson(path.first);
    BillFlowViewModel? flow;
    unawaited(
      showBillFlow(
        context,
        create: () => flow = shelves.newBillFlow(type)!,
        testMode: widget.testMode,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final drive = flow;
    if (drive == null) {
      return;
    }
    await playBillScenario(drive, path);
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.pos,
            navigation: const _PreviewNavigation(),
          ),
          appBar: PointyAppBar(
            style: PointyAppBarStyle.highFocus,
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.appTitle),
          ),
          body: widget.scenario == 'dialog-charging'
              ? Stack(
                  children: [
                    _Workspace(viewModel: _viewModel),
                    Positioned.fill(
                      child: PosProviderChargeOverlay(
                        startedAt: DateTime.now().subtract(
                          const Duration(seconds: 17),
                        ),
                      ),
                    ),
                  ],
                )
              : _Workspace(viewModel: _viewModel),
        );
      },
    );
  }
}

IntegrationChargeResult _chargeResult(Map<String, Object?> json) =>
    IntegrationChargeResult.fromJson(json);

const Map<String, Object?> _airtimeCharged = {
  'fulfillment': 17,
  'provider': 'pointy',
  'kind': 'airtime',
  'subscriber_ref': '+22370123456',
  'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
  'outcome': 'charged',
  'status': 'confirmed',
  'provider_reference': '4602843',
  'receipt': {
    'title': 'شحن مباشر',
    'rows': [
      ['الشبكة', 'أورنج مالي'],
      ['الرقم', '+22370123456'],
      ['المبلغ المرسل', '5,000 فرنك أفريقي'],
      ['رقم العملية', '4602843'],
    ],
    'pin': '',
    'pin_label': 'رمز الشحن',
    'notice': 'تم إرسال الرصيد إلى الرقم المذكور، ولا يمكن استرداده.',
  },
};

const Map<String, Object?> _electricityCharged = {
  'fulfillment': 18,
  'provider': 'pointy',
  'kind': 'bill',
  'subscriber_ref': '04223568280',
  'option_label': 'كهرباء إيكيجا (مسبقة الدفع)',
  'outcome': 'charged',
  'status': 'confirmed',
  'receipt': {
    'title': 'دفع فاتورة كهرباء',
    'rows': [
      ['الجهة', 'كهرباء إيكيجا (مسبقة الدفع)'],
      ['رقم العدّاد', '04223568280'],
      ['المبلغ', '5,000 نيرة نيجيرية'],
      ['الوحدات', '10.7 ك.و.س'],
    ],
    'pin': '2737-6032-5315-7183-0856-4410',
    'pin_label': 'رمز الشحن',
    'notice': 'أدخل رمز الشحن في العدّاد.',
  },
};

const Map<String, Object?> _airtimeRefused = {
  'fulfillment': 19,
  'provider': 'pointy',
  'kind': 'airtime',
  'subscriber_ref': '+22370123456',
  'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
  'outcome': 'refused',
  'status': 'failed',
  'error_code': 'insufficient_float',
  'receipt': <String, Object?>{},
};

const Map<String, Object?> _electricityUnknown = {
  'fulfillment': 20,
  'provider': 'pointy',
  'kind': 'bill',
  'subscriber_ref': '04223568280',
  'option_label': 'كهرباء إيكيجا (مسبقة الدفع)',
  'outcome': 'unknown',
  'status': 'submitted',
  'needs_attention': true,
  'error_code': 'indeterminate',
  'provider_reference': 'PNT-77-1182',
  'receipt': <String, Object?>{},
};

/// Plays an airtime scenario on [airtime], waiting for the fake relay.
Future<void> playAirtimeScenario(
  AirtimeViewModel airtime,
  String scenario,
) async {
  final catalog = airtime.catalog;
  final directory = catalog.directory!;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  Future<void> pickCountry(String code) async {
    airtime.selectCountry(directory.country(code)!);
    await catalog.loadDetail(code);
    await settle();
  }

  Future<void> type(String digits) async {
    airtime.onPhoneInput(digits);
    await Future<void>.delayed(
      airtime.detectDebounce + const Duration(milliseconds: 1500),
    );
  }

  switch (scenario) {
    case 'airtime-country':
      await pickCountry('ML');
    case 'airtime-ready' || 'airtime-refused' || 'airtime-detect-failed':
      await pickCountry('ML');
      await type('70123456');
      if (scenario == 'airtime-detect-failed') {
        airtime.selectOperator(airtime.detail!.operator(289)!);
      }
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
    case 'airtime-undetected':
      await pickCountry('ML');
      await type('70120000');
    case 'airtime-dial-hint':
      await pickCountry('ML');
      await type('22370123456');
    case 'airtime-shared-code':
      airtime.onPhoneInput('+1 202 555 0123', pasted: true);
      await settle();
    case 'airtime-too-long':
      await pickCountry('ML');
      await type('70123456789012');
    case 'airtime-invalid':
      await pickCountry('ML');
      await type('70128888');
    case 'airtime-mismatch' || 'airtime-balance':
      await pickCountry('ML');
      await type('70123456');
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
    case 'airtime-nigeria':
      await pickCountry('NG');
      await type('08031234567');
      airtime.openCustomAmount();
      airtime.setCustomAmount('3,500');
    case 'airtime-egypt':
      await pickCountry('EG');
      await type('01012345678');
      airtime.selectAmount(airtime.operator!.amountFor('20')!);
    case 'airtime-ghana':
      await pickCountry('GH');
      airtime.selectOperator(airtime.detail!.operator(342)!);
      airtime.onPhoneInput('244123456');
      airtime.selectAmount(airtime.operator!.amounts[1]);
  }
}

/// Plays a bill scenario on [flow]: `[type, country, step]`.
Future<void> playBillScenario(BillFlowViewModel flow, List<String> path) async {
  final catalog = flow.catalog;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 120));
  await catalog.ensureLoaded();
  await settle();
  if (path.length < 2) {
    return;
  }
  final directory = catalog.directory!;
  final code = path[1].toUpperCase();
  final country = directory.country(code);
  if (country != null && flow.country?.code != code) {
    flow.selectCountry(country);
  }
  await catalog.loadDetail(code);
  await settle();
  if (path.length < 3) {
    return;
  }
  final step = path[2];
  final billers = flow.billers;
  if (billers.isEmpty) {
    return;
  }
  if (flow.biller == null) {
    flow.selectBiller(billers.first);
  }
  final biller = flow.biller!;
  if (step == 'account') {
    return;
  }
  flow.setAccount(biller.requiresInvoice ? '4521897' : '04223568280');
  if (biller.requiresInvoice) {
    flow.setInvoice('2024-118833');
  }
  flow.continueFromAccount();
  await settle();
  if (step == 'amount') {
    return;
  }
  if (biller.isFixed) {
    flow.selectPlan(biller.plans.first);
  } else if (biller.suggested.isNotEmpty && !biller.requiresInvoice) {
    flow.selectSuggestion(biller.suggested[1]);
  } else {
    flow.openCustomAmount();
    flow.setCustomAmount('15000');
  }
  flow.continueFromAmount();
  await Future<void>.delayed(const Duration(milliseconds: 900));
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final catalog = PosCatalogPane(
          viewModel: viewModel,
          capabilities: _managerCaps,
          // The wallet is not in the preview: the button shows, and moves
          // nothing.
          onTransferVoucherBalance: () async => false,
        );
        if (AppBreakpoints.usesTwoPane(width)) {
          return TwoPaneLayout(
            minPrimaryWidth: 390,
            secondaryPaneMaxWidth: AppPaneWidths.orderPaneMaxWidthFor(width),
            primaryPane: catalog,
            secondaryPane: PosCartPane(
              viewModel: viewModel,
              contactRepository: ContactRepository(PosApiService()),
              capabilities: _managerCaps,
            ),
          );
        }
        final l10n = AppLocalizations.of(context)!;
        return Column(
          children: [
            Expanded(child: catalog),
            PointyCompactOrderLauncher(
              title: l10n.currentSaleTitle,
              lineCountLabel: l10n.lineItemCount(viewModel.cart.length),
              totalLabel: formatMoney(viewModel.total),
              actionLabel: l10n.openCartSheetButton,
              icon: Icons.shopping_cart_checkout_outlined,
              onPressed: () {},
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

const _vouchersCategory = ProductCategory(
  id: 99,
  name: 'كروت دفتر',
  isQuickAccess: true,
  isSystem: true,
  systemKey: ProductCategorySystemKey.pointyVouchers,
);

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _PreviewNavigation implements AppNavigation {
  const _PreviewNavigation();

  @override
  PosUser get currentUser => _managerUser;

  @override
  AuthorizationCapabilities get capabilities => _managerCaps;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

/// A few ordinary products, so a search typed over the menu has a grid to
/// fall back to.
class _PreviewCatalogRepository extends CatalogRepository {
  _PreviewCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: [], hasMore: false));

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async {
    return const Ok([
      ProductCategory(id: 1, name: 'مشروبات', isQuickAccess: true),
      _vouchersCategory,
      ProductCategory(id: 2, name: 'وجبات خفيفة', isQuickAccess: true),
      ProductCategory(id: 3, name: 'منظفات', isQuickAccess: true),
    ]);
  }
}

class _PreviewRegisterSessionRepository extends RegisterSessionRepository {
  _PreviewRegisterSessionRepository() : super(PosApiService());

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async {
    return Ok(
      RegisterSession(
        id: 12,
        sessionNumber: 'RS-12',
        status: 'open',
        ownerName: 'سالم',
        openingCash: 100,
        openedAt: DateTime(2026, 10, 7, 8),
      ),
    );
  }
}

/// Totals the cart from the sealed quotes the service lines carry (the fake
/// relay writes the price at the end of them), so the panel reconciles.
class _PreviewSaleRepository extends SaleRepository {
  _PreviewSaleRepository() : super(PosApiService());

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    var subtotal = 0.0;
    for (final line in draft.lines) {
      final quote = line.integration?.quote ?? '';
      final price = RegExp(r'(\d+\.\d{2})$').firstMatch(quote)?.group(1);
      subtotal += (double.tryParse(price ?? '') ?? 0) * line.quantity;
    }
    return Ok(
      SaleDiscountPreview(
        subtotal: subtotal,
        discountTotal: 0,
        total: subtotal,
      ),
    );
  }

  @override
  Future<Result<Map<int, double>>> loadLineCosts(List<int> variantIds) async =>
      const Ok({});
}
