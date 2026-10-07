import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/identified_stock_settings_page.dart';
import 'package:pointy_frontend/src/features/settings/views/unit_checklist_screen.dart';
import 'package:pointy_frontend/src/features/settings/views/unit_checklists_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_attribute_catalog.dart';

import '../unit_checklist_fakes.dart';

/// «قوائم فحص الأجهزة» end to end on the client: reached from the serial
/// settings, a kind opened, a field deleted and moved — and the receiving
/// sheet's cached definitions dropped after each, so the next device received
/// is asked the new list.
void main() {
  late AppLocalizations l10n;
  late int catalogReads;
  late UnitAttributeCatalog catalog;

  setUp(() {
    catalogReads = 0;
    catalog = UnitAttributeCatalog((_) async {
      catalogReads++;
      return const Ok(<UnitAttributeDefinition>[]);
    });
  });

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(1366, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: PointyTheme.light(),
        builder: (context, child) =>
            UnitAttributeCatalogScope(catalog: catalog, child: child!),
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return home;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the entry in the serial settings', () {
    Future<void> pumpSettings(
      WidgetTester tester, {
      required bool serialized,
      FakeChecklistRepository? repository,
    }) async {
      final viewModel = ShopSettingsViewModel(
        _SettingsRepository(serialized: serialized),
      );
      addTearDown(viewModel.dispose);
      await pump(
        tester,
        IdentifiedStockSettingsPage(
          viewModel: viewModel,
          checklistRepository: repository,
        ),
      );
    }

    final tile = find.byKey(const ValueKey('identified_stock_checklists_tile'));

    testWidgets('opens the kinds with their counts', (tester) async {
      await pumpSettings(
        tester,
        serialized: true,
        repository: FakeChecklistRepository(),
      );
      expect(tile, findsOneWidget);
      expect(find.text(l10n.unitChecklistsEntrySubtitle), findsOneWidget);

      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(find.byType(UnitChecklistsScreen), findsOneWidget);
      expect(find.text('هاتف'), findsOneWidget);
      expect(
        find.text(
          '${l10n.unitChecklistFieldCount(3)} · '
          '${l10n.unitChecklistRequiredCount(1)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('is absent for a user who may not edit checklists', (
      tester,
    ) async {
      await pumpSettings(tester, serialized: true);

      expect(tile, findsNothing);
    });

    testWidgets('is absent while serials are off', (tester) async {
      await pumpSettings(
        tester,
        serialized: false,
        repository: FakeChecklistRepository(),
      );

      expect(tile, findsNothing);
    });
  });

  group('one kind\'s checklist', () {
    late FakeChecklistRepository repository;

    Future<void> pumpChecklist(WidgetTester tester, {Size? size}) async {
      repository = FakeChecklistRepository();
      await pump(
        tester,
        UnitChecklistScreen(repository: repository, kind: phoneKind),
        size: size ?? const Size(1366, 900),
      );
      // Prime the receiving sheet's cache, as a receipt opened earlier would.
      await catalog.definitionsFor(phoneKind.assetTypeId);
      expect(catalogReads, 1);
    }

    Future<void> openMenu(WidgetTester tester, int fieldId) async {
      await tester.tap(
        find.byKey(ValueKey('unit-checklist-field-menu-$fieldId')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('lists the fields in order with what each asks', (
      tester,
    ) async {
      await pumpChecklist(tester, size: const Size(390, 844));

      expect(find.text(l10n.unitChecklistScreenTitle('هاتف')), findsOneWidget);
      expect(find.text('صحة البطارية'), findsOneWidget);
      expect(find.text(l10n.unitChecklistRequiredBadge), findsOneWidget);
      expect(
        find.text(
          '${l10n.unitChecklistTypeChoice} · ممتاز +، ممتاز، جيد '
          '${l10n.unitChecklistMoreChoices(2)}',
        ),
        findsOneWidget,
      );
      expect(find.text('${l10n.unitChecklistTypePercent} · %'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('delete asks first, then forgets the cached list', (
      tester,
    ) async {
      await pumpChecklist(tester);

      await openMenu(tester, 1);
      await tester.tap(find.text(l10n.deleteButton).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.unitChecklistDeleteBody), findsOneWidget);
      await tester.tap(find.text(l10n.deleteButton).last);
      await tester.pumpAndSettle();

      expect(repository.deleted, [1]);
      expect(find.text('صحة البطارية'), findsNothing);
      expect(find.text(l10n.unitChecklistDeleted), findsOneWidget);
      await catalog.definitionsFor(phoneKind.assetTypeId);
      expect(catalogReads, 2);
    });

    testWidgets('a field moves from its menu, without a drag', (tester) async {
      await pumpChecklist(tester);

      await openMenu(tester, 1);
      await tester.tap(find.text(l10n.unitChecklistMoveDown));
      await tester.pumpAndSettle();

      expect(repository.reorders.single, [2, 1, 3]);
      await catalog.definitionsFor(phoneKind.assetTypeId);
      expect(catalogReads, 2);
    });

    testWidgets('a new field is saved and the cached list dropped', (
      tester,
    ) async {
      await pumpChecklist(tester);

      await tester.tap(find.byKey(const ValueKey('unit-checklist-add-field')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('unit-checklist-label')),
        'Face ID يعمل',
      );
      await tester.tap(find.byKey(const ValueKey('unit-checklist-save')));
      await tester.pumpAndSettle();

      expect(repository.saved.single.dataType, UnitAttributeType.boolean);
      expect(find.text('Face ID يعمل'), findsOneWidget);
      expect(find.text(l10n.unitChecklistSaved), findsOneWidget);
      await catalog.definitionsFor(phoneKind.assetTypeId);
      expect(catalogReads, 2);
    });

    testWidgets('an empty checklist says what to add', (tester) async {
      repository = FakeChecklistRepository(fields: const []);
      await pump(
        tester,
        UnitChecklistScreen(repository: repository, kind: phoneKind),
      );

      expect(find.text(l10n.unitChecklistEmptyTitle), findsOneWidget);
      expect(
        find.byKey(const ValueKey('unit-checklist-add-field')),
        findsOneWidget,
      );
    });
  });
}

class _SettingsRepository extends ShopSettingsRepository {
  _SettingsRepository({required this.serialized}) : super(PosApiService());

  final bool serialized;

  @override
  Future<Result<ShopSettings>> loadSettings() async => Ok(
    ShopSettings.fromJson({
      'shop_name': 'متجر',
      'enable_serialized_inventory': serialized,
    }),
  );

  @override
  Future<Result<BackupOperationsStatus>> loadBackupOperationsStatus() async =>
      Error(Exception('not used'));

  @override
  Future<Result<List<BackupDestination>>> loadBackupDestinations() async =>
      Error(Exception('not used'));
}
