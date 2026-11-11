// Dev-only preview harness for «دفتر كروت» (safe to delete): a separate web
// entrypoint, never imported by lib/main.dart, so it does not ship.
//
//   make cards-preview, then ?screen=board | home | brand | brand-itunes |
//   sign-in | sign-in-code | checkout | wallet-code | preparing |
//   preparing-slow | refunded | reveal | my-cards | account | signed-out |
//   notice | splash | payment-page (&url=) ; top-ups by ID: topup (a game the relay looks up) |
//   topup-saved | topup-zone | topup-server | topup-telegram | topup-steam |
//   topup-gift | topup-checkout | topup-preparing | topup-done |
//   topup-receipt | topup-refunded | topup-board ;
//   add &theme=dark for dark, &channel=ios|play for a store
//   build's shelf
//   and &lang=en or &lang=fr for English or French (only while
//   AppSettings.languageChoice is on).
//
//   ?screen=home plays scripted purchases: a chip on top says how the next
//   one ends (card, refund, review, unpaid, wrong code, declined, offline)
//   and each purchase moves it on.
//
//   make cards-preview-live: the same, signed in, on the real shelf of a local
//   relay (make relay-run, catalog pushed) - `?screen=home` is the whole app
//   with nothing to sign in to and nothing really paid.
//
// Every screen runs its real code against the fixture relay
// (cards_fixtures.dart). The board lays the main ones out in phone frames.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import '../src/app.dart';
import '../src/core/push/push.dart';
import '../src/data/models/catalog.dart';
import '../src/data/models/customer.dart';
import '../src/data/models/order.dart';
import '../src/design/cards_theme.dart';
import '../src/features/card_payment/payment_page_view.dart';
import '../src/features/brand/brand_page.dart';
import '../src/features/card_payment/card_payment_page.dart';
import '../src/features/checkout/checkout_model.dart';
import '../src/features/checkout/checkout_sheet.dart';
import '../src/features/legal/about_page.dart';
import '../src/features/legal/legal_document.dart';
import '../src/features/legal/legal_page.dart';
import '../src/features/onboarding/onboarding_page.dart';
import '../src/features/orders/order_progress_page.dart';
import '../src/features/orders/order_watcher.dart';
import '../src/features/reveal/reveal_page.dart';
import '../src/data/models/campaign.dart';
import '../src/features/attribution/reward_sheet.dart';
import '../src/features/shell/cards_shell.dart';
import '../src/features/sign_in/sign_in_sheet.dart';
import '../src/features/topup/account_form_model.dart';
import '../src/features/topup/topup_done_page.dart';
import '../src/features/topup/topup_order_page.dart';
import '../src/dependencies.dart';
import '../src/shared/cards_scope.dart';
import 'cards_fixtures.dart';
import '../src/core/esim/esim_device.dart';
import '../src/core/money.dart';
import '../src/data/models/esim.dart';
import '../src/features/esim/esim_checkout.dart';
import '../src/features/esim/esim_destination_page.dart';
import '../src/features/esim/esim_page.dart';
import '../src/features/esim/esim_plan_sheet.dart';
import '../src/features/esim/esim_store_page.dart';
import 'preview_scenarios.dart';
import 'scenario_chip.dart';
import 'splash_lab.dart';

Future<void> main() async {
  // Plain addresses like the real web build. The path opens like a tapped
  // cards.dftr.ly link: /category/gaming?screen=home, /brand/pubg?screen=home.
  usePathUrlStrategy();
  final query = Uri.base.queryParameters;
  final screen = query['screen'] ?? 'board';
  // `&slow=8`: every animation eight times slower, to look at a transition.
  timeDilation = double.tryParse(query['slow'] ?? '') ?? 1;
  final dark = query['theme'] == 'dark';
  // `&platform=ios` or `android`: the page as that phone's browser has it
  // (the web «get the app» bar). A desktop browser's phone emulation still
  // reports a Mac, so it has to be said.
  // Only a debug build may set it: a release build of the harness (fast to
  // load on a phone's Safari) leaves the platform alone.
  if (kDebugMode) {
    debugDefaultTargetPlatformOverride = switch (query['platform']) {
      'ios' => TargetPlatform.iOS,
      'android' => TargetPlatform.android,
      _ => null,
    };
  }
  const shelfRelay = String.fromEnvironment('CARDS_PREVIEW_RELAY');
  // The whole app plays scripted purchases: each one ends the next way.
  final scenarios = screen == 'home' ? PreviewScenarios() : null;
  final dependencies = fixtureDependencies(
    esim: true,
    signedIn:
        screen != 'signed-out' &&
        !screen.startsWith('sign-in') &&
        !screen.startsWith('heard-from'),
    shelfRelay: shelfRelay.isEmpty ? null : Uri.parse(shelfRelay),
    // A late card stays late however often the page asks.
    client: switch (screen) {
      'preparing-slow' => fixtureRelay(orderStatus: 'fulfilling'),
      'topup-preparing' => fixtureRelay(
        orderStatus: 'fulfilling',
        topUps: true,
      ),
      _ => null,
    },
    // The shelf has the cards sent to an account too, and their look-ups
    // take as long as a game's do.
    topUps: true,
    lookUpTakes: const Duration(milliseconds: 900),
    scenarios: scenarios,
    // The card form's Moamalat: `&card=verify` has the bank ask for its
    // code, `&card=decline` refuses the card.
    moamalat: FakeMoamalatClient(
      verify: query['card'] == 'verify',
      decline: query['card'] == 'decline',
    ),
    // `&channel=ios` or `play`: the shelf as a store build has it (games and
    // gift cards «على الموقع» while the console says so).
    channel: query['channel'] ?? 'apk',
  );
  dependencies.settings.setLanguage(query['lang'] ?? 'ar');
  // `&phone=none`: a phone with no eSIM. `&phone=old`: one too old to install
  // from a link. Otherwise a current iPhone.
  dependencies.overrideEsimCompatibility(
    EsimCompatibility(
      repository: dependencies.esim,
      device: _PreviewPhone(query['phone'] ?? ''),
    ),
  );
  if (screen != 'topup') {
    // Two Free Fire players this phone topped up before.
    await dependencies.accounts.remember('tu-free-fire', {
      'player_id': '7788990011',
    }, name: 'Noor.FF');
    await dependencies.accounts.remember('tu-free-fire', {
      'player_id': '5123456789',
    }, name: 'ShadowFox_LY');
  }
  if (screen == 'heard-from-link') {
    // As if the app had opened cards.dftr.ly/go/UNI1.
    dependencies.attribution
      ..openedLink(Uri.parse('https://cards.dftr.ly/go/UNI1'))
      ..offer = CampaignOffer.fromJson(fixtureCampaign);
  }
  if (screen == 'notice') {
    Future.delayed(const Duration(seconds: 2), () {
      dependencies.push.arrived(
        PushNotice(
          title: 'رمز بطاقتك جاهز',
          body: 'ليبيانا · 10 دينار: اضغط لعرض الرمز.',
          order: 'order-1',
          onOpen: () => dependencies.links.open(
            Uri.parse('https://cards.dftr.ly/my-cards/order-1'),
          ),
        ),
      );
    });
  }
  runApp(
    _DuoColumn(
      on: query['duo'] != null,
      child: CardsApp(
        dependencies: dependencies,
        overlay: scenarios == null
            ? null
            : (context, child) => Stack(
                children: [
                  child!,
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 6,
                    left: 12,
                    right: 12,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ScenarioChip(scenarios: scenarios),
                    ),
                  ),
                ],
              ),
        home: Theme(
          data: dark ? CardsTheme.dark() : CardsTheme.light(),
          child: screen == 'board'
              ? const _Board()
              : PreviewSurface(screen: screen),
        ),
      ),
    ),
  );
}

final CardBrand _libyana = CardBrand.fromJson(
  (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
);
final CardBrand _itunes = CardBrand.fromJson(
  (fixtureCatalog['brands'] as List)[4] as Map<String, dynamic>,
);
CardBrand _topUp(int index) => CardBrand.fromJson(fixtureTopUpBrands[index]);

/// The Free Fire account typed in, for the checkout to send to.
AccountFormModel _typedAccount(CardsDependencies dependencies) {
  final brand = _topUp(0);
  return AccountFormModel(
      brand: brand,
      orders: dependencies.orders,
      accounts: dependencies.accounts,
      signedIn: () => true,
    )
    ..itemKey = brand.items[2].key
    ..controllerOf('player_id').text = '5123456789';
}

/// One screen or sheet by name; sheets open over a blank page on load.
class PreviewSurface extends StatelessWidget {
  const PreviewSurface({super.key, required this.screen});

  final String screen;

  @override
  Widget build(BuildContext context) {
    final dependencies = CardsScope.of(context);
    return switch (screen) {
      'home' || 'signed-out' => const CardsShell(),
      'esim' => const EsimStorePage(),
      // The shelf as a link opens it: a month's trip needing 5 GB, cheapest
      // first; and only what is on offer.
      'esim-filtered' => const EsimStorePage(
        filter: EsimShelfFilter(
          minDays: 30,
          minMb: 5120,
          sort: EsimSort.cheapest,
        ),
      ),
      'esim-offers' => const EsimStorePage(
        filter: EsimShelfFilter(offersOnly: true),
      ),
      'esim-destination' => const EsimDestinationPage(
        destination: 'turkey',
        name: 'تركيا',
      ),
      'esim-plan' => _SheetHost(
        sheet: EsimPlanSheet(
          destination: EsimDestination.fromJson(fixtureEsimDestination),
          plan: EsimDestination.fromJson(fixtureEsimDestination).plans[1],
        ),
      ),
      'esim-checkout' => _SheetHost(
        sheet: CheckoutSheet(
          model: CheckoutModel(
            orders: dependencies.orders,
            brand: esimBrand('تركيا', 'TR'),
            item: CardItem(
              key: 'esim:merhaba-30days-3gb',
              country: '',
              // As the real checkout writes it: the amount isolated.
              label: '\u20663 GB\u2069 · 30 يوماً',
              faceValue: '',
              faceCurrency: '',
              price: Money.parse('82.500'),
              regularPrice: Money.parse('82.500'),
              promoBadge: '',
              available: true,
              rank: 0,
            ),
          )..load(),
        ),
      ),
      'esim-preparing' => OrderProgressPage(
        brand: esimBrand('أوروبا', ''),
        openPaymentPage: false,
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(
            fixtureOrder(id: 'esim-2', status: 'fulfilling', item: 'esim:x'),
          ),
        ),
      ),
      'esim-install' => const EsimPage(
        iccid: '8900000000000000001',
        justBought: true,
      ),
      'esim-gift' => const EsimPage(iccid: '8900000000000000003'),
      'esim-low' => const EsimPage(iccid: '8900000000000000002'),
      'esim-active' => const EsimPage(iccid: '8900000000000000004'),
      'esim-ended' => const EsimPage(iccid: '8900000000000000005'),
      'my-cards' => const CardsShell(initialTab: 1),
      'account' => const CardsShell(initialTab: 2),
      'brand' => BrandPage(brand: _libyana),
      'brand-itunes' => BrandPage(brand: _itunes),
      'topup' || 'topup-saved' => BrandPage(brand: _topUp(0)),
      'topup-zone' => BrandPage(brand: _topUp(1)),
      'topup-server' => BrandPage(brand: _topUp(2)),
      'topup-telegram' => BrandPage(brand: _topUp(3)),
      'topup-steam' => BrandPage(brand: _topUp(4)),
      'topup-gift' => BrandPage(brand: _topUp(5)),
      'topup-checkout' => _SheetHost(
        sheet: CheckoutSheet(
          model: CheckoutModel(
            orders: dependencies.orders,
            brand: _topUp(0),
            item: _topUp(0).items[2],
            account: _typedAccount(dependencies),
          )..load(),
        ),
      ),
      'topup-preparing' => OrderProgressPage(
        brand: _topUp(0),
        openPaymentPage: false,
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(
            fixtureTopUpOrder(id: 'topup-2', status: 'fulfilling'),
          ),
        )..start(),
      ),
      'topup-done' => TopUpDonePage(
        order: CardOrder.fromJson(fixtureTopUpOrder()),
        brand: _topUp(0),
      ),
      // A top-up from «كروتي»: `topup-receipt` arrived; `&order=` any id
      // fixtureTopUpById knows (topup-fulfilling, topup-paid-slow,
      // topup-delivered-reported, topup-delivered-replied, topup-refunded).
      'topup-receipt' => TopUpOrderPage(
        brand: _topUp(0),
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(
            fixtureTopUpById(
              Uri.base.queryParameters['order'] ?? 'topup-delivered',
            ),
          ),
        ),
      ),
      'topup-refunded' => OrderProgressPage(
        brand: _topUp(0),
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(fixtureTopUpOrder(status: 'refunded')),
        ),
      ),
      'topup-board' => const _Board(topUps: true),
      'sign-in' => const _SheetHost(sheet: SignInSheet()),
      'sign-in-code' => _SheetHost(
        sheet: SignInSheet(
          initialChallenge: CodeChallenge(
            phone: '218912345678',
            phoneMasked: '091•••678',
            codeLength: 6,
            expiresAt: null,
            resendAt: DateTime.now().add(const Duration(seconds: 27)),
          ),
        ),
      ),
      'checkout' => _SheetHost(
        sheet: CheckoutSheet(
          model: CheckoutModel(
            orders: dependencies.orders,
            brand: _libyana,
            item: _libyana.items[1],
            quantity: 2,
          )..load(),
        ),
      ),
      'wallet-code' => _SheetHost(
        sheet: CheckoutSheet(
          model:
              CheckoutModel(
                  orders: dependencies.orders,
                  brand: _libyana,
                  item: _libyana.items[1],
                )
                ..load().then((_) => null)
                ..order = CardOrder.fromJson(
                  fixtureOrder(status: 'awaiting_payment', nextAction: 'otp'),
                ),
        ),
      ),
      'preparing' => OrderProgressPage(
        brand: _libyana,
        openPaymentPage: false,
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(fixtureOrder(status: 'fulfilling')),
        ),
      ),
      // Paid four minutes ago and still waiting: the page says to go.
      'preparing-slow' => OrderProgressPage(
        brand: _libyana,
        openPaymentPage: false,
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(
            fixtureOrder(status: 'fulfilling')
              ..['paid_at'] = DateTime.now()
                  .subtract(const Duration(minutes: 4))
                  .toIso8601String(),
          ),
        ),
      ),
      // The shelf, and two seconds later a late card's message drops in.
      'notice' => const CardsShell(),
      'refunded' => OrderProgressPage(
        brand: _libyana,
        watcher: OrderWatcher(
          orders: dependencies.orders,
          vault: dependencies.vault,
          order: CardOrder.fromJson(fixtureOrder(status: 'refunded')),
        ),
      ),
      'reveal' => RevealPage(
        order: CardOrder.fromJson(fixtureOrder()),
        brand: _libyana,
      ),
      'splash' => SplashLab(run: Uri.base.queryParameters['run']),
      'card-pay' => CardPaymentPage(
        order: CardOrder.fromJson(
          fixtureOrder(
            id: 'order-new',
            status: 'awaiting_payment',
            nextAction: 'hosted_page',
          ),
        ),
      ),
      // Dafa's card page over the shelf, as the order opens it: `&url=` a
      // test payment's page (a made-up one shows Dafa's error page).
      'payment-page' => _PaymentPageHost(
        url: Uri.parse(
          Uri.base.queryParameters['url'] ??
              'https://localbankcards.dafa.ly/pay-1',
        ),
      ),
      'about' => const AboutPage(),
      'onboarding' => OnboardingPage(onDone: () {}),
      // The onboarding ending on «من أين سمعت عنا؟»: `onboarding-question`
      // walks there (tap through to see the step into it; `&slow=8` plays
      // it eight times slower), `heard-from` opens on it, `heard-from-link`
      // with a code the app holds from a followed flyer link.
      'onboarding-question' => OnboardingPage(
        askHeardFrom: true,
        onDone: () {},
      ),
      'heard-from' || 'heard-from-link' => OnboardingPage(
        askHeardFrom: true,
        startAsking: true,
        onDone: () {},
      ),
      // The same question in the sign-in sheet, for a new customer.
      'sign-in-heard-from' => const _SheetHost(
        sheet: SignInSheet(askFirst: true),
      ),
      // The credit a campaign gave: `&kind=creator|flyer|billboard|referral|ad`
      // and `&via=code|link` choose the reason.
      'reward' => _RewardHost(
        reward: CampaignReward.fromJson(
          fixtureReward(
            kind: Uri.base.queryParameters['kind'] ?? 'flyer',
            via: Uri.base.queryParameters['via'] ?? 'link',
            name:
                Uri.base.queryParameters['name'] ??
                switch (Uri.base.queryParameters['kind']) {
                  'creator' => 'أحمد',
                  'referral' || 'ad' => '',
                  _ => 'ملصق جامعة مصراتة',
                },
          ),
        ),
      ),
      'privacy' => const LegalPage(document: LegalDocument.privacy),
      'terms' => const LegalPage(document: LegalDocument.terms),
      _ => const CardsShell(),
    };
  }
}

class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.sheet});

  final Widget sheet;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => widget.sheet,
      );
    });
  }

  @override
  Widget build(BuildContext context) => const CardsShell();
}

class _PaymentPageHost extends StatefulWidget {
  const _PaymentPageHost({required this.url});

  final Uri url;

  @override
  State<_PaymentPageHost> createState() => _PaymentPageHostState();
}

class _PaymentPageHostState extends State<_PaymentPageHost> {
  final _settled = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => PaymentPageView.open(
        context,
        url: widget.url,
        changes: _settled,
        settled: () => _settled.value,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const CardsShell();
}

class _RewardHost extends StatefulWidget {
  const _RewardHost({required this.reward});

  final CampaignReward reward;

  @override
  State<_RewardHost> createState() => _RewardHostState();
}

class _RewardHostState extends State<_RewardHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showRewardSheet(context, widget.reward),
    );
  }

  @override
  Widget build(BuildContext context) => const CardsShell();
}

class _Board extends StatelessWidget {
  const _Board({this.topUps = false});

  /// The top-up's own screens instead of the app's main ones.
  final bool topUps;

  @override
  Widget build(BuildContext context) {
    const topUpFrames = <(String, String, bool)>[
      ('حسابات محفوظة', 'topup-saved', false),
      ('معرّف ومنطقة', 'topup-zone', false),
      ('معرّف وخادم', 'topup-server', false),
      ('تيليجرام', 'topup-telegram', false),
      ('ستيم', 'topup-steam', false),
      ('هدية ستيم', 'topup-gift', false),
      ('الدفع', 'topup-checkout', false),
      ('نشحن الحساب', 'topup-preparing', false),
      ('تمّ الشحن', 'topup-done', false),
      ('الإيصال', 'topup-receipt', false),
      ('لم يكتمل', 'topup-refunded', false),
      ('شحن · داكن', 'topup-saved', true),
      ('تمّ الشحن · داكن', 'topup-done', true),
    ];
    const appFrames = <(String, String, bool)>[
      ('الرئيسية', 'home', false),
      ('الكرت', 'brand', false),
      ('الشراء', 'checkout', false),
      ('رمز المحفظة', 'wallet-code', false),
      ('الكرت جاهز', 'reveal', false),
      ('كروتي', 'my-cards', false),
      ('حسابي', 'account', false),
      ('الدخول', 'sign-in-code', false),
      ('الرئيسية · داكن', 'home', true),
      ('الكرت جاهز · داكن', 'reveal', true),
    ];
    final frames = topUps ? topUpFrames : appFrames;
    return Scaffold(
      backgroundColor: const Color(0xFFE9ECEA),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Wrap(
          spacing: 32,
          runSpacing: 32,
          children: [
            for (final (label, screen, dark) in frames)
              _PhoneFrame(
                label: label,
                dark: dark,
                child: PreviewSurface(screen: screen),
              ),
          ],
        ),
      ),
    );
  }
}

/// A 390 × 844 phone with its own navigator, so sheets open inside it.
class _PhoneFrame extends StatelessWidget {
  const _PhoneFrame({
    required this.label,
    required this.child,
    this.dark = false,
  });

  final String label;
  final Widget child;
  final bool dark;

  static const Size size = Size(390, 844);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Container(
          width: size.width,
          height: size.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: const Color(0xFF101828), width: 6),
          ),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              padding: const EdgeInsets.only(top: 44, bottom: 24),
              viewPadding: const EdgeInsets.only(top: 44, bottom: 24),
            ),
            child: Theme(
              data: dark ? CardsTheme.dark() : CardsTheme.light(),
              child: Navigator(
                onGenerateRoute: (_) =>
                    MaterialPageRoute(builder: (_) => child),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// `&duo=1`: the system column the iPhone Duo keeps down its right edge
/// (closed, and open on its side), for a browser sized as that screen:
/// 466 x 678 closed, 951 x 669 open on its side. The real column is the
/// system's: confirm on the simulator.
class _DuoColumn extends StatelessWidget {
  const _DuoColumn({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!on) {
      return child;
    }
    const column = EdgeInsets.only(right: 88);
    final view = MediaQueryData.fromView(View.of(context));
    return MediaQuery(
      data: view.copyWith(padding: column, viewPadding: column),
      child: child,
    );
  }
}

/// The eSIM pages' phone, in a browser that has none.
class _PreviewPhone extends EsimDevice {
  const _PreviewPhone(this.kind);

  final String kind;

  @override
  Future<EsimDeviceFacts> facts() async => EsimDeviceFacts(
    platform: 'ios',
    model: 'iPhone13,2',
    osVersion: '18.0',
    supportsEsim: kind != 'none',
    simulator: false,
    directInstall: kind != 'old',
  );

  @override
  Future<bool> install(String url) async => true;
}
