// Dev-only preview harness for «دفتر كروت» (safe to delete): a separate web
// entrypoint, never imported by lib/main.dart, so it does not ship.
//
//   make cards-preview, then ?screen=board | home | brand | brand-itunes |
//   sign-in | sign-in-code | checkout | wallet-code | preparing | refunded |
//   reveal | my-cards | account | signed-out | splash ; add &theme=dark for dark
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
import 'package:flutter/material.dart';

import '../src/app.dart';
import '../src/data/models/catalog.dart';
import '../src/data/models/customer.dart';
import '../src/data/models/order.dart';
import '../src/design/cards_theme.dart';
import '../src/features/brand/brand_page.dart';
import '../src/features/card_payment/card_payment_page.dart';
import '../src/features/checkout/checkout_model.dart';
import '../src/features/checkout/checkout_sheet.dart';
import '../src/features/legal/about_page.dart';
import '../src/features/legal/legal_document.dart';
import '../src/features/legal/legal_page.dart';
import '../src/features/orders/order_progress_page.dart';
import '../src/features/orders/order_watcher.dart';
import '../src/features/reveal/reveal_page.dart';
import '../src/features/shell/cards_shell.dart';
import '../src/features/sign_in/sign_in_sheet.dart';
import '../src/shared/cards_scope.dart';
import 'cards_fixtures.dart';
import 'preview_scenarios.dart';
import 'scenario_chip.dart';
import 'splash_lab.dart';

void main() {
  final query = Uri.base.queryParameters;
  final screen = query['screen'] ?? 'board';
  final dark = query['theme'] == 'dark';
  const shelfRelay = String.fromEnvironment('CARDS_PREVIEW_RELAY');
  // The whole app plays scripted purchases: each one ends the next way.
  final scenarios = screen == 'home' ? PreviewScenarios() : null;
  final dependencies = fixtureDependencies(
    signedIn: screen != 'signed-out' && !screen.startsWith('sign-in'),
    shelfRelay: shelfRelay.isEmpty ? null : Uri.parse(shelfRelay),
    scenarios: scenarios,
    // The card form's Moamalat: `&card=verify` has the bank ask for its
    // code, `&card=decline` refuses the card.
    moamalat: FakeMoamalatClient(
      verify: query['card'] == 'verify',
      decline: query['card'] == 'decline',
    ),
  );
  dependencies.settings.setLanguage(query['lang'] ?? 'ar');
  runApp(
    CardsApp(
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
  );
}

final CardBrand _libyana = CardBrand.fromJson(
  (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
);
final CardBrand _itunes = CardBrand.fromJson(
  (fixtureCatalog['brands'] as List)[4] as Map<String, dynamic>,
);

/// One screen or sheet by name; sheets open over a blank page on load.
class PreviewSurface extends StatelessWidget {
  const PreviewSurface({super.key, required this.screen});

  final String screen;

  @override
  Widget build(BuildContext context) {
    final dependencies = CardsScope.of(context);
    return switch (screen) {
      'home' || 'signed-out' => const CardsShell(),
      'my-cards' => const CardsShell(initialTab: 1),
      'account' => const CardsShell(initialTab: 2),
      'brand' => BrandPage(brand: _libyana),
      'brand-itunes' => BrandPage(brand: _itunes),
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
      'about' => const AboutPage(),
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

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    const frames = <(String, String, bool)>[
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
