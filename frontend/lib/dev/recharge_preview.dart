// Dev-only preview harness for the till's top-up flow (POS → شحن اشتراك).
//
// Renders the recharge screen against an in-memory fake repository (no
// backend, no auth), for **both** providers, because they are not the same
// screen: HD Box sells a fixed ladder of months against one card number, and
// LNET sells an open amount of stored value against a line that a phone number
// may match several of. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/recharge_preview.dart
//
// Pick a scenario from the bar across the top, or with `?screen=`:
//
//   HD Box: expired | active | expiring | empty-history | notfound | idle
//   LNET:   lnet-lines | lnet-single | lnet-expired | lnet-low-float |
//           lnet-notfound | lnet-idle
//
// The fixtures are real shapes from the captured sessions — HD Box's 25/65/
// 125/220 ladder, LNET's 5% agency commission and its 518.80 float — so the
// numbers on screen are the numbers a shop would see.
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/integrations_api_client.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/integration_recharge_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

/// A fixed "today" so the expiry arithmetic renders the same on every run.
final DateTime kToday = DateTime(2026, 9, 19);

/// One entry in the switcher: what to call it and what it exercises.
class _Scenario {
  const _Scenario(this.id, this.label, this.provider, {this.search = ''});

  final String id;
  final String label;
  final IntegrationProviderKey provider;

  /// What the harness types into the search box on load. Empty leaves the
  /// screen in its resting state.
  final String search;

}

const _hdBoxCard = '210906803499';
const _lnetPhone = '0910682854';

const List<_Scenario> _kScenarios = [
  // --- HD Box: a ladder of months against one card -----------------------
  _Scenario('expired', 'HD Box · منتهي', IntegrationProviderKey.hdbox,
      search: _hdBoxCard),
  _Scenario('active', 'HD Box · نشط', IntegrationProviderKey.hdbox,
      search: _hdBoxCard),
  _Scenario('expiring', 'HD Box · يوشك', IntegrationProviderKey.hdbox,
      search: _hdBoxCard),
  _Scenario('empty-history', 'HD Box · بلا سجل', IntegrationProviderKey.hdbox,
      search: _hdBoxCard),
  _Scenario('notfound', 'HD Box · غير موجود', IntegrationProviderKey.hdbox,
      search: _hdBoxCard),
  _Scenario('idle', 'HD Box · البداية', IntegrationProviderKey.hdbox),
  // --- LNET: stored value against a line ---------------------------------
  _Scenario('lnet-lines', 'LNET · عدة خطوط', IntegrationProviderKey.lnet,
      search: _lnetPhone),
  _Scenario('lnet-single', 'LNET · خط واحد', IntegrationProviderKey.lnet,
      search: 'alhussainbasheir'),
  _Scenario('lnet-expired', 'LNET · منتهي', IntegrationProviderKey.lnet,
      search: 'basheir.shop'),
  _Scenario('lnet-low-float', 'LNET · رصيد وكالة ضعيف',
      IntegrationProviderKey.lnet,
      search: 'alhussainbasheir'),
  _Scenario('lnet-notfound', 'LNET · غير موجود', IntegrationProviderKey.lnet,
      search: '0910000000'),
  _Scenario('lnet-idle', 'LNET · البداية', IntegrationProviderKey.lnet),
];

_Scenario _scenarioFor(String id) {
  return _kScenarios.firstWhere(
    (s) => s.id == id,
    orElse: () => _kScenarios.first,
  );
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

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
      home: _PreviewHost(initial: _scenarioFor(_screen())),
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
  return parsed?.queryParameters['screen'] ?? 'expired';
}

/// Holds one view model per selection and drives its lookup on load, so the
/// preview opens on the interesting state instead of an empty search box.
class _PreviewHost extends StatefulWidget {
  const _PreviewHost({required this.initial});

  final _Scenario initial;

  @override
  State<_PreviewHost> createState() => _PreviewHostState();
}

class _PreviewHostState extends State<_PreviewHost> {
  late _Scenario _scenario = widget.initial;
  late IntegrationRechargeViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _build();
  }

  void _build() {
    _viewModel = IntegrationRechargeViewModel(
      repository: _FakeRepo(_scenario.id),
      provider: _scenario.provider,
    );
    if (_scenario.search.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewModel.lookup(_scenario.search);
      });
    }
  }

  void _select(_Scenario next) {
    if (next.id == _scenario.id) return;
    setState(() {
      _scenario = next;
      _build();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _ScenarioBar(selected: _scenario, onSelect: _select),
          Expanded(
            // Keyed so switching scenarios rebuilds the screen's own state
            // (the search field, the typed amount) instead of carrying one
            // provider's half-finished sale into the next.
            child: IntegrationRechargeScreen(
              key: ValueKey(_scenario.id),
              viewModel: _viewModel,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScenarioBar extends StatelessWidget {
  const _ScenarioBar({required this.selected, required this.onSelect});

  final _Scenario selected;
  final ValueChanged<_Scenario> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Material(
      color: colors.surfaceSunken,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final scenario in _kScenarios)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      label: Text(scenario.label),
                      selected: scenario.id == selected.id,
                      onSelected: (_) => onSelect(scenario),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

class _FakeRepo extends IntegrationsRepository {
  _FakeRepo(this.scenario) : super(PosApiService());

  final String scenario;

  bool get _isLnet => scenario.startsWith('lnet');

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (scenario == 'notfound' || scenario == 'lnet-notfound') {
      return Error(const IntegrationProviderRefusal('not_found'));
    }
    if (_isLnet) return Ok(_lnetSnapshot(scenario, cardNo));
    return Ok(_hdBoxSnapshot(scenario));
  }

  @override
  Future<Result<IntegrationHistoryPage>> loadHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (scenario == 'empty-history') {
      return Ok(IntegrationHistoryPage(ok: true, kind: kind, limit: limit));
    }
    if (_isLnet) {
      // LNET keeps no state log, so the till never asks for one — if it did,
      // this is the honest answer rather than a fabricated feed.
      if (kind == IntegrationHistoryKind.statuses) {
        return Ok(
          IntegrationHistoryPage(
            ok: false,
            kind: kind,
            errorCode: 'unavailable',
          ),
        );
      }
      return Ok(
        IntegrationHistoryPage(
          ok: true,
          kind: kind,
          total: _lnetPurchases.length,
          limit: limit,
          offset: offset,
          purchases: _lnetPurchases,
        ),
      );
    }
    if (kind == IntegrationHistoryKind.statuses) {
      return Ok(
        IntegrationHistoryPage(
          ok: true,
          kind: kind,
          total: 31,
          limit: limit,
          offset: offset,
          statuses: _statuses,
        ),
      );
    }
    // The real card's own history: four years across five different agencies,
    // only the last of which was this shop.
    return Ok(
      IntegrationHistoryPage(
        ok: true,
        kind: kind,
        total: 6,
        limit: limit,
        offset: offset,
        purchases: offset == 0 ? _purchases : _purchases.reversed.toList(),
      ),
    );
  }
}

// --- HD Box ----------------------------------------------------------------

IntegrationCardSnapshot _hdBoxSnapshot(String scenario) {
  final expiry = switch (scenario) {
    'active' => kToday.add(const Duration(days: 214)),
    'expiring' => kToday.add(const Duration(days: 9)),
    _ => DateTime(2026, 8, 1),
  };
  final statusId = switch (scenario) {
    'active' || 'expiring' => 3,
    _ => 6,
  };
  return IntegrationCardSnapshot(
    card: IntegrationCardInfo(
      cardNo: _hdBoxCard,
      status: statusId == 6 ? 'On hold' : 'Active',
      statusId: statusId,
      startAt: DateTime(2022, 11, 27),
      expireAt: expiry,
      packageName: 'HDBOX Full package',
    ),
    offers: const [
      // HD Box's real ladder: cost 25/65/125/220, sold at its recommended
      // 30/80/140/240. Durations only — package switches are not offered.
      IntegrationOffer(
        code: 'renew:1',
        kind: 'renew',
        label: '1 month 25.00\$',
        cost: 25,
        price: 30,
        months: 1,
      ),
      IntegrationOffer(
        code: 'renew:3',
        kind: 'renew',
        label: '3 month 65.00\$',
        cost: 65,
        price: 80,
        months: 3,
      ),
      IntegrationOffer(
        code: 'renew:6',
        kind: 'renew',
        label: '6 month 125.00\$',
        cost: 125,
        price: 140,
        months: 6,
      ),
      IntegrationOffer(
        code: 'renew:12',
        kind: 'renew',
        label: '12 month 220.00\$',
        cost: 220,
        price: 245,
        months: 12,
      ),
    ],
    serviceVariant: const IntegrationServiceVariant(
      id: 9001,
      productId: 4001,
      sku: 'INTEG-HDBOX',
      name: 'شحن اشتراك HD Box',
    ),
    balance: 25,
  );
}

// --- LNET ------------------------------------------------------------------

/// The 5% agency commission the shop confirmed, as the backend quotes it: the
/// float pays 0.95 per dinar of face value, and face value is the retail floor.
const _lnetOpenAmount = IntegrationOpenAmount(
  minimum: 1,
  step: 1,
  costRatio: 0.95,
  pricePerUnit: 0.95,
);

const _lnetOffers = [
  IntegrationOffer(
      code: 'topup:10',
      kind: 'topup',
      label: '10 LYD',
      cost: 9.5,
      price: 10,
      faceValue: 10),
  IntegrationOffer(
      code: 'topup:20',
      kind: 'topup',
      label: '20 LYD',
      cost: 19,
      price: 20,
      faceValue: 20),
  IntegrationOffer(
      code: 'topup:25',
      kind: 'topup',
      label: '25 LYD',
      cost: 23.75,
      price: 25,
      faceValue: 25),
  IntegrationOffer(
      code: 'topup:30',
      kind: 'topup',
      label: '30 LYD',
      cost: 28.5,
      price: 30,
      faceValue: 30),
  IntegrationOffer(
      code: 'topup:40',
      kind: 'topup',
      label: '40 LYD',
      cost: 38,
      price: 40,
      faceValue: 40),
  IntegrationOffer(
      code: 'topup:45',
      kind: 'topup',
      label: '45 LYD',
      cost: 42.75,
      price: 45,
      faceValue: 45),
  IntegrationOffer(
      code: 'topup:50',
      kind: 'topup',
      label: '50 LYD',
      cost: 47.5,
      price: 50,
      faceValue: 50),
  IntegrationOffer(
      code: 'topup:100',
      kind: 'topup',
      label: '100 LYD',
      cost: 95,
      price: 100,
      faceValue: 100),
];

const _lnetVariant = IntegrationServiceVariant(
  id: 9002,
  productId: 4002,
  sku: 'INTEG-LNET',
  name: 'شحن اشتراك LNET',
);

IntegrationCardSnapshot _lnetSnapshot(String scenario, String searched) {
  // A phone number matches every line on it; a username matches only its own.
  // This is the whole reason the picker exists.
  final isPhone = !searched.contains('.') && !searched.contains('hussain');
  if (scenario == 'lnet-lines' && isPhone) {
    return IntegrationCardSnapshot(
      card: const IntegrationCardInfo(cardNo: ''),
      offers: const [],
      serviceVariant: _lnetVariant,
      needsSelection: true,
      historyKinds: const ['purchases'],
      balance: 518.80,
      candidates: [
        IntegrationCardInfo(
          cardNo: 'alhussainbasheir',
          providerId: '214737',
          status: 'Active',
          startAt: DateTime(2026, 8, 24),
          expireAt: DateTime(2026, 9, 23),
          packageName: 'Unlimited Home Basic',
          cardBalance: 12.5,
        ),
        IntegrationCardInfo(
          cardNo: 'basheir.shop',
          providerId: '214740',
          status: 'Expired',
          startAt: DateTime(2026, 1, 2),
          expireAt: DateTime(2026, 2, 2),
          packageName: 'Unlimited Home Basic Plus',
        ),
        IntegrationCardInfo(
          cardNo: 'basheir.old',
          providerId: '214741',
          status: 'Suspended',
          startAt: DateTime(2025, 1, 2),
          expireAt: DateTime(2025, 2, 2),
          packageName: 'WIFI-Home Basic',
        ),
      ],
    );
  }

  final expired = scenario == 'lnet-expired' || searched == 'basheir.shop';
  return IntegrationCardSnapshot(
    card: IntegrationCardInfo(
      cardNo: expired ? 'basheir.shop' : 'alhussainbasheir',
      providerId: expired ? '214740' : '214737',
      status: expired ? 'Expired' : 'Active',
      startAt: expired ? DateTime(2026, 1, 2) : DateTime(2026, 8, 24),
      expireAt: expired ? DateTime(2026, 2, 2) : DateTime(2026, 9, 23),
      packageName:
          expired ? 'Unlimited Home Basic Plus' : 'Unlimited Home Basic',
      cardBalance: expired ? 0 : 12.5,
    ),
    offers: _lnetOffers,
    openAmount: _lnetOpenAmount,
    serviceVariant: _lnetVariant,
    // No status log: the portal keeps none an agency can read.
    historyKinds: const ['purchases'],
    // Low enough that 45 (costing the float 42.75) trips the warning.
    balance: scenario == 'lnet-low-float' ? 30.20 : 518.80,
  );
}

/// Straight off the captured payments report: face value against what the
/// float actually paid for it.
final _lnetPurchases = [
  IntegrationPurchaseEntry(
    reference: '4300578',
    cost: 23.75,
    at: DateTime(2026, 9, 20, 16, 38),
    operatorName: 'lnet_r67',
    isOurs: true,
  ),
  IntegrationPurchaseEntry(
    reference: '4299905',
    cost: 42.75,
    at: DateTime(2026, 9, 19, 23, 43),
    operatorName: 'lnet_r67',
    isOurs: true,
  ),
  IntegrationPurchaseEntry(
    reference: '4299824',
    cost: 38,
    at: DateTime(2026, 9, 19, 21, 25),
    operatorName: 'lnet_r67',
    isOurs: true,
  ),
];

final _purchases = [
  IntegrationPurchaseEntry(
    reference: '523415',
    cost: 25,
    months: 1,
    at: DateTime(2026, 6, 30),
    packageName: 'HDBOX Full package',
    operatorName: 'Alnassim',
    isOurs: true,
  ),
  IntegrationPurchaseEntry(
    reference: '484140',
    cost: 65,
    months: 3,
    at: DateTime(2026, 3, 31),
    packageName: 'HDBOX Full package',
    operatorName: 'zhra',
  ),
  IntegrationPurchaseEntry(
    reference: '376198',
    cost: 220,
    months: 12,
    at: DateTime(2025, 3, 29),
    packageName: 'HDBOX Full package',
    operatorName: 'zhra',
  ),
  IntegrationPurchaseEntry(
    reference: '266230',
    cost: 210,
    months: 12,
    at: DateTime(2024, 3, 21),
    packageName: 'HDBOX Full package',
    operatorName: 'hmeda',
  ),
];

final _statuses = [
  IntegrationStatusEntry(
    fromStatus: 'Soon to expire',
    toStatus: 'On hold',
    operatorName: 'System',
    action: 'Auto operation by system timer.',
    at: DateTime(2026, 8, 1),
  ),
  IntegrationStatusEntry(
    fromStatus: 'Active',
    toStatus: 'Soon to expire',
    operatorName: 'System',
    action: 'Auto operation by system timer.',
    at: DateTime(2026, 7, 27),
  ),
  IntegrationStatusEntry(
    fromStatus: 'Soon to expire',
    toStatus: 'Active',
    operatorName: 'Alnassim',
    action: 'Renew card',
    at: DateTime(2026, 6, 30),
  ),
];
