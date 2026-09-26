import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_query.dart';
import 'package:pointy_frontend/src/features/learning/view_models/learning_view_model.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/command_palette/command_palette.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../fake_app_navigation.dart';

/// الخزينة opens the money position, which the server serves only on
/// treasury.view_moneyaccount. The entry was gated on payments.view_payment,
/// which every cashier holds for the till — so a cashier was offered the
/// screen and then refused it (403 on /api/treasury/position/, field export
/// 2026-09-25). The drawer, the rail, the command palette, deep links and the
/// learning guides all ask the same question; these tests ask it for them.
void main() {
  const treasury = AppNavigationDestination.payments;
  final l10n = lookupAppLocalizations(const Locale('ar'));

  group('the الخزينة destination', () {
    test('is not offered to a cashier, who takes payments all day', () {
      final navigation = FakeAppNavigation(currentUser: _cashier());

      // The cashier does hold the payments permission — it is just not the
      // one the screen reads.
      expect(navigation.capabilities.canViewPayments, isTrue);
      expect(navigation.isDestinationAvailable(treasury), isFalse);
    });

    test('is offered to a manager', () {
      final navigation = FakeAppNavigation(currentUser: _manager);

      expect(navigation.isDestinationAvailable(treasury), isTrue);
    });

    test('opens for a cashier the owner grants «عرض الخزينة»', () {
      final navigation = FakeAppNavigation(
        currentUser: _cashier(extra: const {'treasury.view_moneyaccount'}),
      );

      expect(navigation.isDestinationAvailable(treasury), isTrue);
    });
  });

  testWidgets('a cashier\'s drawer has no الخزينة', (tester) async {
    await _pumpDrawer(tester, _cashier());

    expect(find.text(l10n.posDrawerLabel), findsOneWidget);
    expect(find.text(l10n.paymentsHubDrawerLabel), findsNothing);
  });

  testWidgets('a manager\'s drawer keeps it', (tester) async {
    await _pumpDrawer(tester, _manager);

    expect(find.text(l10n.paymentsHubDrawerLabel), findsOneWidget);
  });

  testWidgets('the command palette finds it for a manager only', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SizedBox.shrink()));
    final context = tester.element(find.byType(SizedBox));

    List<String> screens(PosUser user, String query) => [
      for (final item in NavigationCommandSource(
        FakeAppNavigation(currentUser: user),
      ).filter(context, query))
        item.id,
    ];

    expect(screens(_cashier(), ''), isNot(contains('screen-payments')));
    expect(screens(_cashier(), 'خزينة'), isNot(contains('screen-payments')));
    expect(screens(_manager, ''), contains('screen-payments'));
    expect(screens(_manager, 'خزينة'), contains('screen-payments'));
  });

  group('the learning guides', () {
    /// The guides «ما تسمح به صلاحياتي» offers [navigation]'s user.
    List<LearningGuide> matching(AppNavigation navigation) {
      final viewModel =
          LearningViewModel(
              capabilities: navigation.capabilities,
              userId: navigation.currentUser.id,
            )
            ..initialize()
            ..setQuery(
              const LearningQuery(
                audience: LearningAudienceFilter.myPermissions,
              ),
            );
      return viewModel.results;
    }

    Set<String> ids(List<LearningGuide> guides) => {
      for (final guide in guides) guide.id,
    };

    test('about الخزينة match a manager and not a cashier', () {
      const treasuryGuides = ['money.treasury', 'money.payments_hub'];
      final manager = ids(matching(FakeAppNavigation(currentUser: _manager)));
      final cashier = ids(matching(FakeAppNavigation(currentUser: _cashier())));

      expect(manager, containsAll(treasuryGuides));
      for (final id in treasuryGuides) {
        expect(cashier, isNot(contains(id)));
      }
    });

    test('matched to a cashier never open a screen they cannot reach', () {
      final navigation = FakeAppNavigation(currentUser: _cashier());

      final deadEnds = [
        for (final guide in matching(navigation))
          if (guide.opens case final opens?)
            if (!navigation.isDestinationAvailable(opens))
              '${guide.id} -> ${opens.name}',
      ];
      expect(deadEnds, isEmpty);
    });
  });
}

Future<void> _pumpDrawer(WidgetTester tester, PosUser user) async {
  // Tall enough that the drawer's lazy list builds every destination.
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    _app(
      Scaffold(
        drawer: AppNavigationDrawer(
          selectedDestination: AppNavigationDestination.pos,
          navigation: FakeAppNavigation(currentUser: user),
        ),
        body: const SizedBox.shrink(),
      ),
    ),
  );
  tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
  await tester.pumpAndSettle();
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: PointyTheme.light(),
    home: home,
  );
}

/// A cashier as backend/apps/core/roles.py bundles the role
/// (CASHIER_PERMISSION_CODES), plus any per-user [extra] grants. A snapshot,
/// not a source of truth: when the role changes there, change it here too.
PosUser _cashier({Set<String> extra = const {}}) {
  return PosUser(
    id: 7,
    username: 'cashier',
    role: UserRole.cashier,
    isActive: true,
    permissions: {..._cashierPermissions, ...extra},
  );
}

const _manager = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

const _cashierPermissions = <String>{
  'integrations.use_integrations',
  'catalog.view_product',
  'catalog.view_productcategory',
  'catalog.view_productvariant',
  'catalog.view_unitofmeasure',
  'catalog.view_scalebarcoderule',
  'inventory.view_stockcount',
  'inventory.add_stockcount',
  'inventory.change_stockcount',
  'inventory.view_stockunit',
  'inventory.view_stockbatch',
  'inventory.view_consignmentagreement',
  'inventory.view_consignment_liability',
  'inventory.disburse_consignment_payout',
  'sales.add_order',
  'sales.view_order',
  'sales.add_registersession',
  'sales.change_registersession',
  'sales.view_registersession',
  'sales.add_registercashmovement',
  'sales.view_registercashmovement',
  'payments.add_payment',
  'payments.view_payment',
  'core.view_shopsettings',
  'printing.add_printjob',
  'printing.change_printjob',
  'printing.view_printjob',
  'printing.view_printjobevent',
  'printing.add_printauditevent',
  'printing.change_printauditevent',
  'printing.view_printauditevent',
  'analytics.add_analyticsevent',
  'operations.add_job',
  'operations.change_job',
  'operations.view_job',
  'operations.assign_job',
  'operations.add_jobasset',
  'operations.view_jobasset',
  'operations.add_jobmaterial',
  'operations.view_jobmaterial',
  'operations.view_jobstageevent',
  'operations.view_workflowtemplate',
  'operations.view_workflowstage',
  'customers.add_asset',
  'customers.change_asset',
  'customers.view_asset',
  'crm.view_conversations',
  'crm.manage_conversations',
};
