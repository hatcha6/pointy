import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/fx_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/repositories/migration_repository.dart';
import 'package:pointy_frontend/src/data/repositories/modifier_group_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/prep_station_repository.dart';
import 'package:pointy_frontend/src/data/repositories/price_checker_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sales_channel_repository.dart';
import 'package:pointy_frontend/src/data/repositories/scales_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/subscription_repository.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/repositories/warehouse_repository.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_settings_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/transfers_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/transfers_screen.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/asset_types_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/workflows_view_model.dart';
import 'package:pointy_frontend/src/features/scales/view_models/scales_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/exchange_rates_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/factory_reset_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/modifier_groups_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/prep_stations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/price_checkers_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/sales_channels_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/subscription_status_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/warehouses_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/shop_settings_screen.dart';
import 'package:pointy_frontend/src/features/settings/views/warehouses_page.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/command_palette/command_palette.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../../../shared/fake_app_navigation.dart';
import '../../../shared/role_fixtures.dart';

/// Warehouses and transfers answer to their own permissions.
///
/// Both settings tiles used to borrow the sales-channel right. Someone given
/// channels and no stock rights opened pages whose every call came back
/// refused. Someone given the warehouse group from the permission editor
/// never saw the pages at all. Inside them, each button follows the one
/// permission the server checks for it, so nobody is offered a press that
/// will be refused.
void main() {
  group('shop settings tiles', () {
    testWidgets('the sales-channel right no longer brings the stock tiles', (
      tester,
    ) async {
      await _pumpSettings(tester, _staffWith({'channels.change_saleschannel'}));

      expect(_tile(_salesChannelsTitle), findsOneWidget);
      expect(_tile(_warehousesTitle), findsNothing);
      expect(_tile(_transfersTitle), findsNothing);
    });

    testWidgets('viewing places opens the warehouses tile and no other', (
      tester,
    ) async {
      await _pumpSettings(tester, _staffWith({'inventory.view_warehouse'}));

      expect(_tile(_warehousesTitle), findsOneWidget);
      expect(_tile(_transfersTitle), findsNothing);
      expect(_tile(_salesChannelsTitle), findsNothing);
    });

    testWidgets('viewing transfers opens the transfers tile and no other', (
      tester,
    ) async {
      await _pumpSettings(tester, _staffWith({'inventory.view_stocktransfer'}));

      expect(_tile(_transfersTitle), findsOneWidget);
      expect(_tile(_warehousesTitle), findsNothing);
      expect(_tile(_salesChannelsTitle), findsNothing);
    });

    testWidgets('a write right alone opens no page to use it on', (
      tester,
    ) async {
      // The lists are what the pages show, and the server answers them only
      // for the view rights.
      await _pumpSettings(
        tester,
        _staffWith({
          'inventory.add_warehouse',
          'inventory.change_warehouse',
          'inventory.dispatch_stocktransfer',
          'inventory.receive_stocktransfer',
        }),
      );

      expect(_tile(_warehousesTitle), findsNothing);
      expect(_tile(_transfersTitle), findsNothing);
    });

    testWidgets('a manager still sees all three', (tester) async {
      await _pumpSettings(tester, _manager);

      expect(_tile(_salesChannelsTitle), findsOneWidget);
      expect(_tile(_warehousesTitle), findsOneWidget);
      expect(_tile(_transfersTitle), findsOneWidget);
    });

    testWidgets('the pages opened from the tiles keep the same rights', (
      tester,
    ) async {
      await _pumpSettings(
        tester,
        _staffWith({
          'inventory.view_warehouse',
          'inventory.view_stocktransfer',
        }),
      );

      await tester.tap(_tile(_warehousesTitle));
      await tester.pumpAndSettle();
      expect(find.text('المخزن'), findsOneWidget);
      expect(find.byTooltip('إضافة مكان'), findsNothing);
      expect(find.byTooltip('تعديل'), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(_tile(_transfersTitle));
      await tester.pumpAndSettle();
      expect(find.text('TR-0007'), findsOneWidget);
      expect(find.text('استلام'), findsNothing);
      expect(find.text('تحويل جديد'), findsNothing);
    });
  });

  group('warehouses page', () {
    // Each button, keyed by the permission the server checks when it is
    // pressed.
    final buttons = <String, Finder Function()>{
      'inventory.add_warehouse': () => find.byTooltip('إضافة مكان'),
      'inventory.change_warehouse': () => find.byTooltip('تعديل'),
      'inventory.delete_warehouse': () => find.byTooltip('حذف'),
      'sales.change_registerprofile': () => find.text('تغيير المكان'),
    };

    testWidgets('looking at the places offers no change to them', (
      tester,
    ) async {
      await _pumpWarehouses(tester, _staffWith({'inventory.view_warehouse'}));

      expect(find.text('المخزن'), findsOneWidget);
      // Where this till sells from is still said; only the change is gone.
      expect(
        find.text('المبيعات تُخصم من رصيد هذا المكان، والجرد والتقارير تتبعه.'),
        findsOneWidget,
      );
      for (final MapEntry(key: code, value: button) in buttons.entries) {
        expect(button(), findsNothing, reason: code);
      }
    });

    for (final code in buttons.keys) {
      testWidgets('$code brings back its own button and no other', (
        tester,
      ) async {
        await _pumpWarehouses(
          tester,
          _staffWith({'inventory.view_warehouse', code}),
        );

        for (final MapEntry(key: other, value: button) in buttons.entries) {
          expect(
            button(),
            other == code ? findsWidgets : findsNothing,
            reason: other,
          );
        }
      });
    }

    testWidgets('a manager has every button', (tester) async {
      await _pumpWarehouses(tester, _manager);

      for (final MapEntry(key: code, value: button) in buttons.entries) {
        expect(button(), findsWidgets, reason: code);
      }
    });

    testWidgets('one place and no right to add: the fact, not the advice', (
      tester,
    ) async {
      await _pumpWarehouses(
        tester,
        _staffWith({'inventory.view_warehouse'}),
        places: const [_shopFloor],
      );

      expect(find.text('لديك مكان واحد'), findsOneWidget);
      expect(find.text('كل المخزون في المعرض.'), findsOneWidget);
      expect(find.text('إضافة مكان'), findsNothing);
    });

    testWidgets('one place and the right to add: the offer stays', (
      tester,
    ) async {
      await _pumpWarehouses(
        tester,
        _staffWith({'inventory.view_warehouse', 'inventory.add_warehouse'}),
        places: const [_shopFloor],
      );

      expect(find.text('كل المخزون في المعرض.'), findsNothing);
      // The callout's own offer, beside the one in the app bar.
      expect(find.text('إضافة مكان'), findsOneWidget);
      expect(find.byTooltip('إضافة مكان'), findsOneWidget);
    });
  });

  group('transfers screen', () {
    testWidgets('looking at transfers offers nothing to do to them', (
      tester,
    ) async {
      await _pumpTransfers(tester, _viewerWith(const {}));

      expect(find.text('TR-0007'), findsOneWidget);
      expect(find.text('TR-0008'), findsOneWidget);
      expect(find.text('تحويل جديد'), findsNothing);
      expect(find.text('إرسال'), findsNothing);
      expect(find.text('إلغاء التحويل'), findsNothing);
      expect(find.text('استلام'), findsNothing);
    });

    testWidgets('the receiving end can receive and do nothing else', (
      tester,
    ) async {
      await _pumpTransfers(
        tester,
        _viewerWith({'inventory.receive_stocktransfer'}),
      );

      expect(find.text('استلام'), findsOneWidget);
      expect(find.text('إرسال'), findsNothing);
      expect(find.text('إلغاء التحويل'), findsNothing);
      expect(find.text('تحويل جديد'), findsNothing);
    });

    testWidgets('the sending end can send and cancel, not receive', (
      tester,
    ) async {
      // The server checks the sending right for a cancel too: undoing a
      // dispatch moves the same goods back.
      await _pumpTransfers(
        tester,
        _viewerWith({'inventory.dispatch_stocktransfer'}),
      );

      expect(find.text('إرسال'), findsOneWidget);
      expect(find.text('إلغاء التحويل'), findsOneWidget);
      expect(find.text('استلام'), findsNothing);
      expect(find.text('تحويل جديد'), findsNothing);
    });

    testWidgets('writing without the right to send saves drafts only', (
      tester,
    ) async {
      await _pumpTransfers(
        tester,
        _viewerWith({
          'inventory.add_stocktransfer',
          'inventory.view_stockitem',
        }),
      );
      expect(find.text('إرسال'), findsNothing);

      await tester.tap(find.text('تحويل جديد'));
      await tester.pumpAndSettle();

      expect(find.text('إرسال الآن'), findsNothing);
      // The only way out of the sheet, so it is the filled button.
      expect(find.widgetWithText(FilledButton, 'حفظ كمسودة'), findsOneWidget);
    });

    testWidgets('writing needs the stock the composer picks from', (
      tester,
    ) async {
      await _pumpTransfers(
        tester,
        _viewerWith({'inventory.add_stocktransfer'}),
      );

      expect(find.text('تحويل جديد'), findsNothing);
    });

    testWidgets('a manager can do all of it and send straight away', (
      tester,
    ) async {
      await _pumpTransfers(tester, _manager);

      expect(find.text('استلام'), findsOneWidget);
      expect(find.text('إرسال'), findsOneWidget);
      expect(find.text('إلغاء التحويل'), findsOneWidget);

      await tester.tap(find.text('تحويل جديد'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'إرسال الآن'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'حفظ كمسودة'), findsOneWidget);
    });
  });

  group('the way in without shop settings', () {
    // Every stock role holds the two view rights and none holds
    // core.change_shopsettings, and a settings tile was the only door to
    // either page — so they were granted two screens they could not reach.
    final stockRoles = <String, PosUser>{
      'purchasing agent': userWithRole(
        UserRole.purchasingAgent,
        purchasingAgentPermissions,
      ),
      'auditor': userWithRole(UserRole.auditor, auditorPermissions),
      'accountant': userWithRole(UserRole.accountant, accountantPermissions),
    };

    for (final MapEntry(key: role, value: user) in stockRoles.entries) {
      test('the $role reaches both pages and not shop settings', () {
        final navigation = FakeAppNavigation(currentUser: user);

        expect(navigation.capabilities.canManageShopSettings, isFalse);
        expect(navigation.isDestinationAvailable(_warehousesScreen), isTrue);
        expect(navigation.isDestinationAvailable(_transfersScreen), isTrue);
      });
    }

    test('each view right opens its own destination and no other', () {
      final places = FakeAppNavigation(
        currentUser: _clerkWith({'inventory.view_warehouse'}),
      );
      final transfers = FakeAppNavigation(
        currentUser: _clerkWith({'inventory.view_stocktransfer'}),
      );

      expect(places.isDestinationAvailable(_warehousesScreen), isTrue);
      expect(places.isDestinationAvailable(_transfersScreen), isFalse);
      expect(transfers.isDestinationAvailable(_transfersScreen), isTrue);
      expect(transfers.isDestinationAvailable(_warehousesScreen), isFalse);
    });

    test('a write right alone opens no destination to use it on', () {
      final navigation = FakeAppNavigation(
        currentUser: _clerkWith({
          'inventory.add_warehouse',
          'inventory.change_warehouse',
          'inventory.delete_warehouse',
          'sales.change_registerprofile',
          'inventory.add_stocktransfer',
          'inventory.view_stockitem',
          'inventory.dispatch_stocktransfer',
          'inventory.receive_stocktransfer',
        }),
      );

      expect(navigation.isDestinationAvailable(_warehousesScreen), isFalse);
      expect(navigation.isDestinationAvailable(_transfersScreen), isFalse);
    });

    testWidgets('a stock role finds both in the drawer, under stock', (
      tester,
    ) async {
      await _pumpDrawer(tester, stockRoles['auditor']!);

      expect(find.text('المخزون والمشتريات'), findsOneWidget);
      expect(find.text('المخازن'), findsOneWidget);
      expect(find.text('تحويلات البضاعة'), findsOneWidget);
      expect(find.text('إعدادات المتجر'), findsNothing);
    });

    testWidgets('a cashier finds neither', (tester) async {
      await _pumpDrawer(tester, _cashier);

      expect(find.text('شاشة البيع'), findsOneWidget);
      expect(find.text('المخازن'), findsNothing);
      expect(find.text('تحويلات البضاعة'), findsNothing);
    });

    testWidgets('⌘K finds them by the words people type', (tester) async {
      await tester.pumpWidget(_app(const SizedBox.shrink()));
      final context = tester.element(find.byType(SizedBox));

      List<String> screens(PosUser user, String query) => [
        for (final item in NavigationCommandSource(
          FakeAppNavigation(currentUser: user),
        ).filter(context, query))
          item.id,
      ];

      final auditor = stockRoles['auditor']!;
      expect(screens(auditor, 'مخزن'), contains('screen-warehouses'));
      expect(screens(auditor, 'warehouse'), contains('screen-warehouses'));
      expect(screens(auditor, 'تحويل'), contains('screen-stockTransfers'));
      expect(screens(auditor, 'transfer'), contains('screen-stockTransfers'));
      expect(
        screens(_cashier, ''),
        isNot(
          anyOf(
            contains('screen-warehouses'),
            contains('screen-stockTransfers'),
          ),
        ),
      );
    });
  });

  group('opened as a destination', () {
    testWidgets('the warehouses page draws the navigation, not a back '
        'button, and still offers no change it would refuse', (tester) async {
      // Narrow enough for a drawer, tall enough that its lazy list builds the
      // stock group.
      await tester.binding.setSurfaceSize(const Size(800, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auditor = userWithRole(UserRole.auditor, auditorPermissions);
      final opened = <AppNavigationDestination>[];
      await _pumpWarehouses(
        tester,
        auditor,
        navigation: FakeAppNavigation(
          currentUser: auditor,
          onNavigate: opened.add,
        ),
      );

      expect(find.byType(PointyNavigationMenuButton), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('المخزن'), findsOneWidget);
      expect(find.byTooltip('إضافة مكان'), findsNothing);
      expect(find.byTooltip('تعديل'), findsNothing);
      expect(find.text('تغيير المكان'), findsNothing);

      // One tap on to the transfers between these places.
      await tester.tap(find.byTooltip('فتح القائمة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تحويلات البضاعة'));
      await tester.pumpAndSettle();
      expect(opened, [_transfersScreen]);
    });

    testWidgets('the transfers screen draws the navigation and keeps each '
        'button on its own right', (tester) async {
      final user = _clerkWith({
        'inventory.view_stocktransfer',
        'inventory.view_warehouse',
        'inventory.receive_stocktransfer',
      });
      await _pumpTransfers(
        tester,
        user,
        navigation: FakeAppNavigation(currentUser: user),
      );

      expect(find.byType(PointyNavigationMenuButton), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('TR-0007'), findsOneWidget);
      expect(find.text('استلام'), findsOneWidget);
      expect(find.text('إرسال'), findsNothing);
      expect(find.text('تحويل جديد'), findsNothing);
    });

    testWidgets('on a wide screen the rail stands in for the drawer', (
      tester,
    ) async {
      // The breakpoint reads the view's size, not the test surface's.
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auditor = userWithRole(UserRole.auditor, auditorPermissions);
      await _pumpWarehouses(
        tester,
        auditor,
        navigation: FakeAppNavigation(currentUser: auditor),
      );

      expect(find.byType(PointyNavigationRailSurface), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    });
  });
}

const _warehousesScreen = AppNavigationDestination.warehouses;
const _transfersScreen = AppNavigationDestination.stockTransfers;

/// An inventory clerk holding only [permissions] — the role's view rights
/// left out, so each test says exactly which ones it is about.
PosUser _clerkWith(Set<String> permissions) =>
    userWithRole(UserRole.inventoryClerk, permissions);

/// A cashier as the till knows one: no stock rights of any kind.
final _cashier = userWithRole(UserRole.cashier, const {
  'sales.add_order',
  'sales.view_order',
  'payments.add_payment',
  'core.view_shopsettings',
});

const _salesChannelsTitle = 'قنوات البيع';
const _warehousesTitle = 'المخازن والأماكن';
const _transfersTitle = 'تحويل بضاعة';

Finder _tile(String title) => find.widgetWithText(PointySettingsTile, title);

const _manager = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

/// A cashier who may open shop settings, plus whatever [extra] the owner
/// ticked in the permission editor.
PosUser _staffWith(Set<String> extra) => PosUser(
  id: 2,
  username: 'staff',
  role: UserRole.cashier,
  isActive: true,
  permissions: {'core.change_shopsettings', ...extra},
);

/// Somebody who can see the transfers and the places they run between, as
/// every stock role can, plus [extra].
PosUser _viewerWith(Set<String> extra) => PosUser(
  id: 3,
  username: 'store',
  role: UserRole.inventoryClerk,
  isActive: true,
  permissions: {
    'inventory.view_stocktransfer',
    'inventory.view_warehouse',
    ...extra,
  },
);

const _shopFloor = <String, Object?>{
  'id': 1,
  'name': 'المعرض',
  'code': 'SHOP',
  'kind': 'shop_floor',
  'is_default': true,
  'is_active': true,
  'stock_item_count': 12,
  'can_delete': false,
  'blockers': ['يوجد مخزون في هذا المكان.'],
};

const _storeRoom = <String, Object?>{
  'id': 2,
  'name': 'المخزن',
  'code': 'STORE',
  'kind': 'store_room',
  'is_default': false,
  'is_active': true,
  'stock_item_count': 0,
  'can_delete': true,
  'blockers': <String>[],
};

const _transfers = <Map<String, Object?>>[
  {
    'id': 7,
    'transfer_number': 'TR-0007',
    'source': 2,
    'source_name': 'المخزن',
    'destination': 1,
    'destination_name': 'المعرض',
    'status': 'in_transit',
    'lines': <Object?>[],
  },
  {
    'id': 8,
    'transfer_number': 'TR-0008',
    'source': 1,
    'source_name': 'المعرض',
    'destination': 2,
    'destination_name': 'المخزن',
    'status': 'draft',
    'lines': <Object?>[],
  },
];

http.Client _client({
  List<Map<String, Object?>> places = const [_shopFloor, _storeRoom],
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/shop-settings/')) {
      return _json(const {'shop_name': 'متجر'});
    }
    if (path.endsWith('/warehouses/')) {
      return _json({'results': places, 'next': null});
    }
    if (path.endsWith('/register-profiles/me/')) {
      return _json(const {
        'device_id': 'till-1',
        'warehouse': 1,
        'warehouse_name': 'المعرض',
        'warehouse_kind': 'shop_floor',
        'assigned': true,
      });
    }
    if (path.endsWith('/stock-transfers/')) {
      return _json(const {'results': _transfers, 'next': null});
    }
    return _json(const {'results': <Object?>[], 'next': null});
  });
}

http.Response _json(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

PosApiService _service(http.Client client) {
  return PosApiService(baseUrl: 'http://pointy.test/api', client: client);
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

Future<void> _pumpSettings(WidgetTester tester, PosUser user) async {
  // Tall enough that every tile is laid out without scrolling.
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final client = _client();
  final service = _service(client);
  final capabilities = AuthorizationCapabilities.forUser(user);
  final shopSettings = ShopSettingsRepository(service);
  final catalog = CatalogRepository(service);
  final operations = OperationsRepository(service);
  final warehouses = WarehouseRepository(service);
  final viewModel = ShopSettingsViewModel(shopSettings);
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    _app(
      ShopSettingsScreen(
        viewModel: viewModel,
        factoryResetViewModel: FactoryResetViewModel(shopSettings),
        salesChannelsViewModel: SalesChannelsViewModel(
          SalesChannelRepository(service),
        ),
        warehousesViewModel: WarehousesViewModel(warehouses),
        transfersViewModel: TransfersViewModel(warehouses),
        warehouseRepository: warehouses,
        priceCheckersViewModel: PriceCheckersViewModel(
          PriceCheckerRepository(service),
        ),
        cameraSettingsViewModel: CameraSettingsViewModel(
          SurveillanceRepository(service),
        ),
        scalesViewModel: ScalesViewModel(ScalesRepository(service), catalog),
        workflowsViewModel: WorkflowsViewModel(operations),
        assetTypesViewModel: AssetTypesViewModel(operations),
        prepStationsViewModel: PrepStationsViewModel(
          PrepStationRepository(service),
          catalog,
        ),
        modifierGroupsViewModel: ModifierGroupsViewModel(
          ModifierGroupRepository(service),
        ),
        attendanceViewModel: AttendanceViewModel(AttendanceRepository(service)),
        migrationViewModel: MigrationViewModel(MigrationRepository(service)),
        subscriptionViewModel: SubscriptionStatusViewModel(
          SubscriptionRepository(service),
        ),
        exchangeRatesViewModel: ExchangeRatesViewModel(FxRepository(service)),
        messagingViewModel: MessagingSettingsViewModel(
          MessagingRepository(service),
        ),
        integrationsViewModel: IntegrationsViewModel(
          IntegrationsRepository(service),
        ),
        clientUpdateService: ClientUpdateService(
          apiBaseUrl: () => service.baseUrl,
          client: client,
        ),
        capabilities: capabilities,
        navigation: FakeAppNavigation(
          currentUser: user,
          capabilities: capabilities,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [navigation] is how the drawer, the rail and ⌘K open the page; without it
/// the page is what shop settings pushes.
Future<void> _pumpWarehouses(
  WidgetTester tester,
  PosUser user, {
  List<Map<String, Object?>> places = const [_shopFloor, _storeRoom],
  AppNavigation? navigation,
}) async {
  final viewModel = WarehousesViewModel(
    WarehouseRepository(_service(_client(places: places))),
  );
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    _app(
      WarehousesPage(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: navigation,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpTransfers(
  WidgetTester tester,
  PosUser user, {
  AppNavigation? navigation,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final repository = WarehouseRepository(_service(_client()));
  final viewModel = TransfersViewModel(repository);
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    _app(
      TransfersScreen(
        viewModel: viewModel,
        repository: repository,
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: navigation,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpDrawer(WidgetTester tester, PosUser user) async {
  // Tall enough that the drawer's lazy list builds every destination.
  await tester.binding.setSurfaceSize(const Size(800, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

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
