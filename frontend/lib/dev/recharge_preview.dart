// Dev-only preview harness for the till's top-up flow (POS → شحن اشتراك).
//
// Renders the recharge screen against an in-memory fake repository (no
// backend, no auth). Pick the scenario with a `?screen=` query param and
// resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/recharge_preview.dart
//
// Scenarios: expired | active | expiring | empty-history | notfound | idle
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

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final screen = _screen();
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
      home: _PreviewHost(scenario: screen),
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

/// Drives the lookup on load so the preview opens on the interesting state
/// instead of an empty search box — except for `idle`, which is that state.
class _PreviewHost extends StatefulWidget {
  const _PreviewHost({required this.scenario});

  final String scenario;

  @override
  State<_PreviewHost> createState() => _PreviewHostState();
}

class _PreviewHostState extends State<_PreviewHost> {
  late final IntegrationRechargeViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = IntegrationRechargeViewModel(
      repository: _FakeRepo(widget.scenario),
      provider: IntegrationProviderKey.hdbox,
    );
    if (widget.scenario != 'idle') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewModel.lookup('210906803499');
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      IntegrationRechargeScreen(viewModel: _viewModel);
}

class _FakeRepo extends IntegrationsRepository {
  _FakeRepo(this.scenario) : super(PosApiService());

  final String scenario;

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (scenario == 'notfound') {
      return Error(const IntegrationProviderRefusal('not_found'));
    }
    return Ok(_snapshot(scenario));
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

IntegrationCardSnapshot _snapshot(String scenario) {
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
      cardNo: '210906803499',
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
